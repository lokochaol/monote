//
//  MemoEditorView.swift
//  scroll
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private func appendViewDebugLog(message: String, data: [String: Any], hypothesisId: String) {
	let payload: [String: Any] = [
		"sessionId": "da28db",
		"runId": "pre-fix",
		"hypothesisId": hypothesisId,
		"location": "MemoEditorView.swift",
		"message": message,
		"data": data,
		"timestamp": Int(Date().timeIntervalSince1970 * 1000)
	]
	guard let json = try? JSONSerialization.data(withJSONObject: payload),
	      var line = String(data: json, encoding: .utf8)
	else { return }
	line.append("\n")
	let url = URL(fileURLWithPath: "/Users/koichi/in_progress/scroll/.cursor/debug-da28db.log")
	if let data = line.data(using: .utf8) {
		if FileManager.default.fileExists(atPath: url.path),
		   let handle = try? FileHandle(forWritingTo: url) {
			try? handle.seekToEnd()
			try? handle.write(contentsOf: data)
			try? handle.close()
		} else {
			try? data.write(to: url, options: .atomic)
		}
	}
}

private func bootstrapScreenHeight() -> CGFloat {
#if canImport(UIKit)
	max(UIScreen.main.bounds.height, 320)
#else
720
#endif
}

private enum MemoEditorScrollAnimation {
	/// フォーカス行をキーボード付近へ寄せるときのスクロール
	static let focusLine = Animation.easeInOut(duration: 0.48)
	/// 無限スクロールの先頭アンカー復帰
	static let blockPrefetchAnchor = Animation.easeInOut(duration: 0.4)
}

struct MemoEditorView: View {
	@Environment(\.scenePhase) private var scenePhase
	@State private var model = MemoEditorViewModel()
	/// UITextView の第一応答者と並べるため SwiftUI の @FocusState は使わない。
	@State private var focusedLineId: UUID?
	@State private var showSearch = false
	@State private var didBootstrap = false
	@State private var lineIdToScrollIntoView: UUID?
	@State private var scrollThrottleTask: Task<Void, Never>?
	@State private var pendingContentTopY: CGFloat = 0
	@State private var mergeCaret: (lineId: UUID, utf16: Int)?
	@State private var keyboardTopScreenY: CGFloat?
	@State private var keyboardScrollTask: Task<Void, Never>?
	@State private var focusedSelectionLength: Int = 0
	@State private var lastSelectionInteractionAt: Date = .distantPast

	private let scrollSampleNanos: UInt64 = 24_000_000
	/// 行マージで前行が先に first responder になってから現在行を消す（キーボードのちらつき防止）。
	private let mergeLineDeferNanos: UInt64 = 48_000_000
	private let keyboardDismissDragMinDistance: CGFloat = 36
	private let keyboardDismissScrollMinTranslation: CGFloat = 28
	private let keyboardDismissIgnoreAfterSelectionSeconds: TimeInterval = 0.45
	private let scrollLineIntoViewDelayNanos: UInt64 = 48_000_000
	private let keyboardAdjustScrollDelayNanos: UInt64 = 120_000_000

