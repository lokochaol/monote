//
//  MemoSVGAttachment.swift
//  scroll
//

import SVGKit
import UIKit

// MARK: - SVG 添付（ベクタ生データを保持し、表示サイズごとに都度 SVGKit でラスタライズ）

/// 重要:
/// `NSTextAttachment.init(coder:)` は内部的に `[self initWithData:ofType:]` を呼び出すため、
/// `init(data:ofType:)` の override で Swift 側のプロパティを更新してしまうと、`init?(coder:)`
/// で先に復元した `svgData` 等が上書きされ、アーカイブ round-trip 時に SVG が消える。
/// したがって以下を徹底する:
///   * 保存プロパティは `var` + デフォルト値にし、Swift の初期化順序を緩める。
///   * `init(data:ofType:)` は何も触らず `super` だけ呼ぶ。
///   * `init?(coder:)` は **先に** `super.init(coder:)` を呼んで上記経路を通過させた **あと** で、
///     改めて `coder` からプロパティを復元する。
@objc(MemoSVGAttachment)
final class MemoSVGAttachment: NSTextAttachment {
	private static let codingSVGData = "MemoSVGData"
	private static let codingIntrinsicW = "MemoSVGIntrinsicW"
	private static let codingIntrinsicH = "MemoSVGIntrinsicH"
	private static let codingPreviewW = "MemoSVGPreviewW"
	private static let codingPreviewH = "MemoSVGPreviewH"

	/// 元の SVG データ。コピー／再起動後の完全復元のため永続化する。
	var svgData: Data = Data()
	/// SVG の自然サイズ（`viewBox` / `width|height` から）。無ければ `.zero`。
	var intrinsicSize: CGSize = .zero
	/// 行内の表示枠。`attachmentBounds` で使用。
	var previewLayoutSize: CGSize = .zero

	/// 直近に描画した UIImage と、そのピクセル実寸のキャッシュ。
	private var cachedImage: UIImage?
	private var cachedPixelSize: CGSize = .zero

	init(svgData: Data, intrinsicSize: CGSize, previewLayoutSize: CGSize) {
		super.init(data: nil, ofType: nil)
		self.svgData = svgData
		self.intrinsicSize = intrinsicSize
		self.previewLayoutSize = previewLayoutSize
	}

	/// ここでは **意図的に何もしない**。`init?(coder:)` から `super.init(coder:)` 経由で呼ばれた際に
	/// Swift 側の保存プロパティを巻き戻さないための措置。素の NSTextAttachment 初期化のみ行う。
	override init(data contentData: Data?, ofType uti: String?) {
		super.init(data: contentData, ofType: uti)
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		var len: Int = 0
		if let ptr = coder.decodeBytes(forKey: Self.codingSVGData, returnedLength: &len), len > 0 {
			svgData = Data(bytes: ptr, count: len)
		}
		intrinsicSize = CGSize(
			width: CGFloat(coder.decodeDouble(forKey: Self.codingIntrinsicW)),
			height: CGFloat(coder.decodeDouble(forKey: Self.codingIntrinsicH))
		)
		previewLayoutSize = CGSize(
			width: CGFloat(coder.decodeDouble(forKey: Self.codingPreviewW)),
			height: CGFloat(coder.decodeDouble(forKey: Self.codingPreviewH))
		)
		if previewLayoutSize.width <= 0 || previewLayoutSize.height <= 0 {
			if bounds.width > 0, bounds.height > 0 {
				previewLayoutSize = bounds.size
			} else {
				previewLayoutSize = CGSize(width: 120, height: 120)
			}
		}
	}

	override class var supportsSecureCoding: Bool { true }

	override func encode(with coder: NSCoder) {
		super.encode(with: coder)
		svgData.withUnsafeBytes { buf in
			guard let base = buf.baseAddress, svgData.count > 0 else { return }
			coder.encodeBytes(base.assumingMemoryBound(to: UInt8.self), length: svgData.count, forKey: Self.codingSVGData)
		}
		coder.encode(Double(intrinsicSize.width), forKey: Self.codingIntrinsicW)
		coder.encode(Double(intrinsicSize.height), forKey: Self.codingIntrinsicH)
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

	override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex: Int) -> UIImage? {
		let size = imageBounds.size
		let scale = displayScale(for: textContainer)
		if size.width <= 0 || size.height <= 0 {
			return renderedImage(atDisplaySize: previewLayoutSize, displayScale: scale)
		}
		return renderedImage(atDisplaySize: size, displayScale: scale)
	}

