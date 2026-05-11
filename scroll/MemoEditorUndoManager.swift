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

	struct PendingRichEntry: Codable, Equatable, Sendable {
		var lineId: UUID
		/// `NSKeyedArchiver` で出力した `NSAttributedString` のバイト列。
		var archive: Data
	}

	struct Snapshot: Codable, Sendable {
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
	/// スタック全体で保持を許す `pendingRich.archive` の合計バイト数のソフトリミット。
	/// 画像添付のある行を含む編集では 1 スナップショットが数 MB になるため、段数だけで頭打ちすると
	/// すぐに数百 MB に達して OOM kill される。これを超えたら古いスナップショットから捨てる。
	private let maxPendingRichTotalBytes: Int = 24 * 1024 * 1024
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
		enforceEntryCap()
		enforceByteBudget()
		lastRecordedAt = now
		lastRecordedKind = kind
	}

	/// 段数上限を満たすよう、古い undo から順に捨てる。
	private func enforceEntryCap() {
		if undoStack.count > maxEntries {
			undoStack.removeFirst(undoStack.count - maxEntries)
		}
	}

	/// `pendingRich.archive` の合計バイト数のソフトリミットを超えていれば、古い undo から順に捨てる。
	/// undo スタック優先で削り、それでも超えていれば redo からも古い側を削る。
	/// 常に最新 1 件の undo は残す（ここを削ると直前の 1 操作が取り消せなくなって UX 上の痛みが大きい）。
	private func enforceByteBudget() {
		func totalBytes() -> Int {
			var total = 0
			for s in undoStack { for e in s.pendingRich { total += e.archive.count } }
			for s in redoStack { for e in s.pendingRich { total += e.archive.count } }
			return total
		}
		while totalBytes() > maxPendingRichTotalBytes, undoStack.count > 1 {
			undoStack.removeFirst()
		}
		while totalBytes() > maxPendingRichTotalBytes, !redoStack.isEmpty {
			redoStack.removeFirst()
		}
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

	// MARK: - 永続化（メモリ常駐のみ）
	//
	// 以前は `Persisted { undo, redo }` を JSON にシリアライズしてディスクに保存していたが、
	// 1 スナップショットは `visibleLines` と `NSAttributedString` のアーカイブ `Data` を丸ごと含むため、
	// 画像添付のある行を持つドキュメントでは最大 80 件 × 数 MB で数百 MB に膨らむ。
	// 起動時の `loadFromDisk` で `Data(contentsOf:)` + `JSONDecoder.decode` がピーク時にその倍のメモリを要し、
	// 起動直後から高い水位になって「少しの打鍵で OOM kill される」一因になっていた。
	//
	// undo/redo はセッション内で完結するのが一般的な UX なので、ここではディスク永続化をやめてメモリ常駐だけにする。
	// 互換目的で旧来の `undo_stack.json` が残っていれば起動時に削除する。

	/// 以前のバージョンが残した `undo_stack.json` を削除する。
	/// 起動時に呼ぶと、巨大な古い履歴ファイルを読み込むことによるメモリスパイクを避けられる。
	func discardPersistedStackIfPresent(at url: URL) {
		try? FileManager.default.removeItem(at: url)
	}

	/// 互換用のダミー。新規実装ではディスク保存は行わないが、呼び出し側の経路を温存するため no-op で残す。
	func saveToDiskAsync(at _: URL) async { /* no-op: in-memory only */ }

	/// 互換用のダミー。旧ファイルが残っていれば削除する以外は何もしない。
	func loadFromDisk(at url: URL) {
		discardPersistedStackIfPresent(at: url)
		undoStack.removeAll()
		redoStack.removeAll()
		breakCoalescing()
	}
}
