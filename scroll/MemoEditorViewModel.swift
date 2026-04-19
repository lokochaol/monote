//
//  MemoEditorViewModel.swift
//  scroll
//

import Foundation
import Observation
import SwiftUI

/// 改行分割などで MemoLineTextView へフォーカスを移すためのリクエスト（View が onChange で消費する）。
struct MemoEditorFocusRequest: Equatable {
	let lineId: UUID
	let caretUTF16: Int
}

@Observable
@MainActor
final class MemoEditorViewModel {
	private let persistence = MemoBlockPersistence()
	private var saveTask: Task<Void, Never>?
	/// 上方向プリフェッチの重複実行防止（非同期読み込み中）
	private var isLoadingPreviousBlock = false
	/// ヒステリシス: 一度読み込んだあと、先頭帯から十分離れるまで再トリガーしない
	private var prefetchRearmed = true
	/// 下方向トリムのヒステリシス: 一度落としたら、先頭付近へ戻るまで再トリガーしない
	private var trimRearmed = true
	private var isTrimmingLeadingBlock = false
	private weak var syncCoordinator: MemoSyncCoordinating?

	/// Undo / redo 用の履歴スタック。永続化されるので再起動後も残る。
	@ObservationIgnored private let undoManager = MemoEditorUndoManager()
	/// undo/redo 実行中は record をかけない。循環的な push を避けるためのフラグ。
	@ObservationIgnored private var isApplyingUndoRedo = false
	/// `MemoEditorView` が最後に通知してきたキャレット情報。View からのハンドラに渡しそびれない場面で参照する。
	@ObservationIgnored private var lastKnownCaret: (lineId: UUID, utf16: Int)?

	var linesPerBlock: Int = MemoBlockConfig.minLinesPerBlock
	var loadedBlockStart: Int = 0
	var loadedBlockEnd: Int = 0
	/// visibleLines[i] のグローバル行番号は globalLineOffset + i
	var visibleLines: [MemoLine] = []
	private(set) var totalPersistedLines: Int = 0
	private(set) var globalLineOffset: Int = 0

	var searchKeywordText: String = ""
	var searchHitContexts: [MemoSearchHitContext] = []
	var searchMessage: String?
	/// 検索キーワード（空ならハイライトなし）
	var searchHighlightKeyword: String?
	/// 検索結果からユーザーが選択した（ジャンプした）行。未選択なら nil。
	var searchHighlightGlobalLineIndex: Int?
	/// `searchHitContexts` から導出した「ヒットした行」の集合（表示側の高速判定用）。
	private(set) var searchHitGlobalLineIndexSet: Set<Int> = []

	var scrollAnchorLineId: UUID?
	var editorFocusRequest: MemoEditorFocusRequest?

	// MARK: - 複数行選択モード

	/// 選択モード（コピー・削除のための一括選択）に入っているか。
	/// `true` の間はフォーカス系・自動スクロール系の副作用をすべて抑止する。
	var isSelectionMode: Bool = false
	/// 現在選択されている行 ID（`visibleLines` 内）。モード解除時に必ず空へ戻す。
	var selectedLineIds: Set<UUID> = []

	/// 1 本のドラッグジェスチャ中、「最初に触れた行が未選択だったか選択済みだったか」でジェスチャ全体のモードが確定する。
	private enum DragSelectionMode { case adding, removing }
	private var dragSelectionMode: DragSelectionMode?
	/// ジェスチャ開始直前の `selectedLineIds`。範囲方式の基底状態として、
	/// extend のたびにこれと「最初に触れた行〜現在指の行」の範囲を `union` / `subtracting` して上書きする。
	/// これにより、なぞり戻しで範囲が縮むと、外れた行は基底状態へ自然に戻る。
	private var dragSelectionSnapshot: Set<UUID> = []
	/// ジェスチャ最初に触れた行の ID。
	private var dragFirstLineId: UUID?

	private var searchDebounceTask: Task<Void, Never>?
	/// 入力中の最新リッチ本文（永続化用）。キー入力ごとの RTF/Archive 生成を避けるためキャッシュする。
	private var pendingRichByLineId: [UUID: NSAttributedString] = [:]

	private struct DisplayAttrCacheEntry {
		var fingerprint: Int
		var attr: NSAttributedString
	}
	/// 表示用 attributed の復元キャッシュ（フォーカス移動やスクロールでの再計算を抑える）。
	/// `body` 評価中に `displayAttributed(for:)` から更新するため、観測対象外にして
	/// 「ビュー更新中の状態変更」警告を避ける。
	@ObservationIgnored private var displayAttrCacheByLineId: [UUID: DisplayAttrCacheEntry] = [:]

	private func fingerprintForDisplay(line: MemoLine) -> Int {
		var h = Hasher()
		h.combine(line.text)
		h.combine(line.richTextRTF?.count ?? 0)
		h.combine(line.richTextArchive?.count ?? 0)
		// modifiedAt を入れると編集の反映漏れが起きにくい（ただし pending がある場合はそちらが優先される）
		h.combine(line.modifiedAt.timeIntervalSince1970)
		return h.finalize()
	}

	private func pruneDisplayCachesToVisible() {
		let ids = Set(visibleLines.map(\.id))
		displayAttrCacheByLineId = displayAttrCacheByLineId.filter { ids.contains($0.key) }
		// pendingRichByLineId は編集中の行のみのはずだが、念のため visible 範囲外も落とす
		pendingRichByLineId = pendingRichByLineId.filter { ids.contains($0.key) }
	}

