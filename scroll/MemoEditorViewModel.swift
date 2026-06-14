//
//  MemoEditorViewModel.swift
//  scroll
//

import Foundation
import Observation
import UIKit

struct MemoDocSearchHit: Identifiable {
    let id = UUID()
    let range: NSRange
    let contextBefore: String
    let matchText: String
    let contextAfter: String
}

@Observable
@MainActor
final class MemoEditorViewModel {
    private let persistence = MemoDocumentPersistence()
    private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var ubiquityIdentityObserver: NSObjectProtocol?

    // Document
    @ObservationIgnored private var pendingAttributed: NSAttributedString?
    var content = MemoDocumentContent()
    var attributedContent: NSAttributedString = NSAttributedString()
    private(set) var contentVersion: Int = 0

    // Search
    var searchKeywordText: String = ""
    var searchHits: [MemoDocSearchHit] = []
    var searchMessage: String?
    var searchHighlightKeyword: String?
    var scrollToRange: NSRange?
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?

    // iCloud
    private(set) var iCloudStatus: MemoICloudStatus = .unknown
    private(set) var iCloudTransferActive: Bool = false

    // Undo/redo state (tracked from UITextView)
    var canUndo: Bool = false
    var canRedo: Bool = false

    // Boot state
    private(set) var isBootstrapped: Bool = false

    deinit {
        if let token = ubiquityIdentityObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func attachSyncCoordinator(_ coordinator: (any MemoSyncCoordinating)?) {
        // No-op: new document model doesn't use block-based sync coordinator
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        startObservingICloudIdentityIfNeeded()
        await Self.runWithTimeout(milliseconds: 500) { [persistence] in
            await persistence.prepareStorageRootIfNeeded()
        }
        iCloudStatus = persistence.isUsingICloudRoot ? .synced : .disabled
        await refreshICloudTransferState()

        if persistence.documentExists(), let loaded = await persistence.loadAsync() {
            loadDocument(loaded)
        } else {
            let migrated = await migrateFromBlocks()
            loadDocument(migrated)
            await persistence.saveAsync(migrated)
        }
        isBootstrapped = true
    }

    private func loadDocument(_ doc: MemoDocumentContent) {
        content = doc
        // Decode on the main actor: the document may contain attachments
        // (MemoSVGAttachment / MemoPreviewImageAttachment / MemoLinkChipAttachment),
        // which are MainActor-isolated under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
        // NSKeyedUnarchiver instantiates them via init?(coder:), so this must run on main.
        let attr = MemoRichTextEncoding.attributedString(
            rtfData: doc.rtfData,
            archiveData: doc.archiveData,
            plainFallback: doc.plainText
        )
        attributedContent = attr
        contentVersion += 1
    }

    private func migrateFromBlocks() async -> MemoDocumentContent {
        let bp = MemoBlockPersistence()
        await Self.runWithTimeout(milliseconds: 500) {
            await bp.prepareStorageRootIfNeeded()
        }
        let (savedLPB, total) = bp.loadIndex()
        let lpb = savedLPB > 0 ? savedLPB : MemoBlockConfig.minLinesPerBlock
        guard total > 0, lpb > 0 else { return MemoDocumentContent() }

        // File I/O (read + JSON decode of MemoLine structs) runs off the main thread.
        // MemoLine holds only Data, so no attachment objects are instantiated here.
        let lines = await bp.loadLinesFromGlobalIndexToEndAsync(
            startGlobalIndex: 0,
            linesPerBlock: lpb,
            totalLines: total
        )
        guard !lines.isEmpty else { return MemoDocumentContent() }

        // Decode/join/encode the attributed string on the main actor.
        // attributedContent()/persistPayload instantiate and archive the MainActor-isolated
        // attachment classes via NSCoding; doing this off the main thread trips Swift's
        // actor-executor assertion and crashes. The user's data is modest, so main-thread
        // decoding here is well within the watchdog budget.
        let separator = NSAttributedString(
            string: "\n",
            attributes: MemoRichTextEncoding.defaultTypingAttributes()
        )
        let joined = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            if i > 0 { joined.append(separator) }
            joined.append(line.attributedContent())
        }
        let ns = joined.string as NSString
        var end = ns.length
        while end > 0 {
            let c = ns.character(at: end - 1)
            if c == 10 || c == 13 { end -= 1 } else { break }
        }
        let trimmed: NSAttributedString = end > 0
            ? joined.attributedSubstring(from: NSRange(location: 0, length: end))
            : NSAttributedString()
        let (rtf, archive) = MemoRichTextEncoding.persistPayload(from: trimmed)
        var doc = MemoDocumentContent()
        doc.plainText = trimmed.string
        doc.rtfData = rtf
        doc.archiveData = archive
        return doc
    }

