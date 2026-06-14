//
//  MemoLineTextView.swift
//  scroll
//

import ImageIO
import PhotosUI
import SVGKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

// MARK: - プレビュー枠を固定（モーダル後に `bounds` が 0 に戻って実寸表示になるのを防ぐ）

@objc(MemoPreviewImageAttachment)
private final class MemoPreviewImageAttachment: NSTextAttachment {
	private static let codingPreviewW = "MemoInlinePreviewW"
	private static let codingPreviewH = "MemoInlinePreviewH"
	/// 新フォーマット: `contents`（オリジナル画像バイト列）の中身を外部ストアに退避し、
	/// アーカイブにはハッシュ参照だけを乗せる。`MemoLine` を持ち回るときの RAM 占有を激減させる目的。
	private static let codingContentsRefHash = "MemoInlineContentsRefHash"
	private static let codingContentsRefExt = "MemoInlineContentsRefExt"
	private static let codingContentsRefFileType = "MemoInlineContentsRefFileType"

	/// レイアウト用の表示枠。`bounds` が無効でも `attachmentBounds` はここを使う。
	var previewLayoutSize: CGSize

	init(image: UIImage, previewLayoutSize: CGSize) {
		self.previewLayoutSize = previewLayoutSize
		super.init(data: nil, ofType: nil)
		self.image = image
	}

	/// 復元経路（RTF / アーカイブ / コピー等）で呼ばれることがあるため受ける。
	override init(data contentData: Data?, ofType uti: String?) {
		self.previewLayoutSize = .zero
		super.init(data: contentData, ofType: uti)
		if previewLayoutSize == .zero {
			if bounds.width > 0, bounds.height > 0 {
				previewLayoutSize = bounds.size
			} else {
				previewLayoutSize = CGSize(width: 120, height: 120)
			}
		}
	}

	required init?(coder: NSCoder) {
		self.previewLayoutSize = .zero
		super.init(coder: coder)
		if coder.containsValue(forKey: Self.codingPreviewW), coder.containsValue(forKey: Self.codingPreviewH) {
			previewLayoutSize = CGSize(
				width: CGFloat(coder.decodeDouble(forKey: Self.codingPreviewW)),
				height: CGFloat(coder.decodeDouble(forKey: Self.codingPreviewH))
			)
		} else if bounds.width > 0, bounds.height > 0 {
			previewLayoutSize = bounds.size
		} else {
			previewLayoutSize = CGSize(width: 120, height: 120)
		}
		// 新フォーマット: `super.init(coder:)` 段階では `contents` が空で、ハッシュ参照だけが乗っている。
		// 外部ストア（`MemoAttachmentStore`）からオリジナルバイトを引いて `contents` に再装填する。
		// 旧フォーマット（インライン埋め込み）は `super` がすでに `contents` を埋めているので何もしない。
		if (contents == nil || contents?.isEmpty == true),
		   let hex = coder.decodeObject(of: NSString.self, forKey: Self.codingContentsRefHash) as String? {
			let ext = (coder.decodeObject(of: NSString.self, forKey: Self.codingContentsRefExt) as String?) ?? "bin"
			if let data = MemoAttachmentStore.read(hashHex: hex, ext: ext) {
				contents = data
			}
			if let storedFileType = coder.decodeObject(of: NSString.self, forKey: Self.codingContentsRefFileType) as String?,
			   !storedFileType.isEmpty {
				fileType = storedFileType
			}
		}
		// 復元経路では `.contents` にオリジナルの画像データが入っている想定。
		// `.image` を常にプレビュー枠相当のサムネイルに落としておき、初回表示時の
		// メインスレッド上での巨大ビットマップデコードを避ける。
		if previewLayoutSize.width > 0, previewLayoutSize.height > 0,
		   let data = contents,
		   let thumb = MemoImageInsertion.downsampledImage(fromData: data, pointSize: previewLayoutSize) {
			image = thumb
		}
	}

	override class var supportsSecureCoding: Bool { true }

	override func encode(with coder: NSCoder) {
		// `contents` のオリジナル画像バイト列はアーカイブに直接埋め込まず、
		// `MemoAttachmentStore` 配下のファイルへ書き出してハッシュだけ乗せる。
		// 一時的に `self.contents = nil` にして `super.encode(with:)` を呼ぶことで、
		// `NSTextAttachment` 標準の経路がインラインバイトを書き込まないようにする。
		// 書き出し後に元へ戻すため、現在描画中のインスタンスは引き続き使える。
		var savedContents: Data?
		var didExternalize = false
		if let data = contents, !data.isEmpty {
			let ext = MemoAttachmentStore.preferredExtension(forFileType: fileType)
			if let hex = MemoAttachmentStore.write(data: data, ext: ext) {
				savedContents = data
				contents = nil
				didExternalize = true
				coder.encode(hex as NSString, forKey: Self.codingContentsRefHash)
				coder.encode(ext as NSString, forKey: Self.codingContentsRefExt)
				if let ft = fileType {
					coder.encode(ft as NSString, forKey: Self.codingContentsRefFileType)
				}
			}
		}
		super.encode(with: coder)
		if didExternalize {
			contents = savedContents
		}
		coder.encode(Double(previewLayoutSize.width), forKey: Self.codingPreviewW)
		coder.encode(Double(previewLayoutSize.height), forKey: Self.codingPreviewH)
	}

	override func attachmentBounds(
		for textContainer: NSTextContainer?,
		proposedLineFragment lineFrag: CGRect,
		glyphPosition position: CGPoint,
		characterIndex charIndex: Int
	) -> CGRect {
		let w = previewLayoutSize.width
		let h = previewLayoutSize.height
		guard w > 0, h > 0,
		      let lm = textContainer?.layoutManager,
		      let ts = lm.textStorage,
		      ts.length > 0
		else {
			if bounds.width > 0, bounds.height > 0 { return bounds }
			return super.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex)
		}
		let idx = min(max(0, charIndex), ts.length - 1)
		let font = ts.attribute(.font, at: idx, effectiveRange: nil) as? UIFont ?? UIFont.preferredFont(forTextStyle: .body)
		let midY = (font.capHeight - h) / 2
		return CGRect(x: 0, y: midY, width: w, height: h)
	}
}

// MARK: - 画像挿入（レイアウト枠だけ小さく＝表面上のサムネ／タップでフルスクリーン）

enum MemoImageInsertion {
	private static let previewMaxWidth: CGFloat = 152
	private static let previewMinWidth: CGFloat = 88
	private static let previewWidthFraction: CGFloat = 0.38
	/// プレビュー枠の最大高さ（縦長写真で行が伸びすぎないように）
	private static let previewMaxHeight: CGFloat = 200
	/// プレビュー用サムネイルを生成する際の Retina 余裕倍率。
	/// @3x 端末でも原寸より一段階引き上げた解像度を持たせる。
	fileprivate static let previewScaleHeadroom: CGFloat = 3