	/// 行の表示に使う attributed。編集中は pending を返し、そうでなければ復元結果をキャッシュする。
	func displayAttributed(for line: MemoLine) -> NSAttributedString {
		if let pending = pendingRichByLineId[line.id] { return pending }
		let fp = fingerprintForDisplay(line: line)
		if let e = displayAttrCacheByLineId[line.id], e.fingerprint == fp {
			return e.attr
		}
		let decoded = MemoRichTextEncoding.attributedString(
			rtfData: line.richTextRTF,
			archiveData: line.richTextArchive,
			plainFallback: line.text
		)
		displayAttrCacheByLineId[line.id] = DisplayAttrCacheEntry(fingerprint: fp, attr: decoded)
		return decoded
	}

	func attachSyncCoordinator(_ coordinator: MemoSyncCoordinating?) {
		syncCoordinator = coordinator
	}

	func bootstrap(screenHeight: CGFloat) {
		linesPerBlock = MemoBlockConfig.linesPerBlock(screenHeight: screenHeight)
		let (savedLPB, total) = persistence.loadIndex()

		if savedLPB > 0, savedLPB != linesPerBlock, total > 0 {
			let all = persistence.loadAllLines(linesPerBlock: savedLPB, totalFromIndex: total)
			persistence.saveAllLines(all, linesPerBlock: linesPerBlock)
		}

		let (_, newTotal) = persistence.loadIndex()
		totalPersistedLines = newTotal

		if totalPersistedLines == 0 {
			visibleLines = [MemoLine()]
			pruneDisplayCachesToVisible()
			globalLineOffset = 0
			loadedBlockStart = 0
			loadedBlockEnd = 0
			totalPersistedLines = 1
			scheduleSave()
			undoManager.loadFromDisk(at: persistence.undoStackURL)
			return
		}

		let lastBlock = (totalPersistedLines - 1) / linesPerBlock
		loadedBlockStart = lastBlock
		loadedBlockEnd = lastBlock
		globalLineOffset = lastBlock * linesPerBlock
		visibleLines = persistence.loadBlock(lastBlock)
		pruneDisplayCachesToVisible()
		normalizeTrailingEmptyLineOnBootstrap()
		undoManager.loadFromDisk(at: persistence.undoStackURL)
	}

	private func blockCount(forTotalLines total: Int) -> Int {
		guard total > 0, linesPerBlock > 0 else { return 0 }
		return (total + linesPerBlock - 1) / linesPerBlock
	}

	/// 先頭ブロック相当のおおよその高さ（スクロール閾値用。実測より軽量）
	func estimatedFirstBlockHeight() -> CGFloat {
		guard linesPerBlock > 0 else { return MemoBlockConfig.approximateLineHeight }
		return CGFloat(linesPerBlock) * MemoBlockConfig.approximateLineHeight
	}

	/// 無限スクロール: スクロールビュー座標系における **コンテンツ先頭** の minY。
	/// 先頭がビュー上端付近では 0 に近く、下方向へスクロールするほど負に大きくなる想定。
	/// 先頭ブロックの「上から 1/5」以内が見えている帯（`>= -firstBlockHeight * 0.2`）で前ブロックを読み込む。
	func reportScrollForInfiniteScroll(contentTopY: CGFloat, firstBlockHeight: CGFloat, focusedLineId: UUID?) {
		guard loadedBlockStart > 0, firstBlockHeight > 1 else { return }
		if contentTopY < -firstBlockHeight * 0.35 {
			prefetchRearmed = true
		}
		guard prefetchRearmed, !isLoadingPreviousBlock else { return }
		guard contentTopY >= -firstBlockHeight * 0.2 else { return }

		let prev = loadedBlockStart - 1
		let anchorId = visibleLines.first?.id
		prefetchRearmed = false
		isLoadingPreviousBlock = true

		Task { [weak self] in
			guard let self else { return }
			let prefix = await persistence.loadBlockAsync(prev)
			await MainActor.run {
				self.isLoadingPreviousBlock = false
				guard self.loadedBlockStart > 0, self.loadedBlockStart - 1 == prev else {
					self.prefetchRearmed = true
					return
				}
				if prefix.isEmpty {
					self.loadedBlockStart = prev
					self.prefetchRearmed = true
					return
				}
				self.scrollAnchorLineId = anchorId
				self.loadedBlockStart = prev
				self.globalLineOffset = prev * self.linesPerBlock
				var merged = prefix
				merged.append(contentsOf: self.visibleLines)
				self.visibleLines = merged
				self.pruneDisplayCachesToVisible()
			}
		}
	}

	/// 無限スクロールで過去を読み込んで `visibleLines` が肥大化し続けるのを防ぐため、
	/// 十分下方向にスクロールしたら先頭ブロックを 1 つ落としてメモリ上限を作る。
	func reportScrollForWindowTrim(contentTopY: CGFloat, firstBlockHeight: CGFloat, focusedLineId: UUID?) {
		guard firstBlockHeight > 1 else { return }
		guard loadedBlockStart < loadedBlockEnd else { return }
		guard !isTrimmingLeadingBlock else { return }

		// 先頭付近まで戻ったら再アーム（振動防止）。
		if contentTopY > -firstBlockHeight * 0.85 {
			trimRearmed = true
		}
		guard trimRearmed else { return }

		// 先頭ブロックが十分見えなくなるほど下へ行ったら 1 ブロック落とす。
		guard contentTopY < -firstBlockHeight * 1.35 else { return }

		let removeCount = min(linesPerBlock, max(0, visibleLines.count))
		guard removeCount > 0, visibleLines.count > removeCount else { return }

		if let fid = focusedLineId, let idx = visibleLines.firstIndex(where: { $0.id == fid }), idx < removeCount {
			return
		}

		isTrimmingLeadingBlock = true
		trimRearmed = false
		let anchorId = visibleLines[removeCount].id

		visibleLines.removeFirst(removeCount)
		globalLineOffset += removeCount
		loadedBlockStart += 1
		pruneDisplayCachesToVisible()
		updateTotalsAndBlocks()
		scrollAnchorLineId = anchorId

		isTrimmingLeadingBlock = false
	}

