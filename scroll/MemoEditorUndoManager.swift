//
//  MemoEditorUndoManager.swift
//  scroll
//

import Foundation

/// エディタ全体のスナップショットを積むアンドゥスタック。
/// `MemoEditorViewModel` の mutating メソッド入口で pre-mutation スナップショットを積み、
/// `undo` / `redo` では丸ごとそれを差し戻す。
@MainActor
final class MemoEditorUndoManager {
	enum SnapshotKind: String, Codable {
		/// キー入力・スタイル変更など、短時間連続すれば 1 ステップにまとめる対象。
		case textEdit
		/// 改行挿入・行マージ・行削除・画像挿入・ペースト・タイムスタンプ挿入など、常に区切るもの。
		case structural
	}

	struct PendingRichEntry: Codable, Equatable {
		var lineId: UUID
		/// `NSKeyedArchiver` で出力した `NSAttributedString` のバイト列。
		var archive: Data
	}

	struct Snapshot: Codable {
		var visibleLines: [MemoLine]
		var pendingRich: [PendingRichEntry]
		var globalLineOffset: Int
		var loadedBlockStart: Int
		var loadedBlockEnd: Int
		var totalPersistedLines: Int
		var focusedLineId: UUID?
		var caretUTF16: Int
		/// スナップショット時点でアンカー行が文書内の何番目にあったか。
		/// undo/redo 後に「操作された付近」へスクロールするために使う（行削除で id が失われていても近傍に寄せられる）。
		var anchorGlobalIndex: Int?
		var capturedAt: Date
		var kind: SnapshotKind
	}

	private(set) var undoStack: [Snapshot] = []
	private(set) var redoStack: [Snapshot] = []

	/// 履歴の最大段数。これを超えたぶんは古いほうから捨てる。
	private let maxEntries = 80
	/// 連続するテキスト編集をまとめる無入力猶予時間。
	private let coalesceWindow: TimeInterval = 0.6

	/// 直近で新しい entry を積んだ時刻と種別。コアレス判定にだけ使う。
	private var lastRecordedAt: Date?
	private var lastRecordedKind: SnapshotKind?

	var canUndo: Bool { !undoStack.isEmpty }
	var canRedo: Bool { !redoStack.isEmpty }

	/// 直近の undo スナップショット（実際には pop せずに覗く）。
	var peekUndo: Snapshot? { undoStack.last }
	/// 直近の redo スナップショット（同上）。
	var peekRedo: Snapshot? { redoStack.last }

	/// mutating メソッドの入口から呼ぶ。`makeSnapshot` は「これから変更する前」の状態を作るクロージャ。
	/// 直前が `.textEdit` で猶予時間内に続く `.textEdit` が来たら同じ undo ステップにまとめ、
	/// スナップショット自体の構築を省く（NSKeyedArchiver 呼び出し回避）。
	func recordIfNeeded(kind: SnapshotKind, makeSnapshot: () -> Snapshot) {
		if !redoStack.isEmpty {
			redoStack.removeAll()
		}

		let now = Date()
		if let last = lastRecordedAt,
		   let lk = lastRecordedKind,
		   lk == .textEdit, kind == .textEdit,
		   now.timeIntervalSince(last) < coalesceWindow,
		   !undoStack.isEmpty {
			// コアレス中: 既存 entry を残し（＝変更前状態を保持）、時刻だけ更新。
			lastRecordedAt = now
			return
		}

		var snap = makeSnapshot()
		snap.kind = kind
		snap.capturedAt = now
		undoStack.append(snap)
		if undoStack.count > maxEntries {
			undoStack.removeFirst(undoStack.count - maxEntries)
		}
		lastRecordedAt = now
		lastRecordedKind = kind
	}

	/// 明示的にコアレスの区切りを入れる（フォーカス喪失・undo/redo 直後など）。
	func breakCoalescing() {
		lastRecordedAt = nil
		lastRecordedKind = nil
	}

	/// undo: 直前の pre-snapshot を取り出し、現在状態を redo 側に積む。
	func popUndo(current: Snapshot) -> Snapshot? {
		guard let top = undoStack.popLast() else { return nil }
		redoStack.append(current)
		if redoStack.count > maxEntries {
			redoStack.removeFirst(redoStack.count - maxEntries)
		}
		breakCoalescing()
		return top
	}

	/// redo: 直前に undo した状態へ戻し、現在状態を undo 側に積み直す。
	func popRedo(current: Snapshot) -> Snapshot? {
		guard let top = redoStack.popLast() else { return nil }
		undoStack.append(current)
		if undoStack.count > maxEntries {
			undoStack.removeFirst(undoStack.count - maxEntries)
		}
		breakCoalescing()
		return top
	}

	func clear() {
		undoStack.removeAll()
		redoStack.removeAll()
		breakCoalescing()
	}

	// MARK: - 永続化

	private struct Persisted: Codable {
		var undo: [Snapshot]
		var redo: [Snapshot]
	}

	func saveToDisk(at url: URL) {
		let payload = Persisted(undo: undoStack, redo: redoStack)
		guard let data = try? JSONEncoder().encode(payload) else { return }
		try? data.write(to: url, options: .atomic)
	}

	func loadFromDisk(at url: URL) {
		guard let data = try? Data(contentsOf: url) else { return }
		guard let payload = try? JSONDecoder().decode(Persisted.self, from: data) else {
			// 破損時は黙って捨てる（ファイル自体も消してもう読まれないようにする）。
			try? FileManager.default.removeItem(at: url)
			return
		}
		undoStack = payload.undo
		redoStack = payload.redo
		breakCoalescing()
	}
}
