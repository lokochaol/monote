//
//  MemoEditorView.swift
//  scroll
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// `UIScreen.main` の代わりに接続中の `UIWindowScene` から画面サイズを得る。
private func applicationScreenBounds() -> CGRect {
	let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
	if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
		return active.screen.bounds
	}
	if let any = scenes.first {
		return any.screen.bounds
	}
	return CGRect(x: 0, y: 0, width: 393, height: 852)
}

private func bootstrapScreenHeight() -> CGFloat {
	max(applicationScreenBounds().height, 320)
}
#else
private func bootstrapScreenHeight() -> CGFloat { 720 }
#endif

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
	@State private var lineScrollIntoViewTask: Task<Void, Never>?
	/// undo/redo 実行直後に「操作された付近」を画面中央へ寄せるためのターゲット行 ID。
	@State private var undoRedoCenterLineId: UUID?
	@State private var undoRedoScrollTask: Task<Void, Never>?
	@State private var scrollThrottleTask: Task<Void, Never>?
	@State private var pendingContentTopY: CGFloat = 0
	@State private var mergeCaret: (lineId: UUID, utf16: Int)?
	@State private var keyboardTopScreenY: CGFloat?
	@State private var keyboardScrollTask: Task<Void, Never>?
	@State private var focusedSelectionLength: Int = 0
	@State private var focusedCaretUTF16: Int = 0
	@State private var lastSelectionInteractionAt: Date = .distantPast
	/// 起動直後のみ。末尾行フォーカス＋キーボード表示まで本文を隠す。
	@State private var initialBootComplete = false
	@State private var initialBootDebugFallbackTask: Task<Void, Never>?

	// MARK: - 複数行選択モード用の View 側状態
	/// 選択オーバーレイがヒットテストに使う、行 ID → グローバル座標系の矩形。
	@State private var lineFramesInGlobal: [UUID: CGRect] = [:]
	/// オーバーレイから受け取る、エディタ内の `UIScrollView` 参照（× 解除時のスクロール位置保持に使う）。
	@State private var editorScrollView: UIScrollView?
	/// コピー完了のチェックマーク吹き出し表示。
	@State private var showCopiedToast = false
	@State private var copiedToastTask: Task<Void, Never>?
	/// 削除確認アラート。
	@State private var showDeleteConfirm = false

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
				.overlay {
					// オーバーレイは ScrollView のビューポートにぴたり収まる。
					// `.safeAreaInset` の下部バーはこの overlay の外側（後段）に配置されるため、
					// ボタンタップはオーバーレイに吸い取られない。
					if model.isSelectionMode {
						MemoSelectionOverlay(
							lineFrames: lineFramesInGlobal,
							onBegin: { model.beginDragSelection(at: $0) },
							onExtend: { model.extendDragSelection(to: $0) },
							onEnd: { model.endDragSelection() },
							onTap: { model.toggleLineSelection($0) },
							onScrollViewCaptured: { sv in
								editorScrollView = sv
							}
						)
						.transition(.opacity)
					}
				}
				.overlay(alignment: .trailing) {
					// 選択モード中、右端の細いストリップ（見た目のみ）。
					// 実際のタッチパススルーは `MemoSelectionOverlayUIView.hitTest` で行うため、
					// ここは `.allowsHitTesting(false)` で完全に飾りに留める。
					if model.isSelectionMode {
						MemoSelectionScrollGutter()
							.frame(width: MemoSelectionOverlay.scrollGutterWidth)
							.allowsHitTesting(false)
							.transition(.opacity)
					}
				}
				.safeAreaInset(edge: .bottom, spacing: 0) {
					if model.isSelectionMode {
						selectionActionBar
					} else if keyboardTopScreenY == nil {
						bottomSearchEntryBar
					}
				}
				.coordinateSpace(name: "memoScroll")
				.simultaneousGesture(contentScrollDismissKeyboardGesture)
				.onPreferenceChange(MemoLineFramePreferenceKey.self) { frames in
					lineFramesInGlobal = frames
				}
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
					lineScrollIntoViewTask?.cancel()
					lineScrollIntoViewTask = nil
					guard let id else { return }
					// 選択モード中は自動スクロールを完全に抑制（画面位置をユーザー操作以外で動かさない）。
					if model.isSelectionMode {
						lineIdToScrollIntoView = nil
						return
					}
					lineScrollIntoViewTask = Task { @MainActor in
						try? await Task.sleep(nanoseconds: scrollLineIntoViewDelayNanos)
						guard !Task.isCancelled else { return }
						withAnimation(MemoEditorScrollAnimation.focusLine) {
							proxy.scrollTo(id, anchor: .bottom)
						}
						lineIdToScrollIntoView = nil
					}
				}
				.onChange(of: undoRedoCenterLineId) { _, id in
					undoRedoScrollTask?.cancel()
					undoRedoScrollTask = nil
					guard let id else { return }
					// undo/redo 後はキーボードを閉じた直後に走るため、
					// レイアウトが落ち着くまで少し待ってから中央スクロールする。
					undoRedoScrollTask = Task { @MainActor in
						try? await Task.sleep(nanoseconds: scrollLineIntoViewDelayNanos)
						guard !Task.isCancelled else { return }
						withAnimation(MemoEditorScrollAnimation.focusLine) {
							proxy.scrollTo(id, anchor: .center)
						}
						undoRedoCenterLineId = nil
					}
				}
				}
				if !initialBootComplete {
					MemoInitialBootLoadingOverlay()
						.transition(.opacity)
						.zIndex(2)
						.allowsHitTesting(true)
				}
			}
			.onChange(of: focusedLineId) { _, newId in
				focusedSelectionLength = 0
				focusedCaretUTF16 = 0
				lastSelectionInteractionAt = .distantPast
				evaluateInitialBootComplete()
				// 選択モード中はフォーカス変更によるスクロールを起こさない。
				guard !model.isSelectionMode else { return }
				guard let id = newId else { return }
				lineIdToScrollIntoView = id
			}
			.onChange(of: keyboardTopScreenY) { _, newTop in
				keyboardScrollTask?.cancel()
				guard !model.isSelectionMode else { return }
				guard newTop != nil, focusedLineId != nil else { return }
				keyboardScrollTask = Task { @MainActor in
					try? await Task.sleep(nanoseconds: keyboardAdjustScrollDelayNanos)
					guard !Task.isCancelled, let id = focusedLineId else { return }
					lineIdToScrollIntoView = id
				}
				evaluateInitialBootComplete()
			}
			.onAppear {
				if !didBootstrap {
					didBootstrap = true
					model.attachSyncCoordinator(NoOpMemoSyncCoordinator.shared)
					model.bootstrap(screenHeight: bootstrapScreenHeight())
					restoreEditorFocusAtBootstrap()
					scheduleInitialBootDebugFallbackIfNeeded()
					evaluateInitialBootComplete()
					return
				}
			}
			.onChange(of: scenePhase) { oldPhase, newPhase in
				// 起動時以外（バックグラウンド復帰など）では、編集中のカーソル位置を尊重して
				// 自動で末尾へフォーカス/スクロールしない。
			}
			.onChange(of: model.editorFocusRequest) { _, req in
				guard let req else { return }
				// 選択モード中は編集に起因するフォーカス要求を無視し、モード解除後に改めて入力されるまで待つ。
				if model.isSelectionMode {
					model.editorFocusRequest = nil
					return
				}
				focusedLineId = req.lineId
				mergeCaret = (req.lineId, req.caretUTF16)
				lineIdToScrollIntoView = req.lineId
				model.editorFocusRequest = nil
			}
			.onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
				guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
				let screenH = applicationScreenBounds().height
				if frame.minY >= screenH - 0.5 {
					keyboardTopScreenY = nil
				} else {
					keyboardTopScreenY = frame.minY
				}
				evaluateInitialBootComplete()
			}
			.onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
				keyboardTopScreenY = nil
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
			}
			.toolbar(initialBootComplete ? .visible : .hidden, for: .navigationBar)
			.toolbarBackground(.hidden, for: .navigationBar)
			.toolbarBackground(.hidden, for: .automatic)
			.toolbar {
				ToolbarItemGroup(placement: .topBarLeading) {
					if initialBootComplete, !model.isSelectionMode {
						Button(action: performUndo) {
							Image(systemName: "arrow.uturn.backward")
								.font(.system(size: 16, weight: .medium))
						}
						.disabled(!model.canUndo)
						.accessibilityLabel(Text("Undo"))

						Button(action: performRedo) {
							Image(systemName: "arrow.uturn.forward")
								.font(.system(size: 16, weight: .medium))
						}
						.disabled(!model.canRedo)
						.accessibilityLabel(Text("Redo"))
					}
				}
				ToolbarItem(placement: .topBarTrailing) {
					// ローディングオーバーレイ表示中はツールバーごと隠している（上の `.toolbar(.hidden, ...)`）が、
					// 念のためボタン側でも初期化前は描画しない。
					if initialBootComplete {
						if model.isSelectionMode {
							Button(action: exitSelectionModePreservingScroll) {
								Image(systemName: "xmark")
									.font(.system(size: 16, weight: .semibold))
							}
							.accessibilityLabel(Text("Exit selection mode"))
						} else {
							Button(action: enterSelectionModeFromEditor) {
								Text("Select")
									.font(.system(size: 16, weight: .medium))
							}
							.accessibilityLabel(Text("Select"))
						}
					}
				}
			}
			.sheet(isPresented: $showSearch) {
				MemoKeywordSearchSheet(model: model, isPresented: $showSearch)
			}
			.alert("Delete selected lines?", isPresented: $showDeleteConfirm) {
				Button("Cancel", role: .cancel) {}
				Button("Delete", role: .destructive) {
					deleteSelectedLinesPreservingScroll()
				}
			} message: {
				Text("This action can't be undone.")
			}
		}
	}

	// MARK: - Undo / Redo

	private func performUndo() {
		let current = captureCurrentFocusForHistory()
		dismissEditorFocusForHistoryAction()
		if let target = model.performUndo(currentFocus: current) {
			undoRedoCenterLineId = target
		}
	}

	private func performRedo() {
		let current = captureCurrentFocusForHistory()
		dismissEditorFocusForHistoryAction()
		if let target = model.performRedo(currentFocus: current) {
			undoRedoCenterLineId = target
		}
	}

	/// undo/redo 直前のフォーカス・キャレットを履歴スタックへ（redo 側に）積むため取得。
	private func captureCurrentFocusForHistory() -> (lineId: UUID, utf16: Int)? {
		guard let id = focusedLineId else { return nil }
		return (id, focusedCaretUTF16)
	}

	/// undo/redo 実行時はキーボードを下げ、特定の行にフォーカス/キャレットが残らないようにする。
	private func dismissEditorFocusForHistoryAction() {
		focusedLineId = nil
		mergeCaret = nil
		focusedSelectionLength = 0
		focusedCaretUTF16 = 0
		model.editorFocusRequest = nil
		resignFirstResponderGlobally()
	}

	// MARK: - 選択モードの出入り

	private func enterSelectionModeFromEditor() {
		focusedLineId = nil
		mergeCaret = nil
		resignFirstResponderGlobally()
		// キーボードが下りきってから chrome を切替えるとレイアウトのジャンプを避けやすい。
		Task { @MainActor in
			try? await Task.sleep(nanoseconds: 80_000_000)
			withAnimation(.easeOut(duration: 0.2)) {
				model.enterSelectionMode()
			}
		}
	}

	private func exitSelectionModePreservingScroll() {
		// × タップの時点で可視位置を抑えておき、bottom bar・toolbar の切替後に復元する。
		// オーバーレイが外れると `editorScrollView` は nil になり得るため、参照を即座にキャプチャしておく。
		let capturedScrollView = editorScrollView
		let savedY = capturedScrollView?.contentOffset.y
		withAnimation(.easeOut(duration: 0.2)) {
			model.exitSelectionMode()
		}
		focusedLineId = nil
		mergeCaret = nil
		guard let y = savedY, let sv = capturedScrollView else { return }
		// 2 回リストアする: レイアウト確定前後のどちらでも最終的に元位置へ落ち着かせる。
		DispatchQueue.main.async {
			sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: y), animated: false)
			DispatchQueue.main.async {
				sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: y), animated: false)
			}
		}
	}

	private func performCopyWithToast() {
		guard !model.selectedLineIds.isEmpty else { return }
		model.copySelectedLines()
		copiedToastTask?.cancel()
		withAnimation(.easeOut(duration: 0.18)) {
			showCopiedToast = true
		}
		copiedToastTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 1_200_000_000)
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.22)) {
				showCopiedToast = false
			}
		}
	}

	private func deleteSelectedLinesPreservingScroll() {
		let capturedScrollView = editorScrollView
		let savedY = capturedScrollView?.contentOffset.y
		model.deleteSelectedLines()
		// 削除後は画面位置が変わる可能性があるが、削除ボタン押下前の物理位置を保つ。
		guard let y = savedY, let sv = capturedScrollView else { return }
		DispatchQueue.main.async {
			sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: y), animated: false)
		}
	}

	private func evaluateInitialBootComplete() {
		guard !initialBootComplete else { return }
		guard didBootstrap else { return }
		guard let tailId = model.currentTailLineId(), focusedLineId == tailId else { return }
#if canImport(UIKit)
		guard keyboardTopScreenY != nil else { return }
#endif
		initialBootDebugFallbackTask?.cancel()
		initialBootDebugFallbackTask = nil
		withAnimation(.easeOut(duration: 0.28)) {
			initialBootComplete = true
		}
	}

	/// シミュレータ等でソフトキーボードが出ず完了しないのを避ける（DEBUG のみ）。
	private func scheduleInitialBootDebugFallbackIfNeeded() {
#if DEBUG && canImport(UIKit)
		initialBootDebugFallbackTask?.cancel()
		initialBootDebugFallbackTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 2_800_000_000)
			guard !Task.isCancelled, !initialBootComplete, didBootstrap else { return }
			guard let tailId = model.currentTailLineId(), focusedLineId == tailId else { return }
			initialBootDebugFallbackTask = nil
			withAnimation(.easeOut(duration: 0.28)) {
				initialBootComplete = true
			}
		}
