//
//  MemoSelectionOverlay.swift
//  scroll
//

import SwiftUI
import UIKit

/// `LazyVStack` の各行から global 座標系の矩形を収集する preference key。
/// 選択オーバーレイがヒットテストに使う。
struct MemoLineFramePreferenceKey: PreferenceKey {
	typealias Value = [UUID: CGRect]
	static var defaultValue: [UUID: CGRect] = [:]
	static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
		value.merge(nextValue()) { _, new in new }
	}
}

/// 選択モード中に `ScrollView` 全体を覆い、タップ／ドラッグを横取りする透明オーバーレイ。
/// 指が縦端（上端／下端）へ届いたときは `CADisplayLink` で `UIScrollView.contentOffset` を動かし続ける。
struct MemoSelectionOverlay: UIViewRepresentable {
	/// 選択モード中、オーバーレイ右端のこの幅だけはタッチをスルーして背後の `UIScrollView` に届ける。
	/// SwiftUI 側のスクロールストリップ表示もこの幅に揃える。
	static let scrollGutterWidth: CGFloat = 32

	/// 行 ID → グローバル座標系の矩形（`.global` から収集）。
	var lineFrames: [UUID: CGRect]

	var onBegin: (UUID) -> Void
	var onExtend: (UUID) -> Void
	var onEnd: () -> Void
	/// タップ（ドラッグ扱いにならなかった短い接触）。
	var onTap: (UUID) -> Void
	/// オーバーレイが window に入った時点で、同じウィンドウ内の最初の `UIScrollView` を親に渡す。
	var onScrollViewCaptured: (UIScrollView?) -> Void

	func makeUIView(context: Context) -> MemoSelectionOverlayUIView {
		let view = MemoSelectionOverlayUIView()
		view.coordinator = context.coordinator
		context.coordinator.view = view
		return view
	}

	func updateUIView(_ uiView: MemoSelectionOverlayUIView, context: Context) {
		context.coordinator.parent = self
		uiView.setNeedsLayout()
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	final class Coordinator {
		var parent: MemoSelectionOverlay
		weak var view: MemoSelectionOverlayUIView?

		init(_ parent: MemoSelectionOverlay) {
			self.parent = parent
		}
	}
}

/// `MemoSelectionOverlay` の実体。`UILongPressGestureRecognizer(minimumPressDuration: 0)` を 1 本だけ持ち、
/// タップも短いドラッグ（= 動かない押下→離す）として扱う。
final class MemoSelectionOverlayUIView: UIView, UIGestureRecognizerDelegate {
	weak var coordinator: MemoSelectionOverlay.Coordinator?

	private lazy var trackGR: UILongPressGestureRecognizer = {
		let gr = UILongPressGestureRecognizer(target: self, action: #selector(handleTrack(_:)))
		gr.minimumPressDuration = 0
		// 初期認識後の移動で失敗させないため、非常に大きな許容量。
		gr.allowableMovement = .greatestFiniteMagnitude
		gr.cancelsTouchesInView = true
		gr.delegate = self
		return gr
	}()

	/// このジェスチャで一度でも `.changed` が届いたか（届いたなら「タップ」扱いしない）。
	private var didMoveInCurrentGesture = false
	/// ジェスチャ開始時にヒットした行 ID（タップ確定時の対象）。
	private var initialLineId: UUID?
	/// ジェスチャ開始時に `onBegin` を呼んだか（初期ヒット時のみ一度）。
	private var didCallBegin = false

	private weak var capturedScrollView: UIScrollView?
	private var displayLink: CADisplayLink?
	private var lastTouchLocationInSelf: CGPoint = .zero

	/// 端部オートスクロールの検知しきい値と速度。
	private let edgeZonePoints: CGFloat = 72
	private let maxAutoScrollPointsPerFrame: CGFloat = 12

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = .clear
		isOpaque = false
		isUserInteractionEnabled = true
		addGestureRecognizer(trackGR)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { nil }

	/// 右端ストリップ領域へのタッチは `nil` を返してパススルーし、背後の `UIScrollView` の
	/// 標準 pan ジェスチャに任せる。それ以外（左〜中央）は通常通り選択ジェスチャで掴む。
	override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
		if bounds.width - point.x < MemoSelectionOverlay.scrollGutterWidth {
			return nil
		}
		return super.hitTest(point, with: event)
	}

	override func didMoveToWindow() {
		super.didMoveToWindow()
		if window != nil {
			captureScrollViewIfNeeded()
		} else {
			stopAutoScrollIfNeeded()
			capturedScrollView = nil
			coordinator?.parent.onScrollViewCaptured(nil)
		}
	}