	var body: some View {
		NavigationStack {
			ZStack(alignment: .top) {
				MemoJournalPalette.paperBackground()
				ScrollViewReader { proxy in
					ScrollView {
						LazyVStack(alignment: .leading, spacing: 0) {
							headSentinel
							ForEach(Array(model.visibleLines.enumerated()), id: \.element.id) { index, line in
								lineRow(line: line, index: index)
							}
						}
						.padding(.horizontal, MemoJournalPalette.horizontalInset)
						.padding(.top, 10)
						.padding(.bottom, 28)
					}
					.scrollDismissesKeyboard(.never)
					.scrollContentBackground(.hidden)
				.safeAreaInset(edge: .bottom, spacing: 0) {
					if keyboardTopScreenY == nil {
						bottomSearchEntryBar
					}
				}
				.coordinateSpace(name: "memoScroll")
				.simultaneousGesture(contentScrollDismissKeyboardGesture)
				.onChange(of: model.scrollAnchorLineId) { _, newId in
					guard let newId else { return }
					Task { @MainActor in
						try? await Task.sleep(nanoseconds: 32_000_000)
						withAnimation(MemoEditorScrollAnimation.blockPrefetchAnchor) {
							proxy.scrollTo(newId, anchor: .top)
						}
						_ = model.consumeScrollAnchor()
					}
				}
				.onChange(of: lineIdToScrollIntoView) { _, id in
					guard let id else { return }
					Task { @MainActor in
						try? await Task.sleep(nanoseconds: scrollLineIntoViewDelayNanos)
						withAnimation(MemoEditorScrollAnimation.focusLine) {
							proxy.scrollTo(id, anchor: .bottom)
						}
						lineIdToScrollIntoView = nil
					}
				}
				}
			}
			.onChange(of: focusedLineId) { _, newId in
				focusedSelectionLength = 0
				lastSelectionInteractionAt = .distantPast
				guard let id = newId else { return }
				lineIdToScrollIntoView = id
			}
			.onChange(of: keyboardTopScreenY) { _, newTop in
				keyboardScrollTask?.cancel()
				guard newTop != nil, focusedLineId != nil else { return }
				keyboardScrollTask = Task { @MainActor in
					try? await Task.sleep(nanoseconds: keyboardAdjustScrollDelayNanos)
					guard !Task.isCancelled, let id = focusedLineId else { return }
					lineIdToScrollIntoView = id
				}
			}
			.onAppear {
				if !didBootstrap {
					didBootstrap = true
					model.attachSyncCoordinator(NoOpMemoSyncCoordinator.shared)
					model.bootstrap(screenHeight: bootstrapScreenHeight())
					restoreEditorFocusAtBootstrap()
					return
				}
			}
			.onChange(of: scenePhase) { oldPhase, newPhase in
				// #region agent log
				appendViewDebugLog(
					message: "scenePhase changed",
					data: [
						"oldPhase": String(describing: oldPhase),
						"newPhase": String(describing: newPhase),
						"didBootstrap": didBootstrap,
						"isViewingTail": model.isViewingPersistedDocumentTail()
					],
					hypothesisId: "H6"
				)
				// #endregion
				// 起動時以外（バックグラウンド復帰など）では、編集中のカーソル位置を尊重して
				// 自動で末尾へフォーカス/スクロールしない。
			}
			.onChange(of: model.editorFocusRequest) { _, req in
				guard let req else { return }
				focusedLineId = req.lineId
				mergeCaret = (req.lineId, req.caretUTF16)
				lineIdToScrollIntoView = req.lineId
				model.editorFocusRequest = nil
			}
			.onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
				guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
				let screenH = UIScreen.main.bounds.height
				if frame.minY >= screenH - 0.5 {
					keyboardTopScreenY = nil
				} else {
					keyboardTopScreenY = frame.minY
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
				keyboardTopScreenY = nil
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
				// #region agent log
				appendViewDebugLog(
					message: "application will resign active",
					data: [
						"focusedLineId": focusedLineId?.uuidString ?? "",
						"hasKeyboardTop": keyboardTopScreenY != nil
					],
					hypothesisId: "H7"
				)
				// #endregion
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
				// #region agent log
				appendViewDebugLog(
					message: "application did enter background",
					data: [
						"focusedLineId": focusedLineId?.uuidString ?? "",
						"hasKeyboardTop": keyboardTopScreenY != nil
					],
					hypothesisId: "H6"
				)
				// #endregion
			}
			.toolbar(.hidden, for: .navigationBar)
			.sheet(isPresented: $showSearch) {
				MemoKeywordSearchSheet(model: model, isPresented: $showSearch)
			}
		}
	}

	private var headSentinel: some View {
		Color.clear
			.frame(height: 1)
			.onGeometryChange(for: CGFloat.self) { proxy in
				proxy.frame(in: .named("memoScroll")).minY
			} action: { _, newY in
				reportScrollContentTopChange(newY)
			}
	}