#endif
	}

	private var headSentinel: some View {
		Color.clear
			.frame(height: 1)
			.onGeometryChange(for: CGFloat.self) { proxy in
				proxy.frame(in: .named("memoScroll")).minY
			} action: { _, newY in
				Task { @MainActor in
					reportScrollContentTopChange(newY)
				}
			}
	}

	private func reportScrollContentTopChange(_ y: CGFloat) {
		pendingContentTopY = y
		scrollThrottleTask?.cancel()
		scrollThrottleTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: scrollSampleNanos)
			guard !Task.isCancelled else { return }
			let firstBlockHeight = model.estimatedFirstBlockHeight()
			model.reportScrollForWindowTrim(
				contentTopY: pendingContentTopY,
				firstBlockHeight: firstBlockHeight,
				focusedLineId: focusedLineId
			)
			model.reportScrollForInfiniteScroll(
				contentTopY: pendingContentTopY,
				firstBlockHeight: firstBlockHeight,
				focusedLineId: focusedLineId
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
				await Task.yield()
				focusedLineId = id
			}
		} else {
			focusedLineId = id
		}
	}

	private var contentScrollDismissKeyboardGesture: some Gesture {
		DragGesture(minimumDistance: keyboardDismissDragMinDistance, coordinateSpace: .global)
			.onEnded { value in
				// 選択モード中はドラッグ起因の focus 解除を起こさない（そもそも focus はないが、念のため）。
				if model.isSelectionMode { return }
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
				Text(q.isEmpty ? "Search" : q)
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

	/// 選択モード中の下部バー: コピー／削除のアイコンのみ。選択 0 のときは両方 disabled。
	private var selectionActionBar: some View {
		let hasSelection = !model.selectedLineIds.isEmpty
		let barShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
		return HStack(spacing: 0) {
			Button(action: performCopyWithToast) {
				Image(systemName: "doc.on.doc")
					.font(.system(size: 20, weight: .regular))
					.frame(maxWidth: .infinity)
					.padding(.vertical, 12)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.disabled(!hasSelection)
			.foregroundStyle(hasSelection ? Color.primary : Color.secondary.opacity(0.5))
			.accessibilityLabel(Text("Copy"))
			.overlay(alignment: .top) {
				if showCopiedToast {
					copiedToastBubble
						.offset(y: -44)
						.transition(.scale.combined(with: .opacity))
				}
			}

			Button {
				showDeleteConfirm = true
			} label: {
				Image(systemName: "trash")
					.font(.system(size: 20, weight: .regular))
					.frame(maxWidth: .infinity)
					.padding(.vertical, 12)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.disabled(!hasSelection)
			.foregroundStyle(hasSelection ? Color.red : Color.secondary.opacity(0.5))
			.accessibilityLabel(Text("Delete"))
		}
		.frame(maxWidth: .infinity)
		.background(
			barShape.fill(.regularMaterial)
		)
		.clipShape(barShape)
		.padding(.horizontal, MemoJournalPalette.horizontalInset)
		.padding(.bottom, 8)
	}

	private var copiedToastBubble: some View {
		ZStack {
			Capsule(style: .continuous)
				.fill(.regularMaterial)
				.frame(width: 56, height: 38)
				.shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
			Image(systemName: "checkmark")
				.font(.system(size: 17, weight: .semibold))
				.foregroundStyle(.primary)
		}
		.allowsHitTesting(false)
	}

	private func lineRow(line: MemoLine, index: Int) -> some View {
		let globalIdx = model.globalLineOffset + index
		let (highlightQ, highlightAlpha): (String?, CGFloat?) = {
			guard let kw = model.searchHighlightKeyword, !kw.isEmpty else { return (nil, nil) }
			guard model.searchHitGlobalLineIndexSet.contains(globalIdx) else { return (nil, nil) }
			let isSelected = (model.searchHighlightGlobalLineIndex == globalIdx)
			return (kw, isSelected ? 0.62 : 0.32)
		}()
		let isSelectionMode = model.isSelectionMode
		let isLineSelected = isSelectionMode && model.selectedLineIds.contains(line.id)
		return HStack(alignment: .top, spacing: 0) {
			if isSelectionMode {
				Image(systemName: isLineSelected ? "checkmark.circle.fill" : "circle")
					.font(.system(size: 20, weight: .regular))
					.foregroundStyle(isLineSelected ? Color.accentColor : Color.secondary.opacity(0.6))
					.frame(width: 28, height: 28)
					.padding(.top, 4)
					.padding(.trailing, 4)
					.transition(.opacity)
			}
			MemoLineTextView(
				attributed: model.displayAttributed(for: line),
				isFocused: focusedLineId == line.id,
				highlightQuery: highlightQ,
				highlightAlpha: highlightAlpha,
				isInteractive: !isSelectionMode,
				pendingCaretUTF16: Binding(
					get: {
						guard let m = mergeCaret, m.lineId == line.id else { return nil }
						return m.utf16
					},
					set: { newVal in
						if newVal == nil, mergeCaret?.lineId == line.id { mergeCaret = nil }
					}
				),
				onAttributedEdit: { attr, caret in
					model.updateLineRichContent(id: line.id, attributed: attr, caretUTF16: caret)
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
				onSelectionInteraction: { selectionLen, caret in
					guard focusedLineId == line.id else { return }
					let previousLength = focusedSelectionLength
					focusedSelectionLength = selectionLen
					focusedCaretUTF16 = caret
					if selectionLen > 0 || previousLength > 0 {
						lastSelectionInteractionAt = Date()
					}
				}
			)
			.frame(maxWidth: .infinity, alignment: .leading)
			.fixedSize(horizontal: false, vertical: true)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.vertical, isSelectionMode ? 1 : 0)
		.background(
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.fill(isLineSelected ? Color.accentColor.opacity(0.10) : Color.clear)
		)
		.background(
			GeometryReader { g in
				if isSelectionMode {
					Color.clear
						.preference(
							key: MemoLineFramePreferenceKey.self,
							value: [line.id: g.frame(in: .global)]
						)
				} else {
					Color.clear
				}
			}
		)
		.id(line.id)
	}
}

private struct MemoKeywordSearchSheet: View {
	@Bindable var model: MemoEditorViewModel
	@Binding var isPresented: Bool
	@FocusState private var keywordFieldFocused: Bool

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				TextField("Keyword", text: $model.searchKeywordText)
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
			.navigationTitle("Search")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Close") { isPresented = false }
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

private struct MemoInitialBootLoadingOverlay: View {
	private let dotCount = 5
	private let dotSize: CGFloat = 11
	private let dotSpacing: CGFloat = 14
	private let bounceHeight: CGFloat = 13

	var body: some View {
		ZStack {
			Color.white.ignoresSafeArea()
			TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
				let t = timeline.date.timeIntervalSinceReferenceDate * 4.8
				HStack(spacing: dotSpacing) {
					ForEach(0..<dotCount, id: \.self) { i in
						let phase = t + Double(i) * 0.62
						let bounce = pow(max(0, sin(phase)), 2.0)
						Circle()
							.fill(Color.black.opacity(0.9))
							.frame(width: dotSize, height: dotSize)
							.offset(y: -CGFloat(bounce) * bounceHeight)
					}
				}
			}
		}
		.accessibilityLabel(Text("Loading"))
	}
}

/// 選択モード中に右端へ表示する、視覚的なスクロール用ストリップ。
/// 実際のタッチパススルーは `MemoSelectionOverlayUIView.hitTest` 側で扱う飾り専用。
private struct MemoSelectionScrollGutter: View {
	var body: some View {
		// 縦に伸びる薄いカプセル。指で触れる目印として機能し、文字ではなく形状のみで意図を示す。
		Capsule(style: .continuous)
			.fill(Color.secondary.opacity(0.18))
			.frame(width: 4)
			.frame(maxHeight: .infinity)
			.padding(.vertical, 12)
			.frame(maxWidth: .infinity, alignment: .center)
	}
}

#Preview {
	MemoEditorView()
}
