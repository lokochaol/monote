//
//  MemoSVGAttachment.swift
//  scroll
//

import CryptoKit
import SVGKit
import UIKit

// MARK: - SVG ラスタ結果の共有キャッシュ
//
// `MemoSVGAttachment` はアーカイブ round-trip や `LazyVStack` による行の再生成で
// インスタンス自体が作り直されることがあるため、アタッチメントに閉じたキャッシュだけでは
// 同じ SVG を何度もラスタライズしてしまう。そこで「SVG の内容ハッシュ + 描画ピクセルサイズ」
// をキーにしたプロセス共通の `NSCache` を用意し、再入場・複製・行跨ぎのすべてで
// ラスタ結果を使い回せるようにする。
enum MemoSVGRasterCache {
	/// 共有ラスタキャッシュ。件数だけで制限。`UIImage` はピクセルバッファを持つので
	/// メモリ圧を受けると自動的に中身が捨てられる。
	static let cache: NSCache<NSString, UIImage> = {
		let c = NSCache<NSString, UIImage>()
		c.countLimit = 256
		c.name = "MemoSVGRasterCache"
		return c
	}()

	/// 内容ベースのキーを生成する。`dataHash` は `MemoSVGAttachment` が保持する
	/// `Data` の SHA-256 先頭 16 バイト（16 進）を想定。
	static func key(dataHashHex: String, pixelW: Int, pixelH: Int) -> NSString {
		"\(dataHashHex)_\(pixelW)x\(pixelH)" as NSString
	}
}

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
	/// 旧フォーマット: アーカイブ内に SVG バイト列を直接埋め込んでいた頃のキー。
	/// 互換のため読み出し時のみ参照する。書き出しは外部ストアに切り替わる。
	private static let codingSVGData = "MemoSVGData"
	/// 新フォーマット: `MemoAttachmentStore` に保存した SVG ファイルの 16 進ハッシュを乗せる。
	/// アーカイブ自体には数十バイトしか乗らないので、行を持ち回る `richTextArchive` が劇的に軽くなる。
	private static let codingSVGRefHash = "MemoSVGRefHash"
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
	/// このインスタンスに閉じた「ごく短い寿命」のキャッシュ。共有キャッシュ (`MemoSVGRasterCache`) の
	/// 前段として、同一レイアウト中の反復参照を高速化する。
	private var cachedImage: UIImage?
	private var cachedPixelSize: CGSize = .zero

	/// `svgData` から計算した共有キャッシュ用のキー断片。`svgData` が変わらない限り使い回す。
	private var cachedSVGDataHashHex: String?

	/// バックグラウンドラスタ中のピクセルサイズ（`nil` なら走っていない）。
	/// 同一サイズで複数回スケジュールされないようにするための目印。
	private var inflightRenderPixel: CGSize?

	/// バックグラウンドラスタが完了した時点で再描画をトリガしたい `NSLayoutManager`。
	/// `LazyVStack` 由来で `UITextView` が作り直されると古い `layoutManager` は
	/// ARC で破棄されるため、弱参照で持ち失効した場合は何もしないでよい。
	private weak var inflightLayoutManager: NSLayoutManager?

	/// SVGKit のパース＋ラスタライズを流す専用シリアルキュー。
	/// SVGKit は共有状態を持つため、複数画像を同時に描画すると稀にクラッシュしうる。
	/// シリアル化しておけば安全で、体感的にも数十ms×N の直列実行で十分速い。
	private static let asyncRenderQueue = DispatchQueue(label: "app.memo.svg.render", qos: .userInitiated)

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
		// 旧フォーマット（インライン埋め込み）優先で復元。
		// 旧データは外部ストアに移行されるまで読み続けられるよう、ここで取れたら採用する。
		var len: Int = 0
		if let ptr = coder.decodeBytes(forKey: Self.codingSVGData, returnedLength: &len), len > 0 {
			svgData = Data(bytes: ptr, count: len)
		}
		// 新フォーマット: 外部ストアからハッシュ参照で読み戻す。
		// 旧キーが空のときだけ叩く（旧データを再エンコードしたあとはこちらが本流になる）。
		if svgData.isEmpty,
		   let hex = coder.decodeObject(of: NSString.self, forKey: Self.codingSVGRefHash) as String?,
		   let bytes = MemoAttachmentStore.read(hashHex: hex, ext: "svg") {
			svgData = bytes
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
		// SVG バイト列はアーカイブ内には埋め込まず、`MemoAttachmentStore` 配下の
		// 外部ファイルへ書き出してハッシュだけを乗せる。
		// 何らかの事情で外部書き込みが失敗した場合のみ、従来どおり旧キーで埋め込んで救う。
		if !svgData.isEmpty {
			if let hex = MemoAttachmentStore.write(data: svgData, ext: "svg") {
				coder.encode(hex as NSString, forKey: Self.codingSVGRefHash)
			} else {
				svgData.withUnsafeBytes { buf in
					guard let base = buf.baseAddress, svgData.count > 0 else { return }
					coder.encodeBytes(base.assumingMemoryBound(to: UInt8.self), length: svgData.count, forKey: Self.codingSVGData)
				}
			}
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

	/// TextKit から呼ばれる表示用のエントリ。
	/// 1. キャッシュ（ローカル / 共有）にヒットすれば同期で返す。
	/// 2. ヒットしなければ `nil` を返しつつバックグラウンドでラスタライズをスケジュールし、
	///    完了時に該当範囲の再描画を `NSLayoutManager` に依頼する。
	/// これにより、`LazyVStack` で行が描画範囲に入った瞬間のメインスレッド停止時間が消える。
	override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex: Int) -> UIImage? {
		let scale = resolvedDisplayScale(displayScale(for: textContainer))
		let targetSize: CGSize = {
			if imageBounds.width > 0, imageBounds.height > 0 { return imageBounds.size }
			return previewLayoutSize
		}()
		guard targetSize.width > 0, targetSize.height > 0, !svgData.isEmpty else { return nil }

		let pixel = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
		if let cached = cachedImage,
		   abs(cachedPixelSize.width - pixel.width) < 0.5,
		   abs(cachedPixelSize.height - pixel.height) < 0.5 {
			return cached
		}
		let cacheKey = sharedCacheKey(pixel: pixel)
		if let shared = MemoSVGRasterCache.cache.object(forKey: cacheKey) {
			cachedImage = shared
			cachedPixelSize = pixel
			return shared
		}
		scheduleAsyncRender(
			targetSize: targetSize,
			pixel: pixel,
			cacheKey: cacheKey,
			layoutManager: textContainer?.layoutManager
		)
		// 初回はサイズだけ `attachmentBounds` が抑えてくれるので、画像は「描画準備中」として
		// 空のままにする。完了後にメインスレッドで `invalidateDisplay` が走って差し替わる。
		return nil
	}

	private func scheduleAsyncRender(
		targetSize: CGSize,
		pixel: CGSize,
		cacheKey: NSString,
		layoutManager: NSLayoutManager?
	) {
		// 既に同サイズの描画が走っているなら、最新の `layoutManager` だけ更新して終了。
		if let inflight = inflightRenderPixel,
		   abs(inflight.width - pixel.width) < 0.5,
		   abs(inflight.height - pixel.height) < 0.5 {
			if let lm = layoutManager { inflightLayoutManager = lm }
			return
		}
		inflightRenderPixel = pixel
		if let lm = layoutManager { inflightLayoutManager = lm }

		let data = svgData
		Self.asyncRenderQueue.async { [weak self] in
			let rendered: UIImage? = {
				guard let svg = SVGKImage(data: data) else { return nil }
				svg.size = targetSize
				return svg.uiImage
			}()
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				if let rendered {
					MemoSVGRasterCache.cache.setObject(rendered, forKey: cacheKey)
					self.cachedImage = rendered
					self.cachedPixelSize = pixel
				}
				// 同じピクセルサイズの inflight マーカーをクリアする。
				// 途中で別サイズの描画が上書きしていた場合は触らない。
				if let p = self.inflightRenderPixel,
				   abs(p.width - pixel.width) < 0.5,
				   abs(p.height - pixel.height) < 0.5 {
					self.inflightRenderPixel = nil
				}
				self.invalidateDisplayAfterRender()
			}
		}
	}

	/// ラスタ完了後に、自身のアタッチメントが貼られている位置だけを再描画させる。
	/// `textStorage` は複数 `NSLayoutManager` に共有されうるため全てに通知する。
	private func invalidateDisplayAfterRender() {
		guard let lm = inflightLayoutManager, let ts = lm.textStorage else { return }
		let full = NSRange(location: 0, length: ts.length)
		ts.enumerateAttribute(.attachment, in: full, options: []) { value, range, stop in
			guard let a = value as? MemoSVGAttachment, a === self else { return }
			for manager in ts.layoutManagers {
				manager.invalidateDisplay(forCharacterRange: range)
			}
			stop.pointee = true
		}
	}

	/// 指定した表示サイズ（ポイント）でラスタライズ。
	/// 1. インスタンスローカルのキャッシュ (`cachedImage`) にヒットすれば即返す。
	/// 2. プロセス共有の `MemoSVGRasterCache` にヒットすればインスタンスローカルにも積んで返す。
	/// 3. どちらも無ければ `SVGKit` でラスタライズし、両方のキャッシュに書き戻す。
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
		let cacheKey = sharedCacheKey(pixel: pixel)
		if let shared = MemoSVGRasterCache.cache.object(forKey: cacheKey) {
			cachedImage = shared
			cachedPixelSize = pixel
			return shared
		}
		guard let svg = SVGKImage(data: svgData) else { return nil }
		svg.size = size
		let rendered = svg.uiImage
		if let rendered {
			MemoSVGRasterCache.cache.setObject(rendered, forKey: cacheKey)
		}
		cachedImage = rendered
		cachedPixelSize = pixel
		return rendered
	}

	/// `svgData` の SHA-256 先頭 16 バイト（16 進文字列）を内容ハッシュとして返す。
	/// `svgData` が変わらない限り 1 度計算すれば以降は使い回す。
	/// 厳密な暗号強度は不要だが、`Data.hashValue` はプロセス毎にシードが変わり衝突しやすいので
	/// 共有キャッシュでは安定したハッシュを使う。
	fileprivate func svgDataHashHex() -> String {
		if let h = cachedSVGDataHashHex { return h }
		let digest = SHA256.hash(data: svgData)
		var hex = ""
		hex.reserveCapacity(32)
		for byte in digest.prefix(16) {
			hex.append(String(format: "%02x", byte))
		}
		cachedSVGDataHashHex = hex
		return hex
	}

	private func sharedCacheKey(pixel: CGSize) -> NSString {
		MemoSVGRasterCache.key(
			dataHashHex: svgDataHashHex(),
			pixelW: Int(pixel.width.rounded()),
			pixelH: Int(pixel.height.rounded())
		)
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