	func consumeScrollAnchor() -> UUID? {
		let id = scrollAnchorLineId
		scrollAnchorLineId = nil
		return id
	}

	/// 末尾に空行を付けるのは、実データの最終行を含む表示中のみ（検索で途中ブロックだけ見せるときは付けない）
	private func isViewingDocumentTail() -> Bool {
		guard totalPersistedLines > 0 else { return true }
		return globalLineOffset + visibleLines.count >= totalPersistedLines
	}

	/// `UITextView` が空行でも `\n` のみを返すことがあり、それを空行とみなす。
	private func isEffectivelyEmptyLineText(_ text: String) -> Bool {
		text.isEmpty || text.allSatisfy(\.isNewline)
	}

	/// 文書末尾を表示しているとき、末尾の空行パターンを一貫させる（入力用の単一空行など）。
	private func normalizeTrailingEmptyLineIfViewingTail() {
		if visibleLines.isEmpty {
			visibleLines = [MemoLine()]
			return
		}
		guard isViewingDocumentTail() else { return }

		while visibleLines.count > 1,
		      let last = visibleLines.last,
		      let beforeLast = visibleLines.dropLast().last,
		      isEffectivelyEmptyLineText(last.text),
		      isEffectivelyEmptyLineText(beforeLast.text) {
			visibleLines.removeLast()
		}

		if let last = visibleLines.last, !isEffectivelyEmptyLineText(last.text) {
			visibleLines.append(MemoLine())
		}
	}

	/// 起動時のみ、文書末尾の空行をちょうど1行に正規化する。
	private func normalizeTrailingEmptyLineOnBootstrap() {
		normalizeTrailingEmptyLineIfViewingTail()
	}

	/// 表示が永続化された文書の末尾を含むか（末尾の入力用空行を置く対象か）。
	func isViewingPersistedDocumentTail() -> Bool {
		guard totalPersistedLines > 0 else { return true }
		return globalLineOffset + visibleLines.count >= totalPersistedLines
	}

	/// 文書末尾の入力用空行へフォーカスを合わせる準備。必要なら `ensureTrailingEmptyLine` で行を足す。
	func prepareEditorFocusAtBootstrap() -> UUID? {
		let before = visibleLines.count
		normalizeTrailingEmptyLineOnBootstrap()
		if visibleLines.count != before {
			totalPersistedLines = globalLineOffset + visibleLines.count
			updateTotalsAndBlocks()
			scheduleSave()
		}
		return visibleLines.last?.id
	}

	func currentTailLineId() -> UUID? {
		visibleLines.last?.id
	}

	func updateLineRichContent(id: UUID, attributed: NSAttributedString, caretUTF16: Int = 0) {
		/// 空行で勝手に `\n` のみが来ることがあるため、改行だけの内容は空として扱う。
		let original = attributed.string
		let normalized: NSAttributedString = {
			let s = attributed.string
			guard !s.isEmpty, s.allSatisfy(\.isNewline) else { return attributed }
			return NSAttributedString(string: "", attributes: MemoRichTextEncoding.defaultTypingAttributes())
		}()

		guard let idx = visibleLines.firstIndex(where: { $0.id == id }) else { return }
		// 変更前にキャレット情報だけでもキャッシュしておく（別経路の undo 記録で使える）。
		lastKnownCaret = (id, caretUTF16)

		// 差分が大きい（ペースト・画像挿入・タイムスタンプ挿入など）ときは
		// テキストタイピングとは別の undo ステップに区切る。
		let previousLine = visibleLines[idx]
		let previousLen = (previousLine.text as NSString).length
		let newLen = (normalized.string as NSString).length
		let delta = abs(newLen - previousLen)
		let previousAttr = displayAttributed(for: previousLine)
		let previousHadAttachment = MemoRichTextEncoding.containsTextAttachment(previousAttr)
		let newHasAttachment = MemoRichTextEncoding.containsTextAttachment(normalized)
		let recordKind: MemoEditorUndoManager.SnapshotKind =
			(delta > 4 || (newHasAttachment && !previousHadAttachment))
				? .structural
				: .textEdit

		// pre-mutation スナップショットを記録（または既存 entry にコアレス）。
		recordUndoIfNeeded(kind: recordKind, focusedLineId: id, caretUTF16: caretUTF16)

		var line = previousLine
		let wasEmpty = isEffectivelyEmptyLineText(line.text)
		let plain = normalized.string
		line.text = plain
		// 重要: 入力ごとに RTF/Archive を生成すると重いので、ここでは plain の更新と
		// 永続化用の「最新 attributed」をキャッシュするだけに留める。
		pendingRichByLineId[id] = normalized
		line.modifiedAt = Date()
		if original != plain {
		}
		if wasEmpty, !plain.isEmpty {
			line.firstWrittenAt = Date()
		}
		visibleLines[idx] = line
		// 表示キャッシュも最新へ
		displayAttrCacheByLineId[id] = DisplayAttrCacheEntry(fingerprint: fingerprintForDisplay(line: line), attr: normalized)
		let splitFocus = handleAttributedMultilineSplit(at: idx)
		updateTotalsAndBlocks()
		scheduleSave()
		if let (fid, caret) = splitFocus {
			editorFocusRequest = MemoEditorFocusRequest(lineId: fid, caretUTF16: caret)
		} else {
			editorFocusRequest = nil
		}
	}

