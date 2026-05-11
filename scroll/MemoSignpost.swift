//
//  MemoSignpost.swift
//  scroll
//
//  Instruments 用の共通 signpost 定義。
//  Profile 時は "Points of Interest" instrument に "memo.editor" サブシステムが現れる。
//

import Foundation
import os

enum MemoSignpost {
	/// すべてのテキスト入力系 signpost を束ねる唯一の OSLog。
	static let log = OSLog(subsystem: "scroll.memo.editor", category: .pointsOfInterest)
	static let signposter = OSSignposter(logHandle: log)
}