	private func reportScrollContentTopChange(_ y: CGFloat) {
		pendingContentTopY = y
		scrollThrottleTask?.cancel()
		scrollThrottleTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: scrollSampleNanos)
			guard !Task.isCancelled else { return }
			model.reportScrollForInfiniteScroll(
				contentTopY: pendingContentTopY,
				firstBlockHeight: model.estimatedFirstBlockHeight()
			)
		}
	}

	/// 初回起動時のみ、必要なら末尾へ入力用空行を1つ足してそこへフォーカスする。
	private func restoreEditorFocusAtBootstrap() {
		guard let id = model.prepareEditorFocusAtBootstrap() else { return }
		mergeCaret = nil
		lineIdToScrollIntoView = id
		focusedLineId = id
	}

	/// 復帰時は既存の末尾行へフォーカスするだけで、自動で空行は足さない。
	private func focusCurrentTailLine(resetResponderFirst: Bool) {
		guard let id = model.currentTailLineId() else { return }
		mergeCaret = nil
		lineIdToScrollIntoView = id
		if resetResponderFirst {
			focusedLineId = nil
			Task { @MainActor in
				try? await Task.yield()
				focusedLineId = id
			}
		} else {
			focusedLineId = id
		}
	}

	private var contentScrollDismissKeyboardGesture: some Gesture {
		DragGesture(minimumDistance: keyboardDismissDragMinDistance, coordinateSpace: .global)
			.onEnded { value in
				guard focusedLineId != nil else { return }
				if focusedSelectionLength > 0 { return }
				if Date().timeIntervalSince(lastSelectionInteractionAt) < keyboardDismissIgnoreAfterSelectionSeconds { return }
				guard abs(value.translation.height) > keyboardDismissScrollMinTranslation else { return }
				let startY = value.startLocation.y
				if let top = keyboardTopScreenY, startY >= top - 1 {
					return
				}
				focusedLineId = nil
				resignFirstResponderGlobally()
			}
	}

#if canImport(UIKit)
	private func resignFirstResponderGlobally() {
		UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
	}
#else
	private func resignFirstResponderGlobally() {}
#endif

	private var bottomSearchEntryBar: some View {
		let q = model.searchKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
		let fieldShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
		return Button {
			focusedLineId = nil
			resignFirstResponderGlobally()
			showSearch = true
		} label: {
			HStack(spacing: 10) {
				Image(systemName: "magnifyingglass")
					.font(.system(size: 17, weight: .medium))
					.foregroundStyle(.secondary)
				Text(q.isEmpty ? "検索" : q)
					.font(.body)
					.foregroundStyle(q.isEmpty ? .secondary : .primary)
					.lineLimit(1)
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 11)
			.frame(maxWidth: .infinity)
			.contentShape(fieldShape)
			.glassEffect(.regular, in: fieldShape)
		}
		.buttonStyle(.plain)
		.padding(.horizontal, MemoJournalPalette.horizontalInset)
		.padding(.bottom, 8)
	}

	private func lineRow(line: MemoLine, index: Int) -> some View {
		let globalIdx = model.globalLineOffset + index
		let (highlightQ, highlightAlpha): (String?, CGFloat?) = {
			guard let kw = model.searchHighlightKeyword, !kw.isEmpty else { return (nil, nil) }
			guard model.searchHitGlobalLineIndexSet.contains(globalIdx) else { return (nil, nil) }
			let isSelected = (model.searchHighlightGlobalLineIndex == globalIdx)
			return (kw, isSelected ? 0.62 : 0.32)
		}()
		let row = model.visibleLines.first(where: { $0.id == line.id }) ?? line
		return VStack(alignment: .leading, spacing: 4) {
			if let label = dateLabelIfNeeded(for: line, at: index) {
				Text(label)
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary.opacity(0.75))
					.padding(.horizontal, 2)
					.padding(.top, index == 0 ? 2 : 10)
			}
			MemoLineTextView(
				rtfData: row.richTextRTF,
				archiveData: row.richTextArchive,
				plainText: row.text,
				isFocused: focusedLineId == line.id,
				highlightQuery: highlightQ,
				highlightAlpha: highlightAlpha,
				pendingCaretUTF16: Binding(
					get: {
						guard let m = mergeCaret, m.lineId == line.id else { return nil }
						return m.utf16
					},
					set: { newVal in
						if newVal == nil, mergeCaret?.lineId == line.id { mergeCaret = nil }
					}
				),
				onAttributedEdit: { attr in
					model.updateLineRichContent(id: line.id, attributed: attr)
				},
				onInsertLineBreak: { attr, range in
					model.insertLineBreak(id: line.id, attributed: attr, range: range)
				},
				onBackspaceAtBeginning: {
					guard let idx = model.visibleLines.firstIndex(where: { $0.id == line.id }), idx > 0 else { return }
					let prevId = model.visibleLines[idx - 1].id
					let currId = line.id
					focusedLineId = prevId
					mergeCaret = nil
					Task { @MainActor in
						try? await Task.sleep(nanoseconds: mergeLineDeferNanos)
						guard let r = model.mergeLineWithPrevious(id: currId) else { return }
						focusedLineId = r.lineId
						mergeCaret = (r.lineId, r.caretUTF16)
						lineIdToScrollIntoView = r.lineId
					}
				},
				onEditingBegan: {
					model.clearSearchSelectionHighlight()
					focusedLineId = line.id
				},
				onSelectionInteraction: { selectionLen in
					guard focusedLineId == line.id else { return }
					let previousLength = focusedSelectionLength
					focusedSelectionLength = selectionLen
					if selectionLen > 0 || previousLength > 0 {
						lastSelectionInteractionAt = Date()
					}
				}
			)
			.frame(maxWidth: .infinity, alignment: .leading)
			.fixedSize(horizontal: false, vertical: true)
		}
		.id(line.id)
	}

	private func dateLabelIfNeeded(for line: MemoLine, at index: Int) -> String? {
		guard !line.text.isEmpty else { return nil }
		let cal = Calendar.current
		var prevDay: Date?
		if index > 0 {
			for j in (0 ..< index).reversed() {
				let other = model.visibleLines[j]
				if !other.text.isEmpty {
					prevDay = cal.startOfDay(for: other.firstWrittenAt)
					break
				}
			}
		}
		let day = cal.startOfDay(for: line.firstWrittenAt)
		if let prevDay, day == prevDay { return nil }
		let f = DateFormatter()
		f.locale = Locale(identifier: "ja_JP")
		f.dateFormat = "yyyy年M月d日"
		return f.string(from: line.firstWrittenAt)
	}
}

