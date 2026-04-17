//
//  MemoSyncCoordinator.swift
//  scroll
//

import Foundation

/// ローカル確定後にクラウドへ反映する差し替え口（Firebase 等は別実装で差し替え）
@MainActor
protocol MemoSyncCoordinating: AnyObject {
	func memoDidFlushToDisk(persistence: MemoBlockPersistence, linesPerBlock: Int, totalLines: Int) async
}

@MainActor
final class NoOpMemoSyncCoordinator: MemoSyncCoordinating {
	static let shared = NoOpMemoSyncCoordinator()
	private init() {}

	func memoDidFlushToDisk(persistence: MemoBlockPersistence, linesPerBlock: Int, totalLines: Int) async {}
}
