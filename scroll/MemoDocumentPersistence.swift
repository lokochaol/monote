//
//  MemoDocumentPersistence.swift
//  scroll
//

import Foundation

@MainActor
final class MemoDocumentPersistence {
    static let documentFileName = "memo_doc.json"

    private(set) var rootURL: URL

    init() {
        let local = MemoStorageRoot.localMemoBlocksURL
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        rootURL = local
    }

    var documentURL: URL { rootURL.appendingPathComponent(Self.documentFileName) }

    func documentExists() -> Bool {
        FileManager.default.fileExists(atPath: documentURL.path)
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
}
