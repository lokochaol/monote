//
//  MemoDocumentPersistence.swift
//  scroll
//

import Foundation

@MainActor
final class MemoDocumentPersistence {
    static let documentFileName = "memo_doc.json"

    private(set) var rootURL: URL
    private(set) var isUsingICloudRoot: Bool = false

    init() {
        let local = MemoStorageRoot.localMemoBlocksURL
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        rootURL = local
    }

    private func relocateRoot(to url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        rootURL = url
    }

    var documentURL: URL { rootURL.appendingPathComponent(Self.documentFileName) }

    func documentExists() -> Bool {
        FileManager.default.fileExists(atPath: documentURL.path)
    }

    // MARK: - Storage root

    @discardableResult
    func prepareStorageRootIfNeeded() async -> Bool {
        guard MemoStorageRoot.prefersICloud else { return false }
        let localRoot = MemoStorageRoot.localMemoBlocksURL

        let resolvedICloudRoot = await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let ubiquityRoot = MemoStorageRoot.resolveICloudMemoBlocksURLBlocking() else { return nil }
            MemoCloudStorageMigrator.migrateLocalToICloudBlocking(localRoot: localRoot, ubiquityRoot: ubiquityRoot)
            return ubiquityRoot
        }.value

        guard let ubiquityRoot = resolvedICloudRoot else { return false }
        relocateRoot(to: ubiquityRoot)
        isUsingICloudRoot = true
        MemoStorageRoot.hasActivatedICloud = true
        return true
    }

    func setICloudEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            return await prepareStorageRootIfNeeded()
        } else {
            let cloudRoot = rootURL
            let localRoot = MemoStorageRoot.localMemoBlocksURL
            await Task.detached(priority: .userInitiated) {
                MemoCloudStorageMigrator.migrateICloudToLocalBlocking(ubiquityRoot: cloudRoot, localRoot: localRoot)
            }.value
            relocateRoot(to: localRoot)
            isUsingICloudRoot = false
            MemoStorageRoot.prefersICloud = false
            MemoStorageRoot.hasActivatedICloud = false
            return false
        }
    }

    // MARK: - Load / Save

    func load() -> MemoDocumentContent? {
        guard let data = try? Data(contentsOf: documentURL) else { return nil }
        return try? JSONDecoder().decode(MemoDocumentContent.self, from: data)
    }

    func loadAsync() async -> MemoDocumentContent? {
        let url = documentURL
        return await Task.detached(priority: .userInitiated) { () -> MemoDocumentContent? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(MemoDocumentContent.self, from: data)
        }.value
    }

    func save(_ content: MemoDocumentContent) {
        guard let data = try? JSONEncoder().encode(content) else { return }
        try? data.write(to: documentURL, options: .atomic)
    }

    func saveAsync(_ content: MemoDocumentContent) async {
        let content = content
        let url = documentURL
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(content) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }

    // MARK: - iCloud diagnostics

    func evictUnusedICloudItems() async -> Int {
        guard isUsingICloudRoot else { return 0 }
        let url = documentURL
        return await Task.detached(priority: .utility) { () -> Int in
            guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
            do {
                try FileManager.default.evictUbiquitousItem(at: url)
                return 1
            } catch {
                return 0
            }
        }.value
    }

    func fetchStorageDiagnostics() async -> MemoStorageDiagnostics {
        let rootURL = self.rootURL
        let isCloud = self.isUsingICloudRoot
        return await Task.detached(priority: .utility) {
            MemoStorageInspector.collectDiagnostics(rootURL: rootURL, isUsingICloudRoot: isCloud)
        }.value
    }
}