	/// 表示は軽量なサムネイルに差し替え、元データは `attachment.contents` に保持する。
	/// フルスクリーン表示時は `fullImage(from:)` が `contents` を優先して使うため、
	/// タップ時の解像度は従来と同等を維持できる。
	static func insertImage(_ image: UIImage, into textView: UITextView) {
		let insetW = textView.textContainerInset.left + textView.textContainerInset.right + textView.textContainer.lineFragmentPadding * 2
		let containerW = max(1, textView.bounds.width - insetW)
		let previewCap = min(previewMaxWidth, max(previewMinWidth, containerW * previewWidthFraction))
		let font = (textView.typingAttributes[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)

		let iw = max(image.size.width, 1)
		let ih = max(image.size.height, 1)

		var displayW = previewCap
		var displayH = displayW * (ih / iw)
		if displayH > previewMaxHeight {
			displayH = previewMaxHeight
			displayW = displayH * (iw / ih)
		}

		let previewSize = CGSize(width: displayW, height: displayH)
		let (originalData, uti) = encodedOriginalData(from: image)
		let thumbnail: UIImage = {
			if let originalData,
			   let d = downsampledImage(fromData: originalData, pointSize: previewSize) {
				return d
			}
			return downsampledImage(fromImage: image, pointSize: previewSize)
		}()

		let midY = (font.capHeight - displayH) / 2
		let attachment = MemoPreviewImageAttachment(image: thumbnail, previewLayoutSize: previewSize)
		attachment.bounds = CGRect(x: 0, y: midY, width: displayW, height: displayH)
		if let originalData {
			attachment.contents = originalData
			attachment.fileType = uti
		}

		let attrString = NSMutableAttributedString(attachment: attachment)
		let baseAttrs = MemoRichTextEncoding.defaultTypingAttributes()
		attrString.addAttributes(baseAttrs, range: NSRange(location: 0, length: attrString.length))

		let sel = textView.selectedRange
		textView.textStorage.replaceCharacters(in: sel, with: attrString)
		textView.selectedRange = NSRange(location: sel.location + attrString.length, length: 0)
		textView.invalidateIntrinsicContentSize()
		textView.delegate?.textViewDidChange?(textView)
	}

	/// 旧データは `contents` にフル解像度があることがある。新データは `image` のみ。
	static func fullImage(from attachment: NSTextAttachment) -> UIImage? {
		if let data = attachment.contents, let img = UIImage(data: data) {
			return img
		}
		return attachment.image
	}

	// MARK: - ダウンサンプリング補助

	/// `Data`（PNG/JPEG/HEIC 等）から ImageIO で直接サムネイルを生成する。
	/// フル解像度で `UIImage(data:)` → リサイズするより CPU/メモリ共に軽い。
	/// アーカイブ復元経路 (`MemoPreviewImageAttachment.init?(coder:)`) と
	/// 挿入経路の両方から呼ばれる。
	static func downsampledImage(fromData data: Data, pointSize: CGSize, scaleHeadroom: CGFloat = previewScaleHeadroom) -> UIImage? {
		guard pointSize.width > 0, pointSize.height > 0 else { return nil }
		guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
		let maxPx = max(pointSize.width, pointSize.height) * scaleHeadroom
		let opts: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceShouldCacheImmediately: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: maxPx
		]
		guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
		return UIImage(cgImage: cg, scale: scaleHeadroom, orientation: .up)
	}

	/// `Data` 経路で失敗した場合のフォールバック。`UIImage` を直接リサイズする。
	fileprivate static func downsampledImage(fromImage image: UIImage, pointSize: CGSize, scaleHeadroom: CGFloat = previewScaleHeadroom) -> UIImage {
		guard pointSize.width > 0, pointSize.height > 0 else { return image }
		let fmt = UIGraphicsImageRendererFormat.default()
		fmt.scale = scaleHeadroom
		fmt.opaque = false
		let renderer = UIGraphicsImageRenderer(size: pointSize, format: fmt)
		return renderer.image { _ in
			image.draw(in: CGRect(origin: .zero, size: pointSize))
		}
	}

	/// `UIImage` をオリジナル品質に近い `Data` にエンコードし、対応する UTI を返す。
	/// アルファチャネルを持つ画像のみ PNG、それ以外は JPEG。
	private static func encodedOriginalData(from image: UIImage) -> (data: Data?, uti: String) {
		let hasAlpha: Bool = {
			guard let cg = image.cgImage else { return true }
			switch cg.alphaInfo {
			case .none, .noneSkipLast, .noneSkipFirst:
				return false
			default:
				return true
			}
		}()
		if hasAlpha {
			return (image.pngData(), UTType.png.identifier)
		}
		return (image.jpegData(compressionQuality: 0.92), UTType.jpeg.identifier)
	}

	static func presentFullscreen(for attachment: NSTextAttachment, from view: UIView) {
		guard let host = view.memoContainingViewController() else { return }
		if let svg = attachment as? MemoSVGAttachment {
			let sheet = MemoFullscreenSVGViewController(svgData: svg.svgData)
			host.present(sheet, animated: true)
			return
		}
		guard let img = fullImage(from: attachment) else { return }
		let sheet = MemoFullscreenImageViewController(image: img)
		host.present(sheet, animated: true)
	}
}

extension UIView {
	fileprivate func memoContainingViewController() -> UIViewController? {
		var r: UIResponder? = self
		while let cur = r {
			if let vc = cur as? UIViewController { return vc }
			r = cur.next
		}
		return nil
	}
}

/// 添付画像を画面いっぱいに表示（タップまたは閉じるで解除）
private final class MemoFullscreenImageViewController: UIViewController {
	private let image: UIImage

	init(image: UIImage) {
		self.image = image
		super.init(nibName: nil, bundle: nil)
		modalPresentationStyle = .fullScreen
		modalTransitionStyle = .crossDissolve
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { nil }

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black

		let iv = UIImageView(image: image)
		iv.contentMode = .scaleAspectFit
		iv.isUserInteractionEnabled = true
		iv.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(iv)
		let tapImage = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
		iv.addGestureRecognizer(tapImage)

		let close = UIButton(type: .close)
		close.translatesAutoresizingMaskIntoConstraints = false
		close.accessibilityLabel = "Close"
		close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
		view.addSubview(close)

		NSLayoutConstraint.activate([
			iv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			iv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			iv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			iv.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
			close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
			close.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8)
		])

		let tap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
		tap.cancelsTouchesInView = false
		view.addGestureRecognizer(tap)
	}

	@objc private func closeTapped() {
		dismiss(animated: true)
	}
}

/// SVG をフルスクリーンでベクタ表示（ピンチでズームしても再描画でクリア）。
private final class MemoFullscreenSVGViewController: UIViewController, UIScrollViewDelegate {
	private let svgData: Data
	private let scrollView = UIScrollView()
	private let imageView = UIImageView()
	/// 初期描画時に確保する、画面サイズに対する解像度倍率。ピンチで拡大してもこの倍率まではクリア。
	private let resolutionHeadroom: CGFloat = 3
	private var didInitialRender = false

	init(svgData: Data) {
		self.svgData = svgData
		super.init(nibName: nil, bundle: nil)
		modalPresentationStyle = .fullScreen
		modalTransitionStyle = .crossDissolve
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { nil }

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black

		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.delegate = self
		scrollView.minimumZoomScale = 1
		scrollView.maximumZoomScale = 4
		scrollView.bouncesZoom = true
		scrollView.showsVerticalScrollIndicator = false
		scrollView.showsHorizontalScrollIndicator = false
		view.addSubview(scrollView)

		imageView.contentMode = .scaleAspectFit
		imageView.isUserInteractionEnabled = true
		imageView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.addSubview(imageView)

		let close = UIButton(type: .close)
		close.translatesAutoresizingMaskIntoConstraints = false
		close.accessibilityLabel = "Close"
		close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
		view.addSubview(close)

		NSLayoutConstraint.activate([
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
			imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
			imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
			imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
			imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
			imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
			imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
			close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
			close.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8)
		])