	func insertLineBreak(id: UUID, attributed: NSAttributedString, range: NSRange) {
		guard let idx = visibleLines.firstIndex(where: { $0.id == id }) else { return }
		recordUndoIfNeeded(kind: .structural, focusedLineId: id, caretUTF16: range.location)

		let mutable = NSMutableAttributedString(attributedString: attributed)
		let replacement = NSAttributedString(string: "\n", attributes: MemoRichTextEncoding.defaultTypingAttributes())
		mutable.replaceCharacters(in: range, with: replacement)

		var line = visibleLines[idx]
		let segments = MemoRichTextEncoding.attributedSplitByNewlines(mutable)
		guard let first = segments.first else { return }

		line.text = first.string
		pendingRichByLineId[line.id] = first
		line.modifiedAt = Date()
		visibleLines[idx] = line

		let now = Date()
		let inserted: [MemoLine] = segments.dropFirst().map { seg in
			let text = seg.string
			let firstWrittenAt = now
			let newLine = MemoLine(text: text, firstWrittenAt: firstWrittenAt, modifiedAt: now)
			pendingRichByLineId[newLine.id] = seg
			return newLine
		}
		visibleLines.insert(contentsOf: inserted, at: idx + 1)
		updateTotalsAndBlocks()
		scheduleSave()

		let focusIndex = idx + min(1, inserted.count)
		guard focusIndex < visibleLines.count else { return }
		let focusLine = visibleLines[focusIndex]
		editorFocusRequest = MemoEditorFocusRequest(lineId: focusLine.id, caretUTF16: 0)
	}

	/// 改行を含む行を分割した場合、カーソルがあるべき最終セグメントの行 ID と UTF-16 オフセット。
	private func handleAttributedMultilineSplit(at index: Int) -> (UUID, Int)? {
		var line = visibleLines[index]
		let attr = line.attributedContent()
		let ns = attr.string as NSString
		guard ns.length > 0 else { return nil }
		var hasNl = false
		for i in 0 ..< ns.length {
			let c = ns.character(at: i)
			if c == 10 || c == 13 {
				hasNl = true
				break
			}
		}
		guard hasNl else { return nil }

		let segments = MemoRichTextEncoding.attributedSplitByNewlines(attr)
		guard segments.count > 1 else { return nil }

		let first = segments[0]
		line.text = first.string
		pendingRichByLineId[line.id] = first
		displayAttrCacheByLineId[line.id] = DisplayAttrCacheEntry(fingerprint: fingerprintForDisplay(line: line), attr: first)
		line.modifiedAt = Date()
		visibleLines[index] = line

		let now = Date()
		let inserted: [MemoLine] = segments.dropFirst().map { seg in
			let t = seg.string
			let l = MemoLine(text: t, firstWrittenAt: now, modifiedAt: now)
			pendingRichByLineId[l.id] = seg
			displayAttrCacheByLineId[l.id] = DisplayAttrCacheEntry(fingerprint: fingerprintForDisplay(line: l), attr: seg)
			return l
		}
		visibleLines.insert(contentsOf: inserted, at: index + 1)
		let lastIndex = index + inserted.count
		let lastLine = visibleLines[lastIndex]
		let caret = (lastLine.text as NSString).length
		return (lastLine.id, caret)
	}

	/// 結合直後の文字列（改行で分割前）上の UTF-16 オフセットを、`handleAttributedMultilineSplit` 後の行 ID と行内オフセットへ写す。
	private func mapGlobalCaretAfterNewlineSplit(mergedLineStartIndex: Int, fullMerge: NSAttributedString, globalCaretUTF16: Int) -> (UUID, Int)? {
		let segments = MemoRichTextEncoding.attributedSplitByNewlines(fullMerge)
		guard segments.count > 1, mergedLineStartIndex + segments.count <= visibleLines.count else { return nil }

		let ns = fullMerge.string as NSString
		var g = 0
		for i in 0 ..< segments.count {
			let L = (segments[i].string as NSString).length
			if globalCaretUTF16 < g + L {
				let line = visibleLines[mergedLineStartIndex + i]
				let local = globalCaretUTF16 - g
				let maxLocal = (line.text as NSString).length
				return (line.id, max(0, min(local, maxLocal)))
			}
			if globalCaretUTF16 == g + L, i + 1 < segments.count {
				let line = visibleLines[mergedLineStartIndex + i + 1]
				return (line.id, 0)
			}
			g += L
			guard g < ns.length else { break }
			let c = ns.character(at: g)
			if c == 13, g + 1 < ns.length, ns.character(at: g + 1) == 10 {
				g += 2
			} else if c == 10 || c == 13 {
				g += 1
			} else {
				break
			}
		}
		let last = mergedLineStartIndex + segments.count - 1
		guard last < visibleLines.count else { return nil }
		let line = visibleLines[last]
		return (line.id, (line.text as NSString).length)
	}

	/// 行頭 Backspace: 現在行を直前行に結合する。戻り値はフォーカス先の行 ID と UTF-16 上のキャレット位置。
	func mergeLineWithPrevious(id: UUID) -> (lineId: UUID, caretUTF16: Int)? {
		guard visibleLines.count > 1, let idx = visibleLines.firstIndex(where: { $0.id == id }), idx > 0 else { return nil }
		recordUndoIfNeeded(kind: .structural, focusedLineId: id, caretUTF16: 0)
		var prev = visibleLines[idx - 1]
		let curr = visibleLines[idx]
		let merged = NSMutableAttributedString(attributedString: prev.attributedContent())
		let joinCaretUTF16 = merged.length
		merged.append(curr.attributedContent())
		let fullMergeSnapshot = NSAttributedString(attributedString: merged)
		prev.text = merged.string
		pendingRichByLineId[prev.id] = merged
		displayAttrCacheByLineId[prev.id] = DisplayAttrCacheEntry(fingerprint: fingerprintForDisplay(line: prev), attr: merged)
		prev.modifiedAt = Date()
		visibleLines[idx - 1] = prev
		visibleLines.remove(at: idx)
		pendingRichByLineId.removeValue(forKey: curr.id)
		displayAttrCacheByLineId.removeValue(forKey: curr.id)
		let mergedIndex = idx - 1
		let splitFocus = handleAttributedMultilineSplit(at: mergedIndex)
		updateTotalsAndBlocks()
		scheduleSave()
		if let splitFocus {
			if let mapped = mapGlobalCaretAfterNewlineSplit(mergedLineStartIndex: mergedIndex, fullMerge: fullMergeSnapshot, globalCaretUTF16: joinCaretUTF16) {
				return mapped
			}
			return splitFocus
		}
		guard mergedIndex < visibleLines.count else { return nil }
		let row = visibleLines[mergedIndex]
		let maxCaret = (row.text as NSString).length
		return (row.id, min(joinCaretUTF16, maxCaret))
	}