	/// 指定した表示サイズ（ポイント）でラスタライズ。ピクセルサイズが前回と一致していればキャッシュを返す。
	/// `displayScale` は描画先の trait collection から取得した値を渡す。`nil`/`0` の場合は現在の
	/// `UITraitCollection.current.displayScale` を用い、それも取れなければ 2.0 にフォールバックする。
	func renderedImage(atDisplaySize size: CGSize, displayScale: CGFloat? = nil) -> UIImage? {
		guard size.width > 0, size.height > 0, !svgData.isEmpty else { return nil }
		let scale = resolvedDisplayScale(displayScale)
		let pixel = CGSize(width: size.width * scale, height: size.height * scale)
		if let cached = cachedImage,
		   abs(cachedPixelSize.width - pixel.width) < 0.5,
		   abs(cachedPixelSize.height - pixel.height) < 0.5 {
			return cached
		}
		guard let svg = SVGKImage(data: svgData) else { return nil }
		svg.size = size
		let rendered = svg.uiImage
		cachedImage = rendered
		cachedPixelSize = pixel
		return rendered
	}

	/// `textContainer` から辿れる描画先の `displayScale` を返す。取得できない場合は `nil`。
	/// `NSTextContainer` には view への公開参照が無いため、現状は contextual な
	/// `UITraitCollection.current` に委ねる。
	private func displayScale(for textContainer: NSTextContainer?) -> CGFloat? {
		_ = textContainer
		let s = UITraitCollection.current.displayScale
		return s > 0 ? s : nil
	}

	private func resolvedDisplayScale(_ provided: CGFloat?) -> CGFloat {
		if let s = provided, s > 0 { return s }
		let current = UITraitCollection.current.displayScale
		if current > 0 { return current }
		return 2.0
	}
}

// MARK: - SVG 挿入（`MemoImageInsertion.insertImage` と同じ枠計算を用いて `MemoSVGAttachment` を挿入）

enum MemoSVGInsertion {
	private static let previewMaxWidth: CGFloat = 152
	private static let previewMinWidth: CGFloat = 88
	private static let previewWidthFraction: CGFloat = 0.38
	private static let previewMaxHeight: CGFloat = 200

	/// クリップボード等から渡された `Data` を SVG として行内に挿入する。失敗時は `false`。
	@discardableResult
	static func insertSVG(data: Data, into textView: UITextView) -> Bool {
		guard !data.isEmpty, let svg = SVGKImage(data: data) else { return false }
		let intrinsic: CGSize = {
			let s = svg.size
			if s.width > 0, s.height > 0 { return s }
			return CGSize(width: 150, height: 150)
		}()

		let insetW = textView.textContainerInset.left + textView.textContainerInset.right + textView.textContainer.lineFragmentPadding * 2
		let containerW = max(1, textView.bounds.width - insetW)
		let previewCap = min(previewMaxWidth, max(previewMinWidth, containerW * previewWidthFraction))
		let font = (textView.typingAttributes[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)

		let iw = max(intrinsic.width, 1)
		let ih = max(intrinsic.height, 1)

		var displayW = previewCap
		var displayH = displayW * (ih / iw)
		if displayH > previewMaxHeight {
			displayH = previewMaxHeight
			displayW = displayH * (iw / ih)
		}

		let attachment = MemoSVGAttachment(
			svgData: data,
			intrinsicSize: intrinsic,
			previewLayoutSize: CGSize(width: displayW, height: displayH)
		)
		let midY = (font.capHeight - displayH) / 2
		attachment.bounds = CGRect(x: 0, y: midY, width: displayW, height: displayH)

		let attrString = NSMutableAttributedString(attachment: attachment)
		let baseAttrs = MemoRichTextEncoding.defaultTypingAttributes()
		attrString.addAttributes(baseAttrs, range: NSRange(location: 0, length: attrString.length))

		let sel = textView.selectedRange
		textView.textStorage.replaceCharacters(in: sel, with: attrString)
		textView.selectedRange = NSRange(location: sel.location + attrString.length, length: 0)
		textView.invalidateIntrinsicContentSize()
		textView.delegate?.textViewDidChange?(textView)
		return true
	}

	/// 文字列先頭が `<?xml` / `<svg` で始まり `</svg>` を含むなら SVG と見なして `Data` を返す。
	static func sniffedSVGData(fromString raw: String) -> Data? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed.first == "<" else { return nil }
		let lower = trimmed.lowercased()
		let startsLikely = lower.hasPrefix("<?xml") || lower.hasPrefix("<svg") || lower.hasPrefix("<!--")
		guard startsLikely, lower.contains("<svg"), lower.contains("</svg>") else { return nil }
		return trimmed.data(using: .utf8)
	}
}