		let tap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
		imageView.addGestureRecognizer(tap)
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		guard !didInitialRender, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
		renderImage(fittingSize: scrollView.bounds.size)
		didInitialRender = true
	}

	/// SVG を `size × resolutionHeadroom` のピクセルで描画して `UIImage` 化する。
	/// アスペクト比は `scaleAspectFit` で合わせるので、画像自体は SVG の自然比を保ったまま返す。
	private func renderImage(fittingSize size: CGSize) {
		guard let svg = SVGKImage(data: svgData) else { return }
		let intrinsic: CGSize = {
			let s = svg.size
			if s.width > 0, s.height > 0 { return s }
			return size
		}()
		let fitScale = min(size.width / max(intrinsic.width, 1), size.height / max(intrinsic.height, 1))
		let target = CGSize(
			width: max(1, intrinsic.width * fitScale * resolutionHeadroom),
			height: max(1, intrinsic.height * fitScale * resolutionHeadroom)
		)
		svg.size = target
		imageView.image = svg.uiImage
	}

	func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

	@objc private func closeTapped() {
		dismiss(animated: true)
	}
}

/// `SwiftUI` から渡される幅でテキストコンテナを揃え、行が横にはみ出さないようにする。
private final class MemoWrappingTextView: UITextView, UIGestureRecognizerDelegate {
	private let imageTap = UITapGestureRecognizer()
	private let voidTap = UITapGestureRecognizer()

	override init(frame: CGRect, textContainer: NSTextContainer?) {
		super.init(frame: frame, textContainer: textContainer)
		setupImageTap()
		setupVoidTap()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		setupImageTap()
		setupVoidTap()
	}

	/// 行マージ・行間移動で別 `UITextView` へ first responder が渡っても、直前に使っていた
	/// 入力モード（英字 / 日本語 / 顔文字等）が復元されるよう、全行で同じ識別子を返す。
	override var textInputContextIdentifier: String? { "scroll.memo.line" }

	private func setupImageTap() {
		imageTap.addTarget(self, action: #selector(handleImageTap(_:)))
		imageTap.numberOfTapsRequired = 1
		imageTap.cancelsTouchesInView = false
		imageTap.delaysTouchesBegan = false
		imageTap.delaysTouchesEnded = false
		imageTap.delegate = self
		addGestureRecognizer(imageTap)
	}

	private func setupVoidTap() {
		voidTap.addTarget(self, action: #selector(handleVoidTap(_:)))
		voidTap.numberOfTapsRequired = 1
		voidTap.cancelsTouchesInView = false
		voidTap.delaysTouchesBegan = false
		voidTap.delaysTouchesEnded = false
		voidTap.delegate = self
		addGestureRecognizer(voidTap)
	}

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
		if gestureRecognizer === imageTap {
			let pt = touch.location(in: self)
			return attachmentAndIndex(at: pt) != nil
		}
		return true
	}

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		// テキスト編集（キャレット移動 / 選択）を邪魔しない
		gestureRecognizer === imageTap || gestureRecognizer === voidTap
	}

	/// 非編集中（= `!isFirstResponder`）は iOS 標準の長押し系（虫眼鏡・精密キャレット）を始動させない。
	/// タップによるフォーカス取得や、自前の `imageTap` / `voidTap` は通過させる。
	override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
		if gestureRecognizer === imageTap || gestureRecognizer === voidTap {
			return super.gestureRecognizerShouldBegin(gestureRecognizer)
		}
		if !isFirstResponder, gestureRecognizer is UILongPressGestureRecognizer {
			return false
		}
		return super.gestureRecognizerShouldBegin(gestureRecognizer)
	}

	private func attachmentAndIndex(at viewPoint: CGPoint) -> (NSTextAttachment, Int)? {
		let layoutManager = self.layoutManager
		let textContainer = self.textContainer
		var point = viewPoint
		point.x -= textContainerInset.left
		point.y -= textContainerInset.top
		point.x -= textContainer.lineFragmentPadding
		var fraction: CGFloat = 0
		let idx = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
		guard idx >= 0, idx < textStorage.length else { return nil }
		guard let att = textStorage.attribute(.attachment, at: idx, effectiveRange: nil) as? NSTextAttachment else { return nil }

		// `characterIndex(for:)` は近傍に吸い寄せられるため、添付の実矩形で厳密にヒットテストする。
		let charRange = NSRange(location: idx, length: 1)
		let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
		guard glyphRange.length > 0 else { return nil }
		let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
		return rect.contains(point) ? (att, idx) : nil
	}

	@objc private func handleImageTap(_ gesture: UITapGestureRecognizer) {
		guard gesture.state == .ended else { return }
		let pt = gesture.location(in: self)
		guard let (att, idx) = attachmentAndIndex(at: pt) else { return }
		if let chip = att as? MemoLinkChipAttachment {
			let linkVal = textStorage.attribute(.link, at: idx, effectiveRange: nil)
			guard let url = MemoLinkChipInsertion.openableHTTPURL(from: chip, linkAttribute: linkVal) else { return }
			MemoLinkChipInsertion.openInBrowser(url)
			return
		}
		MemoImageInsertion.presentFullscreen(for: att, from: self)
	}

	@objc private func handleVoidTap(_ gesture: UITapGestureRecognizer) {
		guard gesture.state == .ended else { return }
		let pt = gesture.location(in: self)
		guard attachmentAndIndex(at: pt) == nil else { return }
		// `UITextView` の既定タップ後に選択を上書きする
		DispatchQueue.main.async { [weak self] in
			self?.snapCaretForTapInTrailingOrBelowTextVoid(viewPoint: pt)
		}
	}

	/// 行末より右の余白、または本文レイアウトより下の余白をタップしたとき、その行の末尾（または文末）へキャレットを寄せる。
	private func snapCaretForTapInTrailingOrBelowTextVoid(viewPoint: CGPoint) {
		let lm = layoutManager
		let tc = textContainer
		let inset = textContainerInset
		let pad = textContainer.lineFragmentPadding

		var p = viewPoint
		p.x -= inset.left + pad
		p.y -= inset.top

		let containerW = max(1, tc.size.width)
		let containerH = max(1, tc.size.height)
		guard p.x >= -2, p.x <= containerW + 2, p.y >= -2, p.y <= containerH + 2 else { return }

		let plainLen = (text as NSString?)?.length ?? 0
		let usedBounds = lm.usedRect(for: tc)

		// 本文より下の余白 → 文末（空行なら先頭）
		if p.y > usedBounds.maxY + 0.5 {
			if !isFirstResponder { _ = becomeFirstResponder() }
			selectedRange = NSRange(location: plainLen, length: 0)
			return
		}

		guard plainLen > 0 else { return }

		var frac: CGFloat = 0
		let gi = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &frac)
		var fragGlyphRange = NSRange(location: 0, length: 0)
		let usedInFrag = lm.lineFragmentUsedRect(forGlyphAt: gi, effectiveRange: &fragGlyphRange)
		let fullFrag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: &fragGlyphRange)

		let ySlop: CGFloat = 2
		guard p.y >= fullFrag.minY - ySlop, p.y <= fullFrag.maxY + ySlop else { return }

		let xEps: CGFloat = 3
		let tailStartsAt = usedInFrag.maxX - xEps
		let inHorizontalTail = p.x > tailStartsAt && p.x <= fullFrag.maxX + xEps
		let emptyLineBand = usedInFrag.width < 1 && p.x >= fullFrag.minX - xEps && p.x <= fullFrag.maxX + xEps
		guard inHorizontalTail || emptyLineBand else { return }

		let charRange = lm.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
		let end = NSMaxRange(charRange)
		guard end >= 0, end <= plainLen else { return }

		if !isFirstResponder { _ = becomeFirstResponder() }
		selectedRange = NSRange(location: end, length: 0)
	}

	/// `typingAttributes` で挿入（タブ・箇条書きプレフィックス・キーボードアクセサリと共有）。
	/// `uniformBold` を渡したときだけ、その有無に合わせてフォントの太字を上書きする（日時挿入用）。
	fileprivate func insertWithTypingAttributes(_ string: String, uniformBold: Bool? = nil) {
		guard markedTextRange == nil else { return }
		let sel = selectedRange
		var attrs = typingAttributes
		if let uniformBold {
			let baseFont = (attrs[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
			attrs[.font] = baseFont.memoFontWithUniformBold(uniformBold)
		}
		let insertion = NSAttributedString(string: string, attributes: attrs)
		textStorage.replaceCharacters(in: sel, with: insertion)
		selectedRange = NSRange(location: sel.location + (string as NSString).length, length: 0)
		invalidateIntrinsicContentSize()
		delegate?.textViewDidChange?(self)
	}

	override var keyCommands: [UIKeyCommand]? {
		let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(keyCommandInsertTab(_:)))
		tab.wantsPriorityOverSystemBehavior = true
		return [tab]
	}

	@objc private func keyCommandInsertTab(_ sender: UIKeyCommand) {
		insertWithTypingAttributes("\t")
	}

	override func paste(_ sender: Any?) {
		if let svgData = Self.pasteboardSVGData(), MemoSVGInsertion.insertSVG(data: svgData, into: self) {
			return
		}
		if let img = UIPasteboard.general.image {
			MemoImageInsertion.insertImage(img, into: self)
			return
		}
		guard let s = UIPasteboard.general.string, !s.isEmpty else {
			super.paste(sender)
			return
		}

		if let sniffed = MemoSVGInsertion.sniffedSVGData(fromString: s),
		   MemoSVGInsertion.insertSVG(data: sniffed, into: self) {
			return
		}

		if let url = MemoLinkChipInsertion.lonePastedWebURL(s) {
			let attrs = MemoRichTextEncoding.defaultTypingAttributes()
			typingAttributes = attrs
			MemoLinkChipInsertion.insertLinkChip(for: url, into: self)
			return
		}

		let attrs = MemoRichTextEncoding.defaultTypingAttributes()
		typingAttributes = attrs

		let selected = selectedRange
		let insertion = NSAttributedString(string: s, attributes: attrs)
		textStorage.replaceCharacters(in: selected, with: insertion)
		selectedRange = NSRange(location: selected.location + (s as NSString).length, length: 0)

		invalidateIntrinsicContentSize()
		delegate?.textViewDidChange?(self)
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		guard bounds.width > 0 else { return }
		let insetW = textContainerInset.left + textContainerInset.right + textContainer.lineFragmentPadding * 2
		let w = max(1, bounds.width - insetW)
		if abs(textContainer.size.width - w) > 0.5 {
			textContainer.size = CGSize(width: w, height: .greatestFiniteMagnitude)
			invalidateIntrinsicContentSize()
		}
	}

	/// ペーストボード内を走査して SVG データを取り出す。UTI `public.svg-image` 等の生 `Data` が最優先。
	fileprivate static func pasteboardSVGData() -> Data? {
		let svgTypes = ["public.svg-image", "org.w3.scalable-vector-graphics-xml"]
		let pb = UIPasteboard.general
		for type in svgTypes {
			if let d = pb.data(forPasteboardType: type), !d.isEmpty {
				return d
			}
		}
		return nil
	}
}