	private func captureScrollViewIfNeeded() {
		guard capturedScrollView == nil, let win = window else { return }
		let sv = Self.findFirstScrollView(in: win)
		capturedScrollView = sv
		coordinator?.parent.onScrollViewCaptured(sv)
	}

	private static func findFirstScrollView(in root: UIView) -> UIScrollView? {
		if let sv = root as? UIScrollView { return sv }
		for sub in root.subviews {
			if let r = findFirstScrollView(in: sub) { return r }
		}
		return nil
	}

	private func lineId(atGlobalPoint gp: CGPoint) -> UUID? {
		guard let frames = coordinator?.parent.lineFrames else { return nil }
		for (id, rect) in frames where rect.contains(gp) {
			return id
		}
		return nil
	}

	@objc private func handleTrack(_ gr: UILongPressGestureRecognizer) {
		let locSelf = gr.location(in: self)
		lastTouchLocationInSelf = locSelf
		let locWindow = gr.location(in: nil)

		switch gr.state {
		case .began:
			didMoveInCurrentGesture = false
			didCallBegin = false
			initialLineId = lineId(atGlobalPoint: locWindow)
			if let id = initialLineId {
				// `began` で最初の行をドラッグ開始として記録。`ended` で「動いていない」と判定できたら
				// 巻き戻して `onTap` 扱いに切り替える。
				coordinator?.parent.onBegin(id)
				didCallBegin = true
			}
			startAutoScrollIfNeeded()

		case .changed:
			didMoveInCurrentGesture = true
			if let id = lineId(atGlobalPoint: locWindow) {
				coordinator?.parent.onExtend(id)
			}
			updateAutoScroll()

		case .ended:
			if didMoveInCurrentGesture {
				coordinator?.parent.onEnd()
			} else {
				// 動かない押下→離しはタップ扱い。`onBegin` で行った反転を「タップのトグル」と同一視する。
				// （adding モードなら「未選択→選択」、removing モードなら「選択→未選択」となり、
				//  いずれもユーザーから見れば 1 回のタップによる切り替えなので追加処理は不要。）
				coordinator?.parent.onEnd()
				if !didCallBegin, let id = lineId(atGlobalPoint: locWindow) {
					coordinator?.parent.onTap(id)
				}
			}
			didMoveInCurrentGesture = false
			didCallBegin = false
			initialLineId = nil
			stopAutoScrollIfNeeded()

		case .cancelled, .failed:
			coordinator?.parent.onEnd()
			didMoveInCurrentGesture = false
			didCallBegin = false
			initialLineId = nil
			stopAutoScrollIfNeeded()

		default:
			break
		}
	}

	// 他のジェスチャ（例: ScrollView の pan）が裏で生きている場合でも、同時認識は避ける。
	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		false
	}

	// MARK: - 端部オートスクロール

	private func startAutoScrollIfNeeded() {
		guard displayLink == nil else { return }
		captureScrollViewIfNeeded()
		let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
		link.add(to: .main, forMode: .common)
		displayLink = link
	}

	private func stopAutoScrollIfNeeded() {
		displayLink?.invalidate()
		displayLink = nil
	}

	@objc private func autoScrollTick() {
		updateAutoScroll()
	}

	private func updateAutoScroll() {
		guard let sv = capturedScrollView else { return }
		let y = lastTouchLocationInSelf.y
		let height = bounds.height
		guard height > 1 else { return }

		var delta: CGFloat = 0
		if y < edgeZonePoints {
			let norm = max(0, min(1, (edgeZonePoints - y) / edgeZonePoints))
			delta = -maxAutoScrollPointsPerFrame * norm
		} else if y > height - edgeZonePoints {
			let norm = max(0, min(1, (y - (height - edgeZonePoints)) / edgeZonePoints))
			delta = maxAutoScrollPointsPerFrame * norm
		}

		guard delta != 0 else { return }

		let maxOffsetY = max(0, sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height)
		let minOffsetY = -sv.adjustedContentInset.top
		let newY = min(max(minOffsetY, sv.contentOffset.y + delta), maxOffsetY)
		guard newY != sv.contentOffset.y else { return }
		sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: newY), animated: false)

		// スクロール後、指の現在位置から再ヒットテストして新しく視界に入った行も選択対象に加える。
		let global = convert(lastTouchLocationInSelf, to: nil)
		if let id = lineId(atGlobalPoint: global) {
			coordinator?.parent.onExtend(id)
		}
	}
}
