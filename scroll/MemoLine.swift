//
//  MemoLine.swift
//  scroll
//

import Foundation

struct MemoLine: Identifiable, Codable, Equatable, Hashable, Sendable {
	var id: UUID
	/// プレーン（検索・互換用）。リッチと常に `attributed.string` で一致させる。
	var text: String
	/// 装飾付き本文（RTF）。nil のときは `text` をプレーンとして表示（既存データ互換）。
	var richTextRTF: Data?
	/// 画像添付など RTF で落ちる内容用（`NSSecureCoding`）。nil のときは RTF / plain のみ。
	var richTextArchive: Data?
	/// その行に初めて書き込んだ日時（日付区切り表示に使用）
	var firstWrittenAt: Date
	var modifiedAt: Date

	init(
		id: UUID = UUID(),
		text: String = "",
		richTextRTF: Data? = nil,
		richTextArchive: Data? = nil,
		firstWrittenAt: Date = Date(),
		modifiedAt: Date = Date()
	) {
		self.id = id
		self.text = text
		self.richTextRTF = richTextRTF
		self.richTextArchive = richTextArchive
		self.firstWrittenAt = firstWrittenAt
		self.modifiedAt = modifiedAt
	}
}