/// 純正メモのように選択範囲へ太字・文字色を付けられる 1 行エディタ（`UITextView` + RTF 永続化）
struct MemoLineTextView: UIViewRepresentable {
	/// 表示用本文（すでに復元済み）。フォーカス移動時の復元コストを避けるため外から渡す。
	let attributed: NSAttributedString
	var isFocused: Bool
	var highlightQuery: String?
	/// 検索ハイライトの濃さ（0...1）。nil の場合は既定値。
	var highlightAlpha: CGFloat?
	/// `false` にすると `UITextView` の操作（タップ／編集／長押し）を完全に止める。選択モード中に使う。
	var isInteractive: Bool = true
	@Binding var pendingCaretUTF16: Int?

	var onAttributedEdit: (NSAttributedString, Int) -> Void
	var onInsertLineBreak: (NSAttributedString, NSRange) -> Void
	var onBackspaceAtBeginning: () -> Void
	var onEditingBegan: () -> Void = {}
	var onSelectionInteraction: (_ selectionLength: Int, _ caretUTF16: Int) -> Void = { _, _ in }

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	func makeUIView(context: Context) -> UITextView {
		let tv = MemoWrappingTextView()
		tv.delegate = context.coordinator
		tv.backgroundColor = .clear
		tv.allowsEditingTextAttributes = true
		let attrs = MemoRichTextEncoding.defaultTypingAttributes()
		tv.typingAttributes = attrs
		tv.attributedText = attributed
		tv.textContainer.lineFragmentPadding = 0
		tv.textContainer.widthTracksTextView = false
		tv.isScrollEnabled = false
		tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		tv.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
		tv.textContentType = nil
		tv.passwordRules = nil
		tv.smartInsertDeleteType = .yes
		tv.keyboardDismissMode = .none

		let accessory = MemoRichTextKeyboardAccessoryView()
		accessory.attach(to: tv)
		accessory.setAccentColors(MemoJournalPalette.formatBarUIColors())
		tv.inputAccessoryView = accessory

		context.coordinator.accessory = accessory

		return tv
	}