	func deleteEmptyLineIfNeeded(id: UUID) {
		guard visibleLines.count > 1, let idx = visibleLines.firstIndex(where: { $0.id == id }) else { return }
		guard visibleLines[idx].text.isEmpty else { return }
		let isLast = idx == visibleLines.count - 1
		if !isLast {
			recordUndoIfNeeded(kind: .structural, focusedLineId: id, caretUTF16: 0)
			visibleLines.remove(at: idx)
			updateTotalsAndBlocks()
			scheduleSave()
		}
	}

	private func updateTotalsAndBlocks() {
		let endGlobal = globalLineOffset + visibleLines.count
		totalPersistedLines = max(totalPersistedLines, endGlobal)
		loadedBlockStart = globalLineOffset / linesPerBlock
		loadedBlockEnd = (globalLineOffset + visibleLines.count - 1) / linesPerBlock
	}

	private func scheduleSave() {
		saveTask?.cancel()
		saveTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 400_000_000)
			await self?.flushToDisk()
		}
	}

	private func mergeFullDocumentByLoadingAll() -> [MemoLine] {
		// 重要: 可視範囲で行の挿入/削除が起きると、以降のグローバル行がシフトする。
		// 旧実装の「ブロック単位で見えている範囲だけ差し替え」だと、未ロード領域がディスクの旧配置のまま残り、
		// 消したはずの空行が“復活”するなどの症状が出る。
		//
		// そこで、ディスク上の全行をベースに「ロードしているブロック範囲」を subrange 置換し、
		// visibleLines の増減（行の挿入/削除）を後続へ正しく反映させる。

		let (savedLPB, savedTotal) = persistence.loadIndex()
		let lpb = savedLPB > 0 ? savedLPB : linesPerBlock
		let diskTotal = max(0, savedTotal)

		var base: [MemoLine] = []
		if diskTotal > 0, lpb > 0 {
			base = persistence.loadAllLines(linesPerBlock: lpb, totalFromIndex: diskTotal)
		}

		if base.count < diskTotal {
			for _ in base.count ..< diskTotal {
				base.append(MemoLine())
			}
		}

		let blockSpan = max(1, loadedBlockEnd - loadedBlockStart + 1)
		let loadedDiskWindowMax = blockSpan * linesPerBlock
		let loadedDiskWindowCount = min(max(0, diskTotal - globalLineOffset), loadedDiskWindowMax)

		if globalLineOffset > base.count {
			for _ in base.count ..< globalLineOffset {
				base.append(MemoLine())
			}
		}

		let start = max(0, min(globalLineOffset, base.count))
		let end = max(start, min(start + loadedDiskWindowCount, base.count))
		base.replaceSubrange(start ..< end, with: visibleLines)
		return base
	}

	/// `mergeFullDocumentByLoadingAll()` と同じ論理結果になるよう、ディスクのサフィックスだけを読み込んで「保存対象の tail」を作る。
	/// - Returns: `prefixCount` はグローバル行の先頭側（ディスク未読）行数。返る `tail` は `prefixCount` からの連続配列。
	private func buildMergedTailForStorage() -> (prefixCount: Int, tail: [MemoLine], storageLinesPerBlock: Int) {
		let (savedLPB, savedTotal) = persistence.loadIndex()
		let lpb = savedLPB > 0 ? savedLPB : linesPerBlock
		let diskTotal = max(0, savedTotal)

		// ディスクが可視範囲の開始より短い場合は、旧経路へフォールバック（現状このケースはほぼ起きない想定）。
		guard diskTotal >= globalLineOffset else {
			let merged = mergeFullDocumentByLoadingAll()
			return (prefixCount: 0, tail: merged, storageLinesPerBlock: lpb)
		}

		let blockSpan = max(1, loadedBlockEnd - loadedBlockStart + 1)
		let loadedDiskWindowMax = blockSpan * linesPerBlock
		let loadedDiskWindowCount = min(max(0, diskTotal - globalLineOffset), loadedDiskWindowMax)

		let suffixStart = globalLineOffset + loadedDiskWindowCount
		let diskSuffix: [MemoLine] = {
			guard suffixStart < diskTotal else { return [] }
			return persistence.loadLinesFromGlobalIndexToEnd(
				startGlobalIndex: suffixStart,
				linesPerBlock: lpb,
				totalLines: diskTotal
			)
		}()

		var tail = visibleLines
		if !diskSuffix.isEmpty {
			tail.append(contentsOf: diskSuffix)
		}
		return (prefixCount: globalLineOffset, tail: tail, storageLinesPerBlock: lpb)
	}

	/// 永続化時は末尾の空行パディングを落とし、再起動で増殖しないようにする。
	private func normalizedDocumentForStorage(_ lines: [MemoLine]) -> [MemoLine] {
		var result = lines
		while let last = result.last, isEffectivelyEmptyLineText(last.text) {
			result.removeLast()
		}
		return result
	}

	private func flushToDisk() async {
		// 入力中に溜めた attributed を、ここでまとめてエンコードして永続化データへ反映する（バックグラウンド）。
		let pendingSnapshot = pendingRichByLineId
		let payloads: [UUID: (rtf: Data?, archive: Data?)] = await Task.detached(priority: .utility) {
			var out: [UUID: (rtf: Data?, archive: Data?)] = [:]
			out.reserveCapacity(pendingSnapshot.count)
			for (id, attr) in pendingSnapshot {
				out[id] = MemoRichTextEncoding.persistPayload(from: attr)
			}
			return out
		}.value

		if !payloads.isEmpty {
			for i in visibleLines.indices {
				let id = visibleLines[i].id
				guard let p = payloads[id] else { continue }
				visibleLines[i].richTextRTF = p.rtf
				visibleLines[i].richTextArchive = p.archive
			}
			for id in payloads.keys {
				pendingRichByLineId.removeValue(forKey: id)
			}
		}

		let (prefixCount, tailBeforeTrim, _) = buildMergedTailForStorage()
		let tail = normalizedDocumentForStorage(tailBeforeTrim)
		let computedTotal = prefixCount + tail.count
		totalPersistedLines = computedTotal

		// 先頭側ブロックは触らず、読み込み済み開始ブロックから末尾だけ上書きする。
		await persistence.saveBlocksFromBlockIndexAsync(
			startBlock: loadedBlockStart,
			linesFromStartBlock: tail,
			linesPerBlock: linesPerBlock,
			totalLines: computedTotal
		)
		let (_, t) = persistence.loadIndex()
		totalPersistedLines = t
		updateTotalsAndBlocks()
		// 本文保存と同じ debounce タイミングで undo スタックも書き出して、
		// 再起動後も履歴が使えるようにする。
		undoManager.saveToDisk(at: persistence.undoStackURL)
		await syncCoordinator?.memoDidFlushToDisk(persistence: persistence, linesPerBlock: linesPerBlock, totalLines: totalPersistedLines)
	}

	func scheduleSearchHitRefresh() {
		searchDebounceTask?.cancel()
		searchDebounceTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 280_000_000)
			guard !Task.isCancelled else { return }
			refreshSearchHits()
		}
	}

	func refreshSearchHits() {
		let kw = searchKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !kw.isEmpty else {
			searchHitContexts = []
			searchMessage = nil
			searchHitGlobalLineIndexSet = []
			return
		}
		let (lpb, total) = persistence.loadIndex()
		guard lpb > 0, total > 0 else {
			searchHitContexts = []
			searchMessage = "No data"
			searchHitGlobalLineIndexSet = []
			return
		}
		searchHitContexts = persistence.searchKeywordLineContexts(
			keyword: kw,
			linesPerBlock: lpb,
			totalLines: total,
			options: .caseInsensitive
		)
		searchMessage = searchHitContexts.isEmpty ? "No matches" : "\(searchHitContexts.count) match\(searchHitContexts.count == 1 ? "" : "es")"
		searchHitGlobalLineIndexSet = Set(searchHitContexts.map(\.globalLineIndex))
	}

	func selectSearchHit(_ hit: MemoSearchHitContext) {
		let kw = searchKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
		searchHighlightKeyword = kw.isEmpty ? nil : kw
		searchHighlightGlobalLineIndex = hit.globalLineIndex
		prepareScrollToGlobalLine(hit.globalLineIndex)
	}

	/// 編集開始などで「選択中の検索ヒット（濃いハイライト）」だけ解除する。
	/// キーワードが残っている限り、他のヒット箇所のハイライト表示は維持する。
	func clearSearchSelectionHighlight() {
		searchHighlightGlobalLineIndex = nil
	}

	/// 検索結果のグローバル行インデックスへ移動（必要ならブロックを読み込む）
	func prepareScrollToGlobalLine(_ globalIndex: Int) {
		guard linesPerBlock > 0, totalPersistedLines > 0 else { return }
		let bc = max(1, blockCount(forTotalLines: totalPersistedLines))
		let targetBlock = min(max(0, globalIndex / linesPerBlock), bc - 1)
		loadedBlockStart = targetBlock
		loadedBlockEnd = targetBlock
		globalLineOffset = targetBlock * linesPerBlock
		visibleLines = persistence.loadBlock(targetBlock)
		pruneDisplayCachesToVisible()
		scrollAnchorLineId = lineId(atGlobalIndex: globalIndex)
	}

	private func lineId(atGlobalIndex gi: Int) -> UUID? {
		let li = gi - globalLineOffset
		guard li >= 0, li < visibleLines.count else { return nil }
		return visibleLines[li].id
	}

	// MARK: - 選択モードの制御

	func enterSelectionMode() {
		guard !isSelectionMode else { return }
		isSelectionMode = true
		selectedLineIds = []
		dragSelectionMode = nil
		dragSelectionSnapshot = []
		dragFirstLineId = nil
	}

	func exitSelectionMode() {
		guard isSelectionMode else { return }
		isSelectionMode = false
		selectedLineIds = []
		dragSelectionMode = nil
		dragSelectionSnapshot = []
		dragFirstLineId = nil
	}

	/// タップによる 1 行トグル。
	func toggleLineSelection(_ id: UUID) {
		guard isSelectionMode else { return }
		if selectedLineIds.contains(id) {
			selectedLineIds.remove(id)
		} else {
			selectedLineIds.insert(id)
		}
	}

	/// ドラッグの始点: 最初に触れた行の選択状態でジェスチャ全体のモード（追加 / 解除）を確定し、
	/// その時点の選択集合をスナップショットとして保持する。以後の extend は常にこのスナップショットを基底に再計算する。
	func beginDragSelection(at id: UUID) {
		guard isSelectionMode else { return }
		dragSelectionSnapshot = selectedLineIds
		dragFirstLineId = id
		dragSelectionMode = dragSelectionSnapshot.contains(id) ? .removing : .adding
		applyDragRange(to: id)
	}

	/// ドラッグ中の追従: 「最初に触れた行」と「現在の指の位置の行」の範囲を都度計算し、
	/// スナップショットに対して union（追加モード）/ subtracting（解除モード）して上書きする。
	/// これによりなぞり戻しで範囲が縮むと、外れた行は基底状態へ戻る。
	func extendDragSelection(to id: UUID) {
		guard isSelectionMode, dragSelectionMode != nil, dragFirstLineId != nil else { return }
		applyDragRange(to: id)
	}

	private func applyDragRange(to currentId: UUID) {
		guard let firstId = dragFirstLineId, let mode = dragSelectionMode else { return }
		guard let firstIdx = visibleLines.firstIndex(where: { $0.id == firstId }),
			  let currIdx = visibleLines.firstIndex(where: { $0.id == currentId })
		else { return }
		let lo = min(firstIdx, currIdx)
		let hi = max(firstIdx, currIdx)
		let rangeIds = Set(visibleLines[lo...hi].map { $0.id })
		switch mode {
		case .adding:
			selectedLineIds = dragSelectionSnapshot.union(rangeIds)
		case .removing:
			selectedLineIds = dragSelectionSnapshot.subtracting(rangeIds)
		}
	}

	func endDragSelection() {
		dragSelectionMode = nil
		dragSelectionSnapshot = []
		dragFirstLineId = nil
	}

	// MARK: - 選択行のコピー・削除

	/// 選択中の行をコピー用に表示順で集める。
	private func selectedLinesInDisplayOrder() -> [MemoLine] {
		guard !selectedLineIds.isEmpty else { return [] }
		return visibleLines.filter { selectedLineIds.contains($0.id) }
	}

	/// 選択行をプレーンテキスト＋リッチテキスト（RTFD）としてペーストボードに書き込む。
	/// 画像が含まれる場合は RTFD 側で運ばれる。
	func copySelectedLines() {
		let lines = selectedLinesInDisplayOrder()
		guard !lines.isEmpty else { return }

		let plain = lines.map { $0.text }.joined(separator: "\n")

		let combined = NSMutableAttributedString()
		for (i, line) in lines.enumerated() {
			if i > 0 {
				combined.append(NSAttributedString(string: "\n", attributes: MemoRichTextEncoding.defaultTypingAttributes()))
			}
			combined.append(displayAttributed(for: line))
		}

		let fullRange = NSRange(location: 0, length: combined.length)
		let rtfdData: Data? = try? combined.data(
			from: fullRange,
			documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
		)

		var item: [String: Any] = [:]
		let plainKey = "public.utf8-plain-text"
		let rtfdKey = "com.apple.flat-rtfd"
		item[plainKey] = plain
		if let rtfdData, !rtfdData.isEmpty {
			item[rtfdKey] = rtfdData
		}
		UIPasteboard.general.setItems([item])
	}

	/// 選択行を削除して永続化にも反映。削除後もフォーカスは一切当てない（呼び出し側で管理）。
	func deleteSelectedLines() {
		guard !selectedLineIds.isEmpty else { return }
		let removeIds = selectedLineIds
		let removedCount = visibleLines.filter { removeIds.contains($0.id) }.count
		guard removedCount > 0 else { return }

		// 先頭に近い選択行をアンカーにしておき、undo/redo の復元時に近傍へスクロールできるようにする。
		let anchorId = visibleLines.first(where: { removeIds.contains($0.id) })?.id
		recordUndoIfNeeded(kind: .structural, focusedLineId: anchorId, caretUTF16: 0)

		let wasViewingTail = isViewingDocumentTail()

		visibleLines.removeAll { removeIds.contains($0.id) }
		for id in removeIds {
			pendingRichByLineId.removeValue(forKey: id)
			displayAttrCacheByLineId.removeValue(forKey: id)
		}
		selectedLineIds = []
		dragSelectionMode = nil
		dragSelectionSnapshot = []
		dragFirstLineId = nil

		// 可視範囲の中で閉じる削除なので、既存の総行数を削除分だけ減らす。
		// 最終的な整合は flushToDisk が `buildMergedTailForStorage` で再計算する。
		totalPersistedLines = max(0, totalPersistedLines - removedCount)

		// 表示が末尾を含むなら、入力用の空行パターンを維持する（既存の最低 1 行ルール）。
		// 末尾を含まないなら、可視が空になっても文書全体としては空ではないのでそのまま。
		if wasViewingTail {
			normalizeTrailingEmptyLineIfViewingTail()
		}

		// block インデックスの再計算。`max()` で縮まない total はすでに上で縮めてある。
		let endGlobal = globalLineOffset + visibleLines.count
		totalPersistedLines = max(totalPersistedLines, endGlobal)
		loadedBlockStart = globalLineOffset / max(1, linesPerBlock)
		let last = max(globalLineOffset, endGlobal - 1)
		loadedBlockEnd = last / max(1, linesPerBlock)

		scheduleSave()
	}

	// MARK: - Undo / Redo

	var canUndo: Bool { undoManager.canUndo }
	var canRedo: Bool { undoManager.canRedo }

	/// 選択モードへの遷移・フォーカス喪失など、「ここで履歴を区切りたい」場面で View から呼ぶ。
	func breakUndoCoalescing() {
		undoManager.breakCoalescing()
	}

	/// View 側のテキスト更新ハンドラから現在のキャレットを通知する。
	/// 直後に起きるかもしれない別経路（画像挿入など）の undo 記録にも使える。
	func noteCaret(lineId: UUID, utf16: Int) {
		lastKnownCaret = (lineId, utf16)
	}

	/// undo を実行する。押す前の現在状態を redo スタックへ退避し、履歴の直前状態へ巻き戻す。
	/// 呼び出し側はフォーカスとキーボードを自分で片付ける想定。
	/// - Returns: 操作対象付近をスクロールで見せるための行 ID（該当行が無ければ nil）。
	func performUndo(currentFocus: (lineId: UUID, utf16: Int)?) -> UUID? {
		guard let peeked = undoManager.peekUndo else { return nil }
		// 現在状態は redo スタックへ渡す。そのアンカーは今から undo しようとしている編集地点
		//（＝ peeked のアンカー）にそろえて、redo 時も同じ付近に戻せるようにする。
		let current = makeCurrentSnapshot(
			focusedLineId: peeked.focusedLineId,
			caretUTF16: currentFocus?.utf16 ?? 0,
			anchorGlobalIndex: peeked.anchorGlobalIndex,
			kind: .structural
		)
		guard let target = undoManager.popUndo(current: current) else { return nil }
		applySnapshot(target)
		return scrollTargetLineId(for: target)
	}

	func performRedo(currentFocus: (lineId: UUID, utf16: Int)?) -> UUID? {
		guard let peeked = undoManager.peekRedo else { return nil }
		let current = makeCurrentSnapshot(
			focusedLineId: peeked.focusedLineId,
			caretUTF16: currentFocus?.utf16 ?? 0,
			anchorGlobalIndex: peeked.anchorGlobalIndex,
			kind: .structural
		)
		guard let target = undoManager.popRedo(current: current) else { return nil }
		applySnapshot(target)
		return scrollTargetLineId(for: target)
	}

	private func recordUndoIfNeeded(kind: MemoEditorUndoManager.SnapshotKind, focusedLineId: UUID?, caretUTF16: Int) {
		guard !isApplyingUndoRedo else { return }
		let anchorIndex = anchorGlobalIndexForCurrentState(focusedLineId: focusedLineId)
		undoManager.recordIfNeeded(kind: kind) { [self] in
			makeCurrentSnapshot(
				focusedLineId: focusedLineId,
				caretUTF16: caretUTF16,
				anchorGlobalIndex: anchorIndex,
				kind: kind
			)
		}
	}

	/// `focusedLineId` が示す行のグローバルインデックス。
	/// 明示的にない場合は `visibleLines` の中央行を使う（選択モード削除などの保険）。
	private func anchorGlobalIndexForCurrentState(focusedLineId: UUID?) -> Int? {
		if let fid = focusedLineId,
		   let localIdx = visibleLines.firstIndex(where: { $0.id == fid }) {
			return globalLineOffset + localIdx
		}
		guard !visibleLines.isEmpty else { return nil }
		return globalLineOffset + visibleLines.count / 2
	}

	private func makeCurrentSnapshot(
		focusedLineId: UUID?,
		caretUTF16: Int,
		anchorGlobalIndex: Int?,
		kind: MemoEditorUndoManager.SnapshotKind
	) -> MemoEditorUndoManager.Snapshot {
		var pending: [MemoEditorUndoManager.PendingRichEntry] = []
		pending.reserveCapacity(pendingRichByLineId.count)
		for (id, attr) in pendingRichByLineId {
			if let data = MemoRichTextEncoding.archivedAttributedData(from: attr) {
				pending.append(MemoEditorUndoManager.PendingRichEntry(lineId: id, archive: data))
			}
		}
		return MemoEditorUndoManager.Snapshot(
			visibleLines: visibleLines,
			pendingRich: pending,
			globalLineOffset: globalLineOffset,
			loadedBlockStart: loadedBlockStart,
			loadedBlockEnd: loadedBlockEnd,
			totalPersistedLines: totalPersistedLines,
			focusedLineId: focusedLineId,
			caretUTF16: caretUTF16,
			anchorGlobalIndex: anchorGlobalIndex,
			capturedAt: Date(),
			kind: kind
		)
	}

	/// スナップショット適用後、その「操作された部分」へ近い行の ID を返す。
	/// - 既存の `focusedLineId` が restored visibleLines にあればそれを優先。
	/// - 無ければ `anchorGlobalIndex` を使って近傍の行にフォールバック。
	private func scrollTargetLineId(for snap: MemoEditorUndoManager.Snapshot) -> UUID? {
		if let fid = snap.focusedLineId,
		   visibleLines.contains(where: { $0.id == fid }) {
			return fid
		}
		guard !visibleLines.isEmpty else { return nil }
		guard let global = snap.anchorGlobalIndex else {
			return visibleLines[visibleLines.count / 2].id
		}
		let local = global - globalLineOffset
		let clamped = max(0, min(local, visibleLines.count - 1))
		return visibleLines[clamped].id
	}

	private func applySnapshot(_ snap: MemoEditorUndoManager.Snapshot) {
		isApplyingUndoRedo = true
		defer { isApplyingUndoRedo = false }

		visibleLines = snap.visibleLines
		globalLineOffset = snap.globalLineOffset
		loadedBlockStart = snap.loadedBlockStart
		loadedBlockEnd = snap.loadedBlockEnd
		totalPersistedLines = snap.totalPersistedLines

		// pending attr を復元。archive を NSAttributedString に戻す。
		var restored: [UUID: NSAttributedString] = [:]
		for entry in snap.pendingRich {
			if let attr = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: entry.archive) {
				restored[entry.lineId] = attr
			}
		}
		pendingRichByLineId = restored

		// 表示キャッシュは作り直す（fingerprint で自動的に次回 displayAttributed で再生成される）。
		displayAttrCacheByLineId.removeAll()
		// 選択モード中に undo/redo は走らない想定だが、念のため選択をクリア。
		selectedLineIds = []
		searchHighlightGlobalLineIndex = nil

		// 次回 visibleLines が変わってもキャッシュが visible に追従するように整理。
		pruneDisplayCachesToVisible()

		// ディスクへ書き戻す。undo/redo 自体も scheduleSave で 400ms 後にまとめて保存される。
		scheduleSave()
	}

}
