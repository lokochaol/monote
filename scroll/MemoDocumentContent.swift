//
//  MemoDocumentContent.swift
//  scroll
//

import Foundation

struct MemoDocumentContent: Codable, Sendable {
    var id: UUID
    var plainText: String
    var rtfData: Data?
    var archiveData: Data?
    var modifiedAt: Date
    var createdAt: Date

    init() {
        id = UUID()
        plainText = ""
        modifiedAt = Date()
        createdAt = Date()
    }
}