	func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
		guard let w = proposal.width, w.isFinite, w > 0 else { return nil }
		let insetW = uiView.textContainerInset.left + uiView.textContainerInset.right + uiView.textContainer.lineFragmentPadding * 2
		let cw = max(1, w - insetW)
		uiView.textContainer.size = CGSize(width: cw, height: .greatestFiniteMagnitude)
		let h = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
		return CGSize(width: w, height: h)
	}

	func updateUIView(_ uiView: UITextView, context: Context) {
		let state = MemoSignpost.signposter.beginInterval("MemoLineTextView.updateUIView")
		defer { MemoSignpost.signposter.endInterval("MemoLineTextView.updateUIView", state) }

		let coord = context.coordinator
		coord.parent = self

		// アクセサリの差し込みは UITextView 1 個あたり 1 回きりで十分。
		// `makeUIView` で既に attach しているため、通常は何もしない。
		if coord.lastAttachedAccessoryTextView !== uiView {
			coord.accessory?.attach(to: uiView)
			coord.lastAttachedAccessoryTextView = uiView
		}
		// アクセントカラーは `UIColor` のダイナミックカラー経由で trait に追従するので、
		// 一度設定すれば以降のテーマ切替も UIKit が面倒を見てくれる。毎キー再適用する必要はない。
		if !coord.didApplyAccentColors {
			coord.accessory?.setAccentColors(MemoJournalPalette.formatBarUIColors())
			coord.didApplyAccentColors = true
		}

		// 選択モード中などで完全に操作を止める。first responder を握ったままだと
		// 誤って編集が再開するため、必要なら resign も行う。
		if uiView.isUserInteractionEnabled != isInteractive {
			uiView.isUserInteractionEnabled = isInteractive
			if !isInteractive, uiView.isFirstResponder {
				uiView.resignFirstResponder()
			}
		}

		let base = attributed
		// ハイライト生成は (source, query, alpha) が同じならキャッシュを使い回す。
		// 検索結果オーバーレイを表示しながらの編集で、関係のない行の再生成が走るのを防ぐ。
		let target: NSAttributedString
		if !isFocused, let q = highlightQuery, !q.isEmpty {
			if coord.lastHighlightSource === base,
			   coord.lastHighlightQuery == q,
			   coord.lastHighlightAlpha == highlightAlpha,
			   let cached = coord.lastHighlightResult {
				target = cached
			} else {
				let made = Self.makeHighlighted(attr: base, query: q, alpha: highlightAlpha)
				coord.lastHighlightSource = base
				coord.lastHighlightQuery = q
				coord.lastHighlightAlpha = highlightAlpha
				coord.lastHighlightResult = made
				target = made
			}
		} else {
			coord.lastHighlightSource = nil
			coord.lastHighlightQuery = nil
			coord.lastHighlightAlpha = nil
			coord.lastHighlightResult = nil
			target = base
		}

		// IME 変換中（marked text）がある状態で本文を差し替えると、変換が毎入力で確定してしまう。
		let isComposing = uiView.markedTextRange != nil
		// `isFocused`（SwiftUI の focusedLineId）だけでは第一応答者と 1 フレームずれることがある（LazyVStack・
		// 行レイアウト変化など）。その間に本文を差し替えると `typingAttributes` が落ち、直後の太字などが無効になる。
		if coord.lastAppliedAttributed === target {
			// 前回適用したインスタンスと同じなら、uiView.attributedText も同一内容のはず。
			// 一番重い `isEqual:` の deep compare と `target.string == uiView.text` まるごと省ける。
		} else {
			let plainMatchesModel = target.string == (uiView.text ?? "")
			let skipBodyReplace = isComposing || (uiView.isFirstResponder && plainMatchesModel)
			if !skipBodyReplace {
				if !target.isEqual(to: uiView.attributedText) {
					uiView.attributedText = target
				}
			}
			// skipBodyReplace の場合も、UIKit 側が打鍵で attributedText を更新しているので
			// 次回は identity 一致で短絡させたい。いずれにせよ最新参照を記録する。
			coord.lastAppliedAttributed = target
		}

		if let off = pendingCaretUTF16 {
			let len = (uiView.text as NSString?)?.length ?? 0
			let clamped = max(0, min(off, len))
			uiView.selectedRange = NSRange(location: clamped, length: 0)
			let clearBinding = _pendingCaretUTF16
			DispatchQueue.main.async {
				clearBinding.wrappedValue = nil
			}
		}

		if isFocused != context.coordinator.lastSyncedIsFocused {
			context.coordinator.lastSyncedIsFocused = isFocused
			context.coordinator.scheduleResponderSync(wantFocus: isFocused, textView: uiView)
		}

		// 復元直後（既存メモを開いた／検索ヒットへジャンプした等）に、未取得のリンクチップへ
		// `LPMetadataProvider` でページタイトルを取りに行く。`MemoLinkMetadataCache` 側で URL 単位に
		// 同期キャッシュ＋ in-flight 重複排除されるため、updateUIView から何度呼んでも安全。
		MemoLinkChipInsertion.scheduleMetadataRefresh(in: uiView)
	}

	private static func makeHighlighted(attr: NSAttributedString, query: String, alpha: CGFloat?) -> NSMutableAttributedString {
		let m = NSMutableAttributedString(attributedString: attr)
		let plain = m.string as NSString
		let fullLen = plain.length
		guard !query.isEmpty, fullLen > 0 else { return m }
		let a = max(0, min(alpha ?? 0.45, 1))
		var search = NSRange(location: 0, length: fullLen)
		while search.length > 0 {
			let r = plain.range(of: query, options: .caseInsensitive, range: search)
			if r.location == NSNotFound { break }
			m.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(a), range: r)
			let next = r.location + max(1, r.length)
			search = NSRange(location: next, length: fullLen - next)
		}
		return m
	}

	final class Coordinator: NSObject, UITextViewDelegate {
		var parent: MemoLineTextView
		var lastSyncedIsFocused: Bool?
		weak var accessory: MemoRichTextKeyboardAccessoryView?
		private var responderApplyWorkItem: DispatchWorkItem?

		/// 直近 `updateUIView` で適用した attributed。identity 一致なら重い deep compare を丸ごと省く。
		var lastAppliedAttributed: NSAttributedString?
		/// 直近ハイライト生成時の (source, query, alpha, result)。同じなら `makeHighlighted` を再実行しない。
		var lastHighlightSource: NSAttributedString?
		var lastHighlightQuery: String?
		var lastHighlightAlpha: CGFloat?
		var lastHighlightResult: NSAttributedString?
		/// アクセサリを attach した UITextView。再アタッチが必要なのは view が差し替わったときだけ。
		weak var lastAttachedAccessoryTextView: UITextView?
		/// アクセントカラー適用済みフラグ（ダイナミックカラーなので trait 切替でも再適用不要）。
		var didApplyAccentColors: Bool = false

		deinit {
			responderApplyWorkItem?.cancel()
		}

		func scheduleResponderSync(wantFocus: Bool, textView: UITextView) {
			responderApplyWorkItem?.cancel()
			guard wantFocus else { return }
			// build 後の初回起動などでは、末尾行が LazyVStack から実体化した直後の
			// `becomeFirstResponder()` が UIKit 側のウインドウアタッチ完了前に呼ばれて失敗することがある
			// （失敗してもログも出ず、キーボードが永久に開かないまま停止して見える）。
			// 失敗が続く間は段階的に遅延を伸ばして複数回再試行する。
			let retryDelaysMs: [Int] = [0, 40, 120, 260, 520, 900]
			scheduleBecomeFirstResponderRetries(textView: textView, delaysMs: retryDelaysMs, attemptIndex: 0)
		}

		private func scheduleBecomeFirstResponderRetries(textView: UITextView, delaysMs: [Int], attemptIndex: Int) {
			guard attemptIndex < delaysMs.count else { return }
			let delay = delaysMs[attemptIndex]
			let item = DispatchWorkItem { [weak self, weak textView] in
				guard let self else { return }
				guard let tv = textView else { return }
				// フォーカス要求が取り下げられた（他行へ移ったなど）ら以降のリトライも止める。
				guard self.parent.isFocused, self.lastSyncedIsFocused == true else { return }
				if tv.isFirstResponder { return }
				// ウインドウ未アタッチ時の `becomeFirstResponder()` は失敗扱いにして、次の遅延で再試行する。
				if tv.window == nil {
					self.scheduleBecomeFirstResponderRetries(textView: tv, delaysMs: delaysMs, attemptIndex: attemptIndex + 1)
					return
				}
				let became = tv.becomeFirstResponder()
				if !became || !tv.isFirstResponder {
					self.scheduleBecomeFirstResponderRetries(textView: tv, delaysMs: delaysMs, attemptIndex: attemptIndex + 1)
				}
			}
			responderApplyWorkItem = item
			if delay <= 0 {
				DispatchQueue.main.async(execute: item)
			} else {
				DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: item)
			}
		}

		init(_ parent: MemoLineTextView) {
			self.parent = parent
		}

		func textViewDidChange(_ textView: UITextView) {
			let state = MemoSignpost.signposter.beginInterval("textViewDidChange")
			defer { MemoSignpost.signposter.endInterval("textViewDidChange", state) }

			let caret = textView.selectedRange.location
			parent.onAttributedEdit(textView.attributedText, caret)
			textView.invalidateIntrinsicContentSize()
		}

		func textViewDidBeginEditing(_ textView: UITextView) {
			parent.onEditingBegan()
		}

		func textViewDidEndEditing(_ textView: UITextView) {
			accessory?.resetToStyleMode()
		}

		func textViewDidChangeSelection(_ textView: UITextView) {
			guard textView.isFirstResponder, parent.isFocused else { return }
			parent.onSelectionInteraction(textView.selectedRange.length, textView.selectedRange.location)
		}

		func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
			if text.isEmpty, range.location == 0, range.length == 0 {
				parent.onBackspaceAtBeginning()
				return false
			}
			if text == "\n" || text == "\r" {
				parent.onInsertLineBreak(textView.attributedText, range)
				return false
			}
			return true
		}

		func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
			guard case .textAttachment(let attachment) = textItem.content else {
				return defaultAction
			}
			if let chip = attachment as? MemoLinkChipAttachment {
				return UIAction { [weak textView] _ in
					guard let tv = textView else { return }
					var chipIndex: Int?
					tv.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tv.textStorage.length), options: []) { value, range, stop in
						guard (value as AnyObject) === (chip as AnyObject) else { return }
						chipIndex = range.location
						stop.pointee = true
					}
					let linkVal = chipIndex.map { tv.textStorage.attribute(.link, at: $0, effectiveRange: nil) }
					guard let url = MemoLinkChipInsertion.openableHTTPURL(from: chip, linkAttribute: linkVal ?? nil) else { return }
					MemoLinkChipInsertion.openInBrowser(url)
				}
			}
			return UIAction { _ in
				MemoImageInsertion.presentFullscreen(for: attachment, from: textView)
			}
		}
	}
}