private struct MemoKeywordSearchSheet: View {
	@Bindable var model: MemoEditorViewModel
	@Binding var isPresented: Bool
	@FocusState private var keywordFieldFocused: Bool

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				TextField("キーワード", text: $model.searchKeywordText)
					.textFieldStyle(.roundedBorder)
					.padding(.horizontal)
					.padding(.top, 12)
					.focused($keywordFieldFocused)
					.submitLabel(.search)
					.onChange(of: model.searchKeywordText) { _, _ in
						model.scheduleSearchHitRefresh()
					}
				if let msg = model.searchMessage {
					Text(msg)
						.font(.caption)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal)
						.padding(.top, 6)
				}
				List {
					ForEach(model.searchHitContexts) { hit in
						Button {
							model.selectSearchHit(hit)
							isPresented = false
						} label: {
							MemoSearchHitRow(hit: hit, keyword: trimmedKeyword)
								.frame(maxWidth: .infinity, alignment: .leading)
								.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
					}
				}
				.listStyle(.plain)
			}
			.navigationTitle("検索")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("閉じる") { isPresented = false }
				}
			}
			.onAppear {
				model.refreshSearchHits()
				keywordFieldFocused = true
			}
		}
	}

	private var trimmedKeyword: String {
		model.searchKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

private struct MemoSearchHitRow: View {
	let hit: MemoSearchHitContext
	let keyword: String

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(searchHitLineAttributed(hit.previousLine, dimmed: true))
			.frame(maxWidth: .infinity, alignment: .leading)
			Text(searchHitLineAttributed(hit.matchLine, dimmed: false))
				.frame(maxWidth: .infinity, alignment: .leading)
			Text(searchHitLineAttributed(hit.nextLine, dimmed: true))
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle())
	}

	private func searchHitLineAttributed(_ line: String, dimmed: Bool) -> AttributedString {
		let display = line.isEmpty ? " " : line
		var a = AttributedString(display)
		a.font = .subheadline
		a.foregroundColor = dimmed ? .secondary : .primary
		guard !keyword.isEmpty, !line.isEmpty else { return a }
		let ns = line as NSString
		var search = NSRange(location: 0, length: ns.length)
		while search.length > 0 {
			let r = ns.range(of: keyword, options: .caseInsensitive, range: search)
			if r.location == NSNotFound { break }
			if let swiftRange = Range(r, in: line),
			   let low = AttributedString.Index(swiftRange.lowerBound, within: a),
			   let high = AttributedString.Index(swiftRange.upperBound, within: a) {
				a[low..<high].backgroundColor = Color.yellow.opacity(0.42)
			}
			let next = r.location + max(1, r.length)
			search = NSRange(location: next, length: ns.length - next)
		}
		return a
	}
}

#Preview {
	MemoEditorView()
}
