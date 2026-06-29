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

    // Undo/redo state (tracked from UITextView)
    var canUndo: Bool = false
    var canRedo: Bool = false

    // Boot state
    private(set) var isBootstrapped: Bool = false

    func attachSyncCoordinator(_ coordinator: (any MemoSyncCoordinating)?) {
        // No-op: new document model doesn't use block-based sync coordinator
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        if persistence.documentExists(), let loaded = await persistence.loadAsync() {
            await loadDocument(loaded)
        } else {
            let migrated = await migrateFromBlocks()
            await loadDocument(migrated)
            await persistence.saveAsync(migrated)
        }
        isBootstrapped = true
    }

    private func loadDocument(_ doc: MemoDocumentContent) async {
        content = doc
        let rtf = doc.rtfData
        let archive = doc.archiveData
        let plain = doc.plainText
        // Decode attributed string off the main thread; NSKeyedUnarchiver + image thumbnailing
        // can take seconds on large memos with attachments, triggering a watchdog kill.
        let attr: NSAttributedString = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: MemoRichTextEncoding.attributedString(
                    rtfData: rtf, archiveData: archive, plainFallback: plain
                ))
            }
        }
        attributedContent = attr
        contentVersion += 1
    }

    private func migrateFromBlocks() async -> MemoDocumentContent {
        let bp = MemoBlockPersistence()
        let (savedLPB, total) = bp.loadIndex()
        let lpb = savedLPB > 0 ? savedLPB : MemoBlockConfig.minLinesPerBlock
        guard total > 0, lpb > 0 else { return MemoDocumentContent() }

        // Load all block files off the main thread to avoid watchdog kills on large memos
        let lines = await bp.loadLinesFromGlobalIndexToEndAsync(
            startGlobalIndex: 0,
            linesPerBlock: lpb,
            totalLines: total
        )
        guard !lines.isEmpty else { return MemoDocumentContent() }

        // Decode + join + encode entirely off the main thread.
        // MemoLine is Sendable; NSAttributedString lives only inside this task.
        return await Task.detached(priority: .utility) {
            let separator = NSAttributedString(
                string: "\n",
                attributes: MemoRichTextEncoding.defaultTypingAttributes()
            )
            let joined = NSMutableAttributedString()
            for (i, line) in lines.enumerated() {
                if i > 0 { joined.append(separator) }
                joined.append(MemoRichTextEncoding.attributedString(
                    rtfData: line.richTextRTF,
                    archiveData: line.richTextArchive,
                    plainFallback: line.text
                ))
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
        }.value
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
        let (rtf, archive) = await Task.detached(priority: .utility) {
            MemoRichTextEncoding.persistPayload(from: pending)
        }.value
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
}