// MARK: - キーボード上ツールバー（2段階: 選択 → スタイル or 写真）

private extension UIFont {
	/// 既存のサイズ・イタリック等は維持し、太字の有無だけを揃える。
	func memoFontWithUniformBold(_ bold: Bool) -> UIFont {
		var traits = fontDescriptor.symbolicTraits
		if bold {
			traits.insert(.traitBold)
		} else {
			traits.remove(.traitBold)
		}
		guard let desc = fontDescriptor.withSymbolicTraits(traits) else { return self }
		return UIFont(descriptor: desc, size: pointSize)
	}

	func memoFontWithBoldToggled() -> UIFont {
		memoFontWithUniformBold(!fontDescriptor.symbolicTraits.contains(.traitBold))
	}
}

final class MemoRichTextKeyboardAccessoryView: UIView, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
	private enum Step {
		case root
		case style
		case photo
	}

	private weak var textView: UITextView?
	private var step: Step = .root

	private let contentStack = UIStackView()
	private let rootChoiceStack = UIStackView()
	private let styleScreenStack = UIStackView()
	private let photoScreenStack = UIStackView()
	private let styleStack = UIStackView()
	private let photoStack = UIStackView()
	private var accentButtons: [UIButton] = []
	private let toolbarHorizontalInset: CGFloat = 20
	private let touchTargetSize: CGFloat = 44
	private let chipVisualSize: CGFloat = 28
	private weak var timestampChoiceButton: UIButton?
	/// 長押しで形式ピッカーを出した直後の `touchUpInside` を無視する（送られない端末では `ended` で解除）。
	private var skipNextTimestampTouchUp = false

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = UIColor.secondarySystemBackground
		let topLine = UIView()
		topLine.backgroundColor = UIColor.separator
		topLine.translatesAutoresizingMaskIntoConstraints = false
		addSubview(topLine)

		rootChoiceStack.axis = .horizontal
		rootChoiceStack.alignment = .center
		rootChoiceStack.spacing = 12
		rootChoiceStack.distribution = .fill
		rootChoiceStack.translatesAutoresizingMaskIntoConstraints = false

		let styleChoice = makeRootChipButton(accessibilityLabel: "Text style") { b in
			b.setTitle("Aa", for: .normal)
			b.setTitleColor(.label, for: .normal)
			let base = UIFont.systemFont(ofSize: 20, weight: .semibold)
			b.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
			b.titleLabel?.adjustsFontForContentSizeCategory = true
		}
		styleChoice.addTarget(self, action: #selector(goToStyleScreen), for: .touchUpInside)
		styleChoice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let bulletChoice = makeRootChipButton(accessibilityLabel: "Bullet list") { b in
			let symFont = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20, weight: .medium))
			let cfg = UIImage.SymbolConfiguration(font: symFont, scale: .default)
			b.setImage(UIImage(systemName: "list.bullet", withConfiguration: cfg), for: .normal)
			b.tintColor = .label
		}
		bulletChoice.addTarget(self, action: #selector(bulletListTapped), for: .touchUpInside)
		bulletChoice.widthAnchor.constraint(equalToConstant: touchTargetSize).isActive = true
		bulletChoice.setContentCompressionResistancePriority(.required, for: .horizontal)

		let tabChoice = makeRootChipButton(accessibilityLabel: "Tab") { b in
			let symFont = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20, weight: .medium))
			let cfg = UIImage.SymbolConfiguration(font: symFont, scale: .default)
			b.setImage(UIImage(systemName: "arrow.right.to.line.compact", withConfiguration: cfg), for: .normal)
			b.tintColor = .label
		}
		tabChoice.addTarget(self, action: #selector(tabInsertTapped), for: .touchUpInside)
		tabChoice.widthAnchor.constraint(equalToConstant: touchTargetSize).isActive = true
		tabChoice.setContentCompressionResistancePriority(.required, for: .horizontal)

		let timestampChoice = makeRootChipButton(accessibilityLabel: "Date & time") { b in
			let symFont = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20, weight: .medium))
			let cfg = UIImage.SymbolConfiguration(font: symFont, scale: .default)
			b.setImage(UIImage(systemName: "calendar.badge.clock", withConfiguration: cfg), for: .normal)
			b.tintColor = .label
		}
		timestampChoice.addTarget(self, action: #selector(timestampInsertTapped), for: .touchUpInside)
		timestampChoice.widthAnchor.constraint(equalToConstant: touchTargetSize).isActive = true
		timestampChoice.setContentCompressionResistancePriority(.required, for: .horizontal)
		let tsLongPress = UILongPressGestureRecognizer(target: self, action: #selector(timestampLongPressed(_:)))
		tsLongPress.minimumPressDuration = 0.45
		timestampChoice.addGestureRecognizer(tsLongPress)
		timestampChoiceButton = timestampChoice

		let photoChoice = makeRootChipButton(accessibilityLabel: "Insert photo") { b in
			let symFont = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20, weight: .medium))
			let cfg = UIImage.SymbolConfiguration(font: symFont, scale: .default)
			b.setImage(UIImage(systemName: "photo", withConfiguration: cfg), for: .normal)
			b.tintColor = .label
		}
		photoChoice.addTarget(self, action: #selector(goToPhotoScreen), for: .touchUpInside)
		photoChoice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		rootChoiceStack.addArrangedSubview(styleChoice)
		rootChoiceStack.addArrangedSubview(bulletChoice)
		rootChoiceStack.addArrangedSubview(tabChoice)
		rootChoiceStack.addArrangedSubview(timestampChoice)
		rootChoiceStack.addArrangedSubview(photoChoice)

		styleStack.axis = .horizontal
		styleStack.alignment = .center
		styleStack.spacing = 10
		styleStack.distribution = .equalSpacing
		styleStack.translatesAutoresizingMaskIntoConstraints = false

		let backStyle = makeIconButton(systemName: "chevron.backward", accessibilityLabel: "Back")
		backStyle.addTarget(self, action: #selector(goToRoot), for: .touchUpInside)

		let bold = makeIconButton(systemName: "bold", accessibilityLabel: "Bold")
		bold.addTarget(self, action: #selector(boldTapped), for: .touchUpInside)

		let strike = makeIconButton(systemName: "strikethrough", accessibilityLabel: "Strikethrough")
		strike.addTarget(self, action: #selector(strikeTapped), for: .touchUpInside)

		let reset = makeColorChipButton(accessibilityLabel: "Default color")
		colorChipView(in: reset)?.backgroundColor = UIColor.label
		reset.addTarget(self, action: #selector(resetColorTapped), for: .touchUpInside)

		styleStack.addArrangedSubview(bold)
		styleStack.addArrangedSubview(strike)
		for _ in 0 ..< 3 {
			let b = makeColorChipButton(accessibilityLabel: "Text color")
			b.addTarget(self, action: #selector(colorChipTapped(_:)), for: .touchUpInside)
			accentButtons.append(b)
			styleStack.addArrangedSubview(b)
		}
		styleStack.addArrangedSubview(reset)

		styleScreenStack.axis = .horizontal
		styleScreenStack.alignment = .center
		styleScreenStack.spacing = 6
		styleScreenStack.distribution = .fill
		styleScreenStack.translatesAutoresizingMaskIntoConstraints = false
		styleScreenStack.addArrangedSubview(backStyle)
		styleScreenStack.addArrangedSubview(styleStack)

		photoStack.axis = .horizontal
		photoStack.alignment = .fill
		photoStack.spacing = 12
		photoStack.distribution = .fillEqually
		photoStack.translatesAutoresizingMaskIntoConstraints = false
		let backPhoto = makeIconButton(systemName: "chevron.backward", accessibilityLabel: "Back")
		backPhoto.addTarget(self, action: #selector(goToRoot), for: .touchUpInside)
		let library = makeIconButton(systemName: "photo.on.rectangle.angled", accessibilityLabel: "Choose from library", fillsBarWidth: true)
		library.addTarget(self, action: #selector(libraryTapped), for: .touchUpInside)
		let camera = makeIconButton(systemName: "camera", accessibilityLabel: "Take photo", fillsBarWidth: true)
		camera.addTarget(self, action: #selector(cameraTapped), for: .touchUpInside)
		camera.isHidden = !UIImagePickerController.isSourceTypeAvailable(.camera)
		photoStack.addArrangedSubview(library)
		photoStack.addArrangedSubview(camera)

		photoScreenStack.axis = .horizontal
		photoScreenStack.alignment = .center
		photoScreenStack.spacing = 6
		photoScreenStack.distribution = .fill
		photoScreenStack.translatesAutoresizingMaskIntoConstraints = false
		photoScreenStack.addArrangedSubview(backPhoto)
		photoScreenStack.addArrangedSubview(photoStack)

		contentStack.axis = .vertical
		contentStack.spacing = 0
		contentStack.translatesAutoresizingMaskIntoConstraints = false
		contentStack.addArrangedSubview(rootChoiceStack)
		contentStack.addArrangedSubview(styleScreenStack)
		contentStack.addArrangedSubview(photoScreenStack)
		addSubview(contentStack)

		NSLayoutConstraint.activate([
			topLine.topAnchor.constraint(equalTo: topAnchor),
			topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
			topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
			topLine.heightAnchor.constraint(equalToConstant: 1.0 / max(UITraitCollection.current.displayScale, 1)),
			contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: toolbarHorizontalInset),
			contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -toolbarHorizontalInset),
			contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
			contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
		])

		styleScreenStack.isHidden = true
		photoScreenStack.isHidden = true
		updateIntrinsicSize()
		autoresizingMask = [.flexibleWidth, .flexibleHeight]
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { nil }

	private func updateIntrinsicSize() {
		let size = systemLayoutSizeFitting(
			CGSize(width: UIView.layoutFittingExpandedSize.width, height: 0),
			withHorizontalFittingPriority: .fittingSizeLevel,
			verticalFittingPriority: .fittingSizeLevel
		)
		let h = max(size.height, 48)
		frame = CGRect(x: 0, y: 0, width: 320, height: h)
	}

	func attach(to tv: UITextView) {
		textView = tv
	}

	func resetToStyleMode() {
		showStep(.root)
	}

	func setAccentColors(_ colors: [UIColor]) {
		for (i, b) in accentButtons.enumerated() where i < colors.count {
			colorChipView(in: b)?.backgroundColor = colors[i]
		}
	}

	/// `reloadInputViews()` は選択範囲を落とすことがある。スタイル適用は選択に依存するため復元する。
	private func reloadInputViewsPreservingSelection() {
		guard let tv = textView else { return }
		let saved = tv.selectedRange
		tv.reloadInputViews()
		let apply: () -> Void = { [weak tv] in
			guard let tv else { return }
			let len = (tv.text as NSString).length
			let loc = min(max(0, saved.location), len)
			let maxLen = len - loc
			let safeLen = min(max(0, saved.length), maxLen)
			tv.selectedRange = NSRange(location: loc, length: safeLen)
		}
		apply()
		// システム側が次フレームで選択をリセットする場合へのフォロー
		DispatchQueue.main.async(execute: apply)
	}

	private func showStep(_ newStep: Step) {
		step = newStep
		rootChoiceStack.isHidden = newStep != .root
		styleScreenStack.isHidden = newStep != .style
		photoScreenStack.isHidden = newStep != .photo
		updateIntrinsicSize()
		reloadInputViewsPreservingSelection()
	}

	@objc private func goToRoot() {
		showStep(.root)
	}

	@objc private func goToStyleScreen() {
		showStep(.style)
	}

	@objc private func goToPhotoScreen() {
		showStep(.photo)
	}

	@objc private func bulletListTapped() {
		if let wrap = textView as? MemoWrappingTextView {
			wrap.insertWithTypingAttributes("- ")
		} else if let wrap = textView as? MemoDocumentWrappingTextView {
			wrap.insertWithTypingAttributes("- ")
		}
	}

	@objc private func tabInsertTapped() {
		if let wrap = textView as? MemoWrappingTextView {
			wrap.insertWithTypingAttributes("\t")
		} else if let wrap = textView as? MemoDocumentWrappingTextView {
			wrap.insertWithTypingAttributes("\t")
		}
	}

	@objc private func timestampInsertTapped() {
		if skipNextTimestampTouchUp {
			skipNextTimestampTouchUp = false
			return
		}
		if !MemoTimestampSettings.onboardingComplete {
			presentTimestampFormatPicker()
			return
		}
		let s = MemoTimestampSettings.formattedNow()
		let bold = MemoTimestampSettings.timestampUseBold
		if let wrap = textView as? MemoWrappingTextView {
			wrap.insertWithTypingAttributes(s + " ", uniformBold: bold)
		} else if let wrap = textView as? MemoDocumentWrappingTextView {
			wrap.insertWithTypingAttributes(s + " ", uniformBold: bold)
		}
	}

	@objc private func timestampLongPressed(_ gr: UILongPressGestureRecognizer) {
		switch gr.state {
		case .began:
			skipNextTimestampTouchUp = true
			presentTimestampFormatPicker()
		case .ended, .cancelled, .failed:
			// 長押しでタッチがキャンセルされると `touchUpInside` が来ない端末があるため、ここでもフラグを戻す。
			DispatchQueue.main.async { [weak self] in
				self?.skipNextTimestampTouchUp = false
			}
		default:
			break
		}
	}

	private func presentTimestampFormatPicker() {
		guard let host = textView?.memoContainingViewController() else { return }
		let content = MemoTimestampOptionsSheetViewController()
		let nav = UINavigationController(rootViewController: content)
		nav.modalPresentationStyle = .pageSheet
		if let src = timestampChoiceButton {
			nav.popoverPresentationController?.sourceView = src
			nav.popoverPresentationController?.sourceRect = src.bounds
		}
		host.present(nav, animated: true)
	}

	private func makeRootChipButton(accessibilityLabel: String, content: (UIButton) -> Void) -> UIButton {
		let b = UIButton(type: .system)
		b.accessibilityLabel = accessibilityLabel
		b.translatesAutoresizingMaskIntoConstraints = false
		b.backgroundColor = .clear
		content(b)
		NSLayoutConstraint.activate([
			b.heightAnchor.constraint(equalToConstant: touchTargetSize)
		])
		return b
	}

	private func notifyContentChange() {
		guard let tv = textView else { return }
		tv.delegate?.textViewDidChange?(tv)
	}

	private func makeIconButton(systemName: String, accessibilityLabel: String, fillsBarWidth: Bool = false) -> UIButton {
		let b = UIButton(type: .system)
		let img = UIImage(systemName: systemName)
		b.setImage(img, for: .normal)
		b.accessibilityLabel = accessibilityLabel
		b.tintColor = .label
		b.translatesAutoresizingMaskIntoConstraints = false
		b.heightAnchor.constraint(equalToConstant: touchTargetSize).isActive = true
		if fillsBarWidth {
			b.setContentHuggingPriority(.defaultLow, for: .horizontal)
			b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
			b.imageView?.contentMode = .scaleAspectFit
		} else {
			b.widthAnchor.constraint(equalToConstant: touchTargetSize).isActive = true
		}
		return b
	}

	private func makeColorChipButton(accessibilityLabel: String) -> UIButton {
		let b = UIButton(type: .system)
		let chip = UIView()
		chip.isUserInteractionEnabled = false
		chip.layer.cornerRadius = chipVisualSize / 2
		chip.clipsToBounds = true
		b.translatesAutoresizingMaskIntoConstraints = false
		chip.translatesAutoresizingMaskIntoConstraints = false
		b.backgroundColor = .clear
		b.addSubview(chip)
		NSLayoutConstraint.activate([
			b.widthAnchor.constraint(equalToConstant: touchTargetSize),
			b.heightAnchor.constraint(equalToConstant: touchTargetSize),
			chip.centerXAnchor.constraint(equalTo: b.centerXAnchor),
			chip.centerYAnchor.constraint(equalTo: b.centerYAnchor),
			chip.widthAnchor.constraint(equalToConstant: chipVisualSize),
			chip.heightAnchor.constraint(equalToConstant: chipVisualSize)
		])
		b.accessibilityLabel = accessibilityLabel
		return b
	}

	private func colorChipView(in button: UIButton) -> UIView? {
		button.subviews.first(where: { !$0.isUserInteractionEnabled })
	}

	@objc private func boldTapped() {
		guard let tv = textView else { return }
		let range = tv.selectedRange
		if range.length > 0 {
			let sub = tv.attributedText.attributedSubstring(from: range)
			var allBold = true
			sub.enumerateAttribute(.font, in: NSRange(location: 0, length: sub.length)) { val, _, stop in
				let font = (val as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
				if !font.fontDescriptor.symbolicTraits.contains(.traitBold) {
					allBold = false
					stop.pointee = true
				}
			}
			let setBold = !allBold
			tv.textStorage.beginEditing()
			tv.textStorage.enumerateAttribute(.font, in: range, options: []) { val, r, _ in
				let font = (val as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
				tv.textStorage.addAttribute(.font, value: font.memoFontWithUniformBold(setBold), range: r)
			}
			tv.textStorage.endEditing()
		} else {
			var ta = tv.typingAttributes
			let font = (ta[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
			ta[.font] = font.memoFontWithBoldToggled()
			tv.typingAttributes = ta
		}
		notifyContentChange()
	}

	@objc private func strikeTapped() {
		guard let tv = textView else { return }
		let strikeVal = NSUnderlineStyle.single.rawValue
		let range = tv.selectedRange
		if range.length > 0 {
			let sub = tv.attributedText.attributedSubstring(from: range)
			var allStruck = true
			sub.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: sub.length)) { val, _, stop in
				if (val as? Int ?? 0) == 0 {
					allStruck = false
					stop.pointee = true
				}
			}
			if allStruck {
				tv.textStorage.removeAttribute(.strikethroughStyle, range: range)
			} else {
				tv.textStorage.addAttribute(.strikethroughStyle, value: strikeVal, range: range)
			}
		} else {
			var ta = tv.typingAttributes
			let cur = ta[.strikethroughStyle] as? Int ?? 0
			if cur == 0 {
				ta[.strikethroughStyle] = strikeVal
			} else {
				ta.removeValue(forKey: .strikethroughStyle)
			}
			tv.typingAttributes = ta
		}
		notifyContentChange()
	}

	@objc private func resetColorTapped() {
		guard let tv = textView else { return }
		let color = UIColor.label
		if tv.selectedRange.length > 0 {
			tv.textStorage.addAttribute(.foregroundColor, value: color, range: tv.selectedRange)
			tv.textStorage.removeAttribute(.strikethroughStyle, range: tv.selectedRange)
		} else {
			var ta = tv.typingAttributes
			ta[.foregroundColor] = color
			ta.removeValue(forKey: .strikethroughStyle)
			tv.typingAttributes = ta
		}
		notifyContentChange()
	}

	@objc private func colorChipTapped(_ sender: UIButton) {
		guard let tv = textView, let color = colorChipView(in: sender)?.backgroundColor else { return }
		if tv.selectedRange.length > 0 {
			tv.textStorage.addAttribute(.foregroundColor, value: color, range: tv.selectedRange)
		} else {
			var ta = tv.typingAttributes
			ta[.foregroundColor] = color
			tv.typingAttributes = ta
		}
		notifyContentChange()
	}

	@objc private func libraryTapped() {
		guard let host = textView?.memoContainingViewController() else { return }
		var config = PHPickerConfiguration()
		config.filter = .images
		config.selectionLimit = 1
		let picker = PHPickerViewController(configuration: config)
		picker.delegate = self
		host.present(picker, animated: true)
	}

	@objc private func cameraTapped() {
		guard UIImagePickerController.isSourceTypeAvailable(.camera),
		      let host = textView?.memoContainingViewController()
		else { return }
		let picker = UIImagePickerController()
		picker.sourceType = .camera
		picker.delegate = self
		host.present(picker, animated: true)
	}

	func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
		picker.dismiss(animated: true)
		guard let item = results.first else { return }
		item.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
			guard let self, let img = obj as? UIImage else { return }
			DispatchQueue.main.async {
				guard let tv = self.textView else { return }
				MemoImageInsertion.insertImage(img, into: tv)
			}
		}
	}

	func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
		picker.dismiss(animated: true)
		if let img = info[.originalImage] as? UIImage, let tv = textView {
			MemoImageInsertion.insertImage(img, into: tv)
		}
	}

	func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
		picker.dismiss(animated: true)
	}
}