    // MARK: - Content updates

    func updateContent(attributed: NSAttributedString) {
        pendingAttributed = attributed
        content.plainText = attributed.string
        content.modifiedAt = Date()
        scheduleSave()
    }

    func updateUndoState(canUndo: Bool, canRedo: Bool) {
        self.canUndo = canUndo
        self.canRedo = canRedo
    }

    func clearScrollToRange() {
        scrollToRange = nil
    }

    // MARK: - Save

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch { return }
            if Task.isCancelled { return }
            await self?.flushToDisk()
        }
    }

    private func flushToDisk() async {
        guard let pending = pendingAttributed else { return }
        pendingAttributed = nil
        // Encode on the main actor: persistPayload archives the attributed string, which
        // calls each attachment's encode(with:). Those attachment classes are MainActor-isolated
        // (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), so archiving off the main thread crashes.
        // Only the resulting Data is written to disk asynchronously.
        let (rtf, archive) = MemoRichTextEncoding.persistPayload(from: pending)
        content.rtfData = rtf
        content.archiveData = archive
        await persistence.saveAsync(content)
    }

    // MARK: - Search

    func scheduleSearchHitRefresh() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshSearchHits()
        }
    }

    func refreshSearchHits() {
        let kw = searchKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            searchHits = []
            searchMessage = nil
            return
        }
        let text = content.plainText
        let ns = text as NSString
        let textLen = ns.length
        guard textLen > 0 else {
            searchHits = []
            searchMessage = "No data"
            return
        }
        var hits: [MemoDocSearchHit] = []
        var searchRange = NSRange(location: 0, length: textLen)
        let contextLen = 50
        while searchRange.length > 0, hits.count < 200 {
            let r = ns.range(of: kw, options: .caseInsensitive, range: searchRange)
            if r.location == NSNotFound { break }
            let beforeStart = max(0, r.location - contextLen)
            let before = ns.substring(with: NSRange(location: beforeStart, length: r.location - beforeStart))
            let afterStart = r.location + r.length
            let afterLen = min(contextLen, textLen - afterStart)
            let after = afterLen > 0 ? ns.substring(with: NSRange(location: afterStart, length: afterLen)) : ""
            hits.append(MemoDocSearchHit(range: r, contextBefore: before, matchText: ns.substring(with: r), contextAfter: after))
            let next = r.location + max(1, r.length)
            searchRange = NSRange(location: next, length: textLen - next)
        }
        searchHits = hits
        searchMessage = hits.isEmpty ? "No matches" : "\(hits.count) match\(hits.count == 1 ? "" : "es")"
    }

    func selectSearchHit(_ hit: MemoDocSearchHit) {
        let kw = searchKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchHighlightKeyword = kw.isEmpty ? nil : kw
        scrollToRange = hit.range
    }

    func clearSearchSelectionHighlight() {
        searchHighlightKeyword = nil
    }

    // MARK: - iCloud

    private func startObservingICloudIdentityIfNeeded() {
        guard ubiquityIdentityObserver == nil else { return }
        ubiquityIdentityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshICloudStatus()
            }
        }
    }

    func refreshICloudStatus() async {
        let canResolve = await Task.detached(priority: .utility) { () -> Bool in
            MemoStorageRoot.resolveICloudMemoBlocksURLBlocking() != nil
        }.value
        iCloudStatus = canResolve && persistence.isUsingICloudRoot ? .synced : .disabled
        await refreshICloudTransferState()
    }

    func refreshICloudTransferState() async {
        guard persistence.isUsingICloudRoot else {
            iCloudTransferActive = false
            return
        }
        let root = persistence.rootURL
        let active = await Task.detached(priority: .utility) {
            MemoStorageInspector.memoDataHasActiveUbiquitousTransfer(rootURL: root)
        }.value
        iCloudTransferActive = active
    }

    @discardableResult
    func toggleICloudSync(enabled: Bool) async -> Bool {
        iCloudStatus = .unknown
        await saveTask?.value
        let nowICloud = await persistence.setICloudEnabled(enabled)
        iCloudStatus = nowICloud ? .synced : .disabled
        await refreshICloudTransferState()
        return nowICloud
    }

    func fetchStorageDiagnostics() async -> MemoStorageDiagnostics {
        await persistence.fetchStorageDiagnostics()
    }

    func evictUnusedICloudItems() async -> Int {
        await persistence.evictUnusedICloudItems()
    }

    // MARK: - Helpers

    private static func runWithTimeout(milliseconds: UInt64, _ work: @MainActor @escaping () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in await work() }
            group.addTask { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
