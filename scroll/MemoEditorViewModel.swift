//
//  MemoEditorViewModel.swift
//  scroll
//

import Foundation
import Observation
import SwiftUI

private let debugLogPath = "/Users/koichi/in_progress/scroll/.cursor/debug-da28db.log"
private let debugSessionId = "da28db"
private let debugRunId = "pre-fix"

private func appendDebugLog(location: String, message: String, data: [String: Any], hypothesisId: String) {
	let payload: [String: Any] = [
		"sessionId": debugSessionId,
		"runId": debugRunId,
		"hypothesisId": hypothesisId,
		"location": location,
		"message": message,
		"data": data,
		"timestamp": Int(Date().timeIntervalSince1970 * 1000)
	]
	guard let json = try? JSONSerialization.data(withJSONObject: payload),
	      var line = String(data: json, encoding: .utf8)
	else { return }
	line.append("\n")
	if let data = line.data(using: .utf8) {
		if FileManager.default.fileExists(atPath: debugLogPath),
		   let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: debugLogPath)) {
			try? handle.seekToEnd()
			try? handle.write(contentsOf: data)
			try? handle.close()
		} else {
			try? data.write(to: URL(fileURLWithPath: debugLogPath), options: .atomic)
		}
	}
}

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
	private weak var syncCoordinator: MemoSyncCoordinating?

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

	private var searchDebounceTask: Task<Void, Never>?

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
			globalLineOffset = 0
			loadedBlockStart = 0
			loadedBlockEnd = 0
			totalPersistedLines = 1
			scheduleSave()
			return
		}

		let lastBlock = (totalPersistedLines - 1) / linesPerBlock
		loadedBlockStart = lastBlock
		loadedBlockEnd = lastBlock
		globalLineOffset = lastBlock * linesPerBlock
		visibleLines = persistence.loadBlock(lastBlock)
		// #region agent log
		appendDebugLog(
			location: "MemoEditorViewModel.swift:bootstrap",
			message: "loaded last block on bootstrap",
			data: [
				"totalPersistedLines": totalPersistedLines,
				"linesPerBlock": linesPerBlock,
				"lastBlock": lastBlock,
				"visibleCount": visibleLines.count,
				"visibleTrailingEmpty": trailingEmptyLineCount(in: visibleLines)
			],
			hypothesisId: "H2"
		)
		// #endregion
		normalizeTrailingEmptyLineOnBootstrap()
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
	func reportScrollForInfiniteScroll(contentTopY: CGFloat, firstBlockHeight: CGFloat) {
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
			}
		}
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

	private func trailingEmptyLineCount(in lines: [MemoLine]) -> Int {
		var count = 0
		for line in lines.reversed() {
			guard isEffectivelyEmptyLineText(line.text) else { break }
			count += 1
		}
		return count
	}

	/// 起動時のみ、文書末尾の空行をちょうど1行に正規化する。
	private func normalizeTrailingEmptyLineOnBootstrap() {
		let beforeCount = visibleLines.count
		let beforeTrailing = trailingEmptyLineCount(in: visibleLines)
		if visibleLines.isEmpty {
			visibleLines = [MemoLine()]
			// #region agent log
			appendDebugLog(
				location: "MemoEditorViewModel.swift:normalizeTrailingEmptyLineOnBootstrap",
				message: "bootstrap normalize empty document",
				data: [
					"beforeCount": beforeCount,
					"beforeTrailingEmpty": beforeTrailing,
					"afterCount": visibleLines.count,
					"afterTrailingEmpty": trailingEmptyLineCount(in: visibleLines)
				],
				hypothesisId: "H2"
			)
			// #endregion
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
		// #region agent log
		appendDebugLog(
			location: "MemoEditorViewModel.swift:normalizeTrailingEmptyLineOnBootstrap",
			message: "bootstrap normalize trailing empty lines",
			data: [
				"beforeCount": beforeCount,
				"beforeTrailingEmpty": beforeTrailing,
				"afterCount": visibleLines.count,
				"afterTrailingEmpty": trailingEmptyLineCount(in: visibleLines),
				"totalPersistedLines": totalPersistedLines,
				"globalLineOffset": globalLineOffset
			],
			hypothesisId: "H2"
		)
		// #endregion
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

	func updateLineRichContent(id: UUID, attributed: NSAttributedString) {
		/// 空行で勝手に `\n` のみが来ることがあるため、改行だけの内容は空として扱う。
		let original = attributed.string
		let normalized: NSAttributedString = {
			let s = attributed.string
			guard !s.isEmpty, s.allSatisfy(\.isNewline) else { return attributed }
			return NSAttributedString(string: "", attributes: MemoRichTextEncoding.defaultTypingAttributes())
		}()

		guard let idx = visibleLines.firstIndex(where: { $0.id == id }) else { return }
		var line = visibleLines[idx]
		let wasEmpty = isEffectivelyEmptyLineText(line.text)
		let plain = normalized.string
		line.text = plain
		MemoRichTextEncoding.assignPersistence(normalized, to: &line)
		line.modifiedAt = Date()
		if original != plain {
			// #region agent log
			appendDebugLog(
				location: "MemoEditorViewModel.swift:updateLineRichContent",
				message: "normalized newline-only edit",
				data: [
					"lineId": id.uuidString,
					"originalLength": original.count,
					"normalizedLength": plain.count,
					"visibleCount": visibleLines.count,
					"trailingEmptyVisible": trailingEmptyLineCount(in: visibleLines)
				],
				hypothesisId: "H3"
			)
			// #endregion
		}
		if wasEmpty, !plain.isEmpty {
			line.firstWrittenAt = Date()
		}
		visibleLines[idx] = line
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

		let mutable = NSMutableAttributedString(attributedString: attributed)
		let replacement = NSAttributedString(string: "\n", attributes: MemoRichTextEncoding.defaultTypingAttributes())
		mutable.replaceCharacters(in: range, with: replacement)

		var line = visibleLines[idx]
		let segments = MemoRichTextEncoding.attributedSplitByNewlines(mutable)
		guard let first = segments.first else { return }
		// #region agent log
		appendDebugLog(
			location: "MemoEditorViewModel.swift:insertLineBreak",
			message: "user inserted line break",
			data: [
				"lineId": id.uuidString,
				"rangeLocation": range.location,
				"rangeLength": range.length,
				"segmentCount": segments.count,
				"visibleCountBeforeInsert": visibleLines.count
			],
			hypothesisId: "H4"
		)
		// #endregion

		line.text = first.string
		MemoRichTextEncoding.assignPersistence(first, to: &line)
		line.modifiedAt = Date()
		visibleLines[idx] = line

		let now = Date()
		let inserted: [MemoLine] = segments.dropFirst().map { seg in
			let text = seg.string
			let firstWrittenAt = text.isEmpty ? now : now
			var newLine = MemoLine(text: text, firstWrittenAt: firstWrittenAt, modifiedAt: now)
			MemoRichTextEncoding.assignPersistence(seg, to: &newLine)
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
		MemoRichTextEncoding.assignPersistence(first, to: &line)
		line.modifiedAt = Date()
		visibleLines[index] = line

		let now = Date()
		let inserted: [MemoLine] = segments.dropFirst().map { seg in
			let t = seg.string
			var l = MemoLine(text: t, firstWrittenAt: now, modifiedAt: now)
			MemoRichTextEncoding.assignPersistence(seg, to: &l)
			return l
		}
		visibleLines.insert(contentsOf: inserted, at: index + 1)
		let lastIndex = index + inserted.count
		let lastLine = visibleLines[lastIndex]
		let caret = (lastLine.text as NSString).length
		return (lastLine.id, caret)
	}

	/// 行頭 Backspace: 現在行を直前行に結合する。戻り値はフォーカス先の行 ID と UTF-16 上のキャレット位置。
	func mergeLineWithPrevious(id: UUID) -> (lineId: UUID, caretUTF16: Int)? {
		guard visibleLines.count > 1, let idx = visibleLines.firstIndex(where: { $0.id == id }), idx > 0 else { return nil }
		var prev = visibleLines[idx - 1]
		let curr = visibleLines[idx]
		let merged = NSMutableAttributedString(attributedString: prev.attributedContent())
		merged.append(curr.attributedContent())
		prev.text = merged.string
		MemoRichTextEncoding.assignPersistence(merged, to: &prev)
		prev.modifiedAt = Date()
		visibleLines[idx - 1] = prev
		visibleLines.remove(at: idx)
		let mergedIndex = idx - 1
		let splitFocus = handleAttributedMultilineSplit(at: mergedIndex)
		updateTotalsAndBlocks()
		scheduleSave()
		if let (fid, caret) = splitFocus {
			return (fid, caret)
		}
		guard mergedIndex < visibleLines.count else { return nil }
		let row = visibleLines[mergedIndex]
		let caret = (row.text as NSString).length
		return (row.id, caret)
	}

	func deleteEmptyLineIfNeeded(id: UUID) {
		guard visibleLines.count > 1, let idx = visibleLines.firstIndex(where: { $0.id == id }) else { return }
		guard visibleLines[idx].text.isEmpty else { return }
		let isLast = idx == visibleLines.count - 1
		if !isLast {
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
		// #region agent log
		appendDebugLog(
			location: "MemoEditorViewModel.swift:scheduleSave",
			message: "scheduled save task",
			data: [
				"totalPersistedLines": totalPersistedLines,
				"globalLineOffset": globalLineOffset,
				"visibleCount": visibleLines.count,
				"visibleTrailingEmpty": trailingEmptyLineCount(in: visibleLines)
			],
			hypothesisId: "H5"
		)
		// #endregion
		saveTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 400_000_000)
			// #region agent log
			appendDebugLog(
				location: "MemoEditorViewModel.swift:scheduleSave.task",
				message: "save task woke up",
				data: [
					"taskCancelled": Task.isCancelled
				],
				hypothesisId: "H5"
			)
			// #endregion
			await self?.flushToDisk()
		}
	}

	private func mergeFullDocument() -> [MemoLine] {
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

	/// 永続化時は末尾の空行パディングを落とし、再起動で増殖しないようにする。
	private func normalizedDocumentForStorage(_ lines: [MemoLine]) -> [MemoLine] {
		var result = lines
		while let last = result.last, isEffectivelyEmptyLineText(last.text) {
			result.removeLast()
		}
		// #region agent log
		appendDebugLog(
			location: "MemoEditorViewModel.swift:normalizedDocumentForStorage",
			message: "trimmed trailing empty lines before save",
			data: [
				"beforeCount": lines.count,
				"beforeTrailingEmpty": trailingEmptyLineCount(in: lines),
				"afterCount": result.count,
				"afterTrailingEmpty": trailingEmptyLineCount(in: result)
			],
			hypothesisId: "H1"
		)
		// #endregion
		return result
	}

	private func flushToDisk() async {
		let mergedBeforeTrim = mergeFullDocument()
		// #region agent log
		appendDebugLog(
			location: "MemoEditorViewModel.swift:flushToDisk",
			message: "flush before trim",
			data: [
				"mergedCount": mergedBeforeTrim.count,
				"mergedTrailingEmpty": trailingEmptyLineCount(in: mergedBeforeTrim),
				"totalPersistedLines": totalPersistedLines,
				"globalLineOffset": globalLineOffset,
				"visibleCount": visibleLines.count,
				"visibleTrailingEmpty": trailingEmptyLineCount(in: visibleLines)
			],
			hypothesisId: "H1"
		)
		// #endregion
		let merged = normalizedDocumentForStorage(mergedBeforeTrim)
		totalPersistedLines = merged.count
		persistence.saveAllLines(merged, linesPerBlock: linesPerBlock)
		let (_, t) = persistence.loadIndex()
		totalPersistedLines = t
		// #region agent log
		appendDebugLog(
			location: "MemoEditorViewModel.swift:flushToDisk",
			message: "flush after save",
			data: [
				"savedTotalLines": t,
				"savedTrailingEmpty": trailingEmptyLineCount(in: merged)
			],
			hypothesisId: "H1"
		)
		// #endregion
		updateTotalsAndBlocks()
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
			searchMessage = "データがありません"
			searchHitGlobalLineIndexSet = []
			return
		}
		searchHitContexts = persistence.searchKeywordLineContexts(
			keyword: kw,
			linesPerBlock: lpb,
			totalLines: total,
			options: .caseInsensitive
		)
		searchMessage = searchHitContexts.isEmpty ? "該当なし" : "\(searchHitContexts.count) 件"
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
		scrollAnchorLineId = lineId(atGlobalIndex: globalIndex)
	}

	private func lineId(atGlobalIndex gi: Int) -> UUID? {
		let li = gi - globalLineOffset
		guard li >= 0, li < visibleLines.count else { return nil }
		return visibleLines[li].id
	}
}
