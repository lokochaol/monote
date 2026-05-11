//
//  MemoLinkChip.swift
//  scroll
//

import LinkPresentation
import UIKit

// MARK: - 貼り付け URL をチップ表示（タップで既定ブラウザで開く）

enum MemoLinkChipInsertion {
	/// 改行を含まず、先頭末尾空白のみの 1 件の http(s) URL ならその URL。
	static func lonePastedWebURL(_ raw: String) -> URL? {
		var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		t = t.replacingOccurrences(of: "\u{200B}", with: "")
		t = t.replacingOccurrences(of: "\u{FEFF}", with: "")

		func parseHTTPURL(_ s: String) -> URL? {
			guard !s.isEmpty, !s.contains(where: \.isNewline) else { return nil }
			guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
			guard scheme == "http" || scheme == "https", url.host != nil else { return nil }
			return url
		}

		if let u = parseHTTPURL(t) { return u }

		// 文の一部としてコピーされた末尾の句読点を外す（例: "https://…/uuid。"）
		let trimEndChars = CharacterSet(charactersIn: ".,;。，")
		while let last = t.unicodeScalars.last, trimEndChars.contains(last) {
			t.removeLast()
			if let u = parseHTTPURL(t) { return u }
		}

		// `URL(string:)` と微妙に食い違うが全体がリンクとして認識できる場合
		guard !t.isEmpty, !t.contains(where: \.isNewline) else { return nil }
		if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
			let len = (t as NSString).length
			let full = NSRange(location: 0, length: len)
			if let m = detector.firstMatch(in: t, options: [], range: full),
			   m.resultType == .link,
			   let url = m.url,
			   m.range == full,
			   let scheme = url.scheme?.lowercased(),
			   scheme == "http" || scheme == "https",
			   url.host != nil {
				return url
			}
		}
		return nil
	}

	@MainActor
	static func openInBrowser(_ url: URL) {
		guard let scheme = url.scheme?.lowercased(),
		      scheme == "http" || scheme == "https",
		      url.host != nil
		else { return }
		UIApplication.shared.open(url, options: [:], completionHandler: nil)
	}

	/// タップで開く URL。常に元の http(s) 絶対 URL（`linkURL`）を優先し、添付が壊れたときだけ `.link` をフォールバックに使う。
	static func openableHTTPURL(from chip: MemoLinkChipAttachment, linkAttribute: Any?) -> URL? {
		if MemoLinkChipAttachment.isOpenableHTTPURL(chip.linkURL) {
			return chip.linkURL
		}
		return httpURL(fromLinkAttribute: linkAttribute)
	}

	private static func httpURL(fromLinkAttribute any: Any?) -> URL? {
		let url: URL?
		switch any {
		case let u as URL:
			url = u
		case let s as String:
			url = URL(string: s)
		case let s as NSString:
			url = URL(string: s as String)
		case let u as NSURL:
			url = u as URL
		default:
			url = nil
		}
		guard let url, MemoLinkChipAttachment.isOpenableHTTPURL(url) else { return nil }
		return url
	}

	@MainActor
	static func insertLinkChip(for url: URL, into textView: UITextView) {
		guard textView.markedTextRange == nil else { return }
		let font = (textView.typingAttributes[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
		let insetW = textView.textContainerInset.left + textView.textContainerInset.right + textView.textContainer.lineFragmentPadding * 2
		let containerW = max(1, textView.bounds.width - insetW)

		let attachment = MemoLinkChipAttachment(url: url, bodyFont: font, containerWidth: containerW, traitCollection: textView.traitCollection)
		let attrString = NSMutableAttributedString(attachment: attachment)
		let baseAttrs = MemoRichTextEncoding.defaultTypingAttributes()
		let chipRange = NSRange(location: 0, length: attrString.length)
		attrString.addAttributes(baseAttrs, range: chipRange)
		attrString.addAttribute(.link, value: url, range: chipRange)

		let sel = textView.selectedRange
		textView.textStorage.replaceCharacters(in: sel, with: attrString)
		textView.selectedRange = NSRange(location: sel.location + attrString.length, length: 0)
		textView.invalidateIntrinsicContentSize()
		textView.delegate?.textViewDidChange?(textView)

		// 挿入直後に「リンク先のページタイトル」を取りに行く。取得できたチップから順に表示が更新される。
		scheduleMetadataRefresh(in: textView)
	}

	/// テキストビュー内の全 `MemoLinkChipAttachment` を走査し、本物のページタイトルが未取得のチップにメタデータ取得を仕掛ける。
	/// 取得済み URL は `MemoLinkMetadataCache` 側で同期キャッシュ＋ inFlight 重複排除されるため、何度呼んでも安全。
	/// 加えて、何らかの理由で `linkURL` が `scroll:link-chip-invalid` 等の壊れた値で
	/// 復元されてしまったチップは、同じ字位置の `.link` 属性から本来の URL を取り戻す。
	@MainActor
	static func scheduleMetadataRefresh(in textView: UITextView) {
		let storage = textView.textStorage
		let length = storage.length
		guard length > 0 else { return }
		// 壊れたチップを `.link` 属性から復旧する。再バインドできた場合のみ、後段でメタデータ取得対象に含める。
		var pending: [MemoLinkChipAttachment] = []
		var didRebind = false
		storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: length), options: []) { value, range, _ in
			guard let chip = value as? MemoLinkChipAttachment else { return }
			if !MemoLinkChipAttachment.isOpenableHTTPURL(chip.linkURL) {
				let linkValue = storage.attribute(.link, at: range.location, effectiveRange: nil)
				if let recovered = httpURL(fromLinkAttribute: linkValue) {
					chip.rebind(url: recovered, in: textView)
					didRebind = true
				} else {
					// `.link` 属性も信用できないチップはメタデータ取得対象から外す（タップ時の `openableHTTPURL` でも開けない）。
					return
				}
			}
			guard chip.customTitle == nil else { return }
			pending.append(chip)
		}
		// 壊れていたチップを再バインドした場合は、保存対象が変わったことを上位に通知して
		// アーカイブを書き直す（次回起動時の復元で同じ問題が再発しないようにする）。
		if didRebind {
			textView.delegate?.textViewDidChange?(textView)
		}
		guard !pending.isEmpty else { return }
		for chip in pending {
			// 同期キャッシュにヒットすれば await 待ちなく即時反映（再起動時に過去取得済み URL の表示を素早く戻す）。
			if let cached = MemoLinkMetadataCache.shared.cachedTitle(for: chip.linkURL) {
				chip.applyFetchedTitle(cached, in: textView)
				continue
			}
			let url = chip.linkURL
			let token = chip.refreshToken
			Task { @MainActor [weak textView] in
				guard let title = await MemoLinkMetadataCache.shared.fetchTitle(for: url) else { return }
				guard let textView else { return }
				// 取得待ち中にチップが削除・差し替えされている可能性があるため、refreshToken で同一性を再確認する。
				guard let liveChip = findChip(matching: token, in: textView) else { return }
				liveChip.applyFetchedTitle(title, in: textView)
			}
		}
	}

	@MainActor
	private static func findChip(matching token: UUID, in textView: UITextView) -> MemoLinkChipAttachment? {
		let storage = textView.textStorage
		var found: MemoLinkChipAttachment?
		storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, stop in
			guard let chip = value as? MemoLinkChipAttachment, chip.refreshToken == token else { return }
			found = chip
			stop.pointee = true
		}
		return found
	}
}

// MARK: - Attachment

@objc(MemoLinkChipAttachment)
final class MemoLinkChipAttachment: NSTextAttachment {
	private enum Coding {
		static let url = "MemoLinkChipURL"
		static let title = "MemoLinkChipTitle"
		static let layoutW = "MemoLinkChipLW"
		static let layoutH = "MemoLinkChipLH"
		static let token = "MemoLinkChipTok"
	}

	/// `NSTextAttachment` の復元・複製で `init(data:ofType:)` が呼ばれるため、URL は必ず `contents` に載せる。
	private static let contentsUTI = "com.scroll.memo-link-chip"

	private struct ContentsPayload: Codable {
		var urlString: String
		/// `LPMetadataProvider` で取得済みの本物のページタイトル。未取得のときは空文字列。
		var title: String
		var token: String
	}

	/// `contents` 先頭に「絶対 URL + 改行」を載せ、JSON 部分が欠損しても URL だけ復元できるようにする。
	private static let contentsURLLineDelimiter = "\n".utf8.first!

	private(set) var linkURL: URL
	/// `LPMetadataProvider` で実際に取得できたページタイトル（`<title>` / OG）。未取得 / 取得失敗時は nil。
	/// nil の間は `fallbackTitle(for: linkURL)` が表示に使われる。
	private(set) var customTitle: String?
	/// メタデータ取得完了後に同一添付を特定する。
	let refreshToken: UUID

	/// 表示用ラベル。`customTitle` があればそれを優先し、なければ URL から作る短縮ラベル。
	var displayTitle: String {
		if let t = customTitle, !t.isEmpty { return Self.truncatedDisplayTitle(t) }
		return Self.fallbackTitle(for: linkURL)
	}

	/// 表示は常に `linkURL` 由来の短いラベルのみ。開く URL は `linkURL`（と `.link` フォールバック）。
	init(url: URL, bodyFont: UIFont, containerWidth: CGFloat, traitCollection: UITraitCollection) {
		let token = UUID()
		self.linkURL = url
		self.customTitle = nil
		self.refreshToken = token
		super.init(data: Self.makeContentsData(url: url, customTitle: nil, token: token), ofType: Self.contentsUTI)
		applyRendering(maxChipWidth: containerWidth * 0.72, bodyFont: bodyFont, traitCollection: traitCollection)
	}

	override init(data contentData: Data?, ofType uti: String?) {
		if let contentData, !contentData.isEmpty, let parsed = Self.decodeAttachmentContents(contentData) {
			self.linkURL = parsed.url
			self.customTitle = parsed.title.isEmpty ? nil : parsed.title
			self.refreshToken = parsed.token
		} else {
			// デコード不能なときのフォールバック URL。`about:` 等は `openURL` が 115 を返すため使わない。
			// この値が外まで漏れたら `MemoLinkChipInsertion.scheduleMetadataRefresh(in:)` 側で
			// 同じ文字範囲の `.link` 属性から本来の URL を取り戻して再バインドする。
			self.linkURL = URL(string: "scroll:link-chip-invalid")!
			self.customTitle = nil
			self.refreshToken = UUID()
		}
		super.init(data: contentData, ofType: uti)
		let font = UIFont.preferredFont(forTextStyle: .body)
		// この経路（pasteboard 由来 / RTF フォールバックなど）では実コンテナ幅を知り得ないので、
		// 無難な既定値で 1 回描画する。テキストビュー側の `scheduleMetadataRefresh(in:)` で
		// メタデータ取得が走った時点で実コンテナ幅で再描画される。
		applyRendering(maxChipWidth: 200, bodyFont: font, traitCollection: UITraitCollection.current)
	}

	required init?(coder: NSCoder) {
		// まずは coder から URL を直接読み出す（通常経路）。
		// 取れない場合に備えて、コンテンツ復元後に super のデータからも復旧を試みる。
		let codedURLString = coder.decodeObject(of: NSString.self, forKey: Coding.url) as String?
		let codedURL = codedURLString.flatMap { URL(string: $0) }

		let storedTitle = coder.decodeObject(of: NSString.self, forKey: Coding.title) as String?
		let tokStr = coder.decodeObject(of: NSString.self, forKey: Coding.token) as String?
		let tok = tokStr.flatMap { UUID(uuidString: $0) } ?? UUID()

		// Swift の designated initializer 規則により、super.init より先にすべての stored property を埋める。
		// `super.init(coder:)` が内部経路で `init(data:ofType:)` を経由した場合、`linkURL` 等が
		// `scroll:link-chip-invalid` に上書きされてしまう実装が `NSTextAttachment` 側にあり得るため、
		// super 呼び出しの後にもう一度 coder の値で確実に上書きする。
		self.linkURL = codedURL ?? URL(string: "scroll:link-chip-invalid")!
		self.customTitle = (storedTitle?.isEmpty == false) ? storedTitle : nil
		self.refreshToken = tok
		super.init(coder: coder)

		// 防御的: super.init(coder:) で linkURL が踏まれていたら、coder 由来の値で復元する。
		if let codedURL, !Self.isOpenableHTTPURL(self.linkURL) {
			self.linkURL = codedURL
		}
		// それでも取れていない場合は、super が復元した `contents` から再パースして救う。
		if !Self.isOpenableHTTPURL(self.linkURL),
		   let contents,
		   let parsed = Self.decodeAttachmentContents(contents) {
			self.linkURL = parsed.url
			if customTitle == nil, !parsed.title.isEmpty {
				self.customTitle = parsed.title
			}
		}

		// 重要: `layoutW` には「以前レンダリングしたチップ自身の幅」が入っている（コンテナ幅ではない）。
		// 旧実装はこの値を `containerWidth` として再度 0.72 倍してから描画していたため、
		// 復元のたびに `chipW *= 0.72` が積み重なって指数的にチップが縮んでいた。
		// ここでは保存済みの `chipW` をそのまま `maxChipWidth` として使い、ラウンドトリップで縮まないようにする。
		let savedChipW = CGFloat(coder.decodeDouble(forKey: Coding.layoutW))
		let savedChipH = CGFloat(coder.decodeDouble(forKey: Coding.layoutH))
		let font = UIFont.preferredFont(forTextStyle: .body)
		let maxChipW = savedChipW > 0 ? savedChipW : 200
		applyRendering(maxChipWidth: maxChipW, bodyFont: font, traitCollection: UITraitCollection.current)
		// 万一保存値だけが残って画像が無いケースに備えて、bounds は保存値で上書きする（高さも一貫させる）。
		if savedChipH > 0, let img = image {
			let midY = (font.capHeight - img.size.height) / 2
			bounds = CGRect(x: 0, y: midY, width: img.size.width, height: img.size.height)
		}
	}

	/// `contents` に乗せる「URL 改行 + JSON ペイロード」を組み立てる。
	/// 状態（`linkURL` / `customTitle` / `refreshToken`）が変わるタイミングで呼び出して contents を最新に保つ。
	/// `encode(with:)` の中で self を書き換えるとアーカイバの内部状態と競合しうるため、
	/// contents の更新は state mutation 側に集約する。
	private static func makeContentsData(url: URL, customTitle: String?, token: UUID) -> Data {
		var data = (url.absoluteString + "\n").data(using: .utf8) ?? Data()
		let payload = ContentsPayload(urlString: url.absoluteString, title: customTitle ?? "", token: token.uuidString)
		if let jsonData = try? JSONEncoder().encode(payload) {
			data.append(jsonData)
		}
		return data
	}

	override class var supportsSecureCoding: Bool { true }

	override func encode(with coder: NSCoder) {
		// `contents` の中身は state mutation 側で随時更新する（init / applyFetchedTitle）。
		// ここで self.contents を書き換えるとアーカイバの内部状態と競合する可能性があるため、
		// encode 中は self を変更せず、coder への書き込みだけを行う。
		super.encode(with: coder)
		coder.encode(linkURL.absoluteString as NSString, forKey: Coding.url)
		// 取得済みのページタイトルがあるときだけ保存。なければ空文字を入れて旧データとの後方互換を保つ。
		coder.encode((customTitle ?? "") as NSString, forKey: Coding.title)
		coder.encode(refreshToken.uuidString as NSString, forKey: Coding.token)
		coder.encode(Double(bounds.width > 0 ? bounds.width : (image?.size.width ?? 0)), forKey: Coding.layoutW)
		coder.encode(Double(bounds.height > 0 ? bounds.height : (image?.size.height ?? 0)), forKey: Coding.layoutH)
	}

	/// 何らかの経路で `linkURL` が `scroll:link-chip-invalid` 等に踏まれてしまった添付を、
	/// 同じ字位置の `.link` 属性から復旧した URL で再バインドする。タイトル / レンダリングも再生成する。
	/// 呼び出し側（`MemoLinkChipInsertion.scheduleMetadataRefresh`）が `textViewDidChange` を呼ぶ前提なので、
	/// このメソッド自体は dirty 通知を出さない。
	@MainActor
	func rebind(url: URL, in textView: UITextView) {
		linkURL = url
		// 取得済みタイトルがあった場合でも、URL が変わった以上は信用できないのでクリアする。
		customTitle = nil
		contents = Self.makeContentsData(url: url, customTitle: nil, token: refreshToken)

		let font = (textView.typingAttributes[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
		let insetW = textView.textContainerInset.left + textView.textContainerInset.right + textView.textContainer.lineFragmentPadding * 2
		let containerW = max(1, textView.bounds.width - insetW)
		applyRendering(maxChipWidth: containerW * 0.72, bodyFont: font, traitCollection: textView.traitCollection)

		var charRange = NSRange(location: NSNotFound, length: 0)
		textView.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textView.textStorage.length), options: []) { value, range, stop in
			guard (value as AnyObject) === self else { return }
			charRange = range
			stop.pointee = true
		}
		if charRange.location != NSNotFound {
			textView.layoutManager.invalidateLayout(forCharacterRange: charRange, actualCharacterRange: nil)
			textView.layoutManager.invalidateDisplay(forCharacterRange: charRange)
		}
	}

	/// `LPMetadataProvider` 等から取得したページタイトルを反映し、ホスト `UITextView` を持って正しい幅で再描画する。
	/// テキストストレージの dirty 化（→ 自動保存）も呼び出すので、再起動後も取得済みのタイトルが復元される。
	@MainActor
	func applyFetchedTitle(_ title: String, in textView: UITextView) {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		if customTitle == trimmed { return }
		customTitle = trimmed
		// `contents` ペイロードも最新の customTitle を反映するように同期させる
		// （pasteboard / RTF フォールバック経由で `init(data:ofType:)` から復元されたときに
		//   タイトルが取得済みの状態で復元できる）。
		contents = Self.makeContentsData(url: linkURL, customTitle: trimmed, token: refreshToken)

		let font = (textView.typingAttributes[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
		let insetW = textView.textContainerInset.left + textView.textContainerInset.right + textView.textContainer.lineFragmentPadding * 2
		let containerW = max(1, textView.bounds.width - insetW)
		applyRendering(maxChipWidth: containerW * 0.72, bodyFont: font, traitCollection: textView.traitCollection)

		// 添付の表示が変わったので、対応する文字位置のレイアウトと描画を再計算させる。
		var charRange = NSRange(location: NSNotFound, length: 0)
		textView.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textView.textStorage.length), options: []) { value, range, stop in
			guard (value as AnyObject) === self else { return }
			charRange = range
			stop.pointee = true
		}
		if charRange.location != NSNotFound {
			textView.layoutManager.invalidateLayout(forCharacterRange: charRange, actualCharacterRange: nil)
			textView.layoutManager.invalidateDisplay(forCharacterRange: charRange)
		}
		textView.invalidateIntrinsicContentSize()
		// `textViewDidChange` を通じて、上位で行が dirty 化され、RTF / アーカイブが再生成・永続化される。
		textView.delegate?.textViewDidChange?(textView)
	}

	/// `openURL` 用に外部ブラウザで開ける http(s) か。
	static func isOpenableHTTPURL(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return false }
		return true
	}

	private static func decodeAttachmentContents(_ contentData: Data) -> (url: URL, token: UUID, title: String)? {
		if let nl = contentData.firstIndex(of: contentsURLLineDelimiter) {
			let headData = contentData[..<nl]
			let tail = contentData[contentData.index(after: nl)...]
			if let head = String(data: Data(headData), encoding: .utf8),
			   let u = URL(string: head), !head.isEmpty {
				if tail.isEmpty {
					return (u, UUID(), "")
				}
				if let p = try? JSONDecoder().decode(ContentsPayload.self, from: Data(tail)) {
					let tok = UUID(uuidString: p.token) ?? UUID()
					return (u, tok, p.title)
				}
				return (u, UUID(), "")
			}
		}
		if let p = try? JSONDecoder().decode(ContentsPayload.self, from: contentData),
		   let u = URL(string: p.urlString) {
			let tok = UUID(uuidString: p.token) ?? UUID()
			return (u, tok, p.title)
		}
		if let s = String(data: contentData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
		   let u = URL(string: s), u.host != nil {
			return (u, UUID(), "")
		}
		return nil
	}

	/// `maxChipWidth` は **チップ自身の最大幅**。コンテナ幅から導出する場合は呼び出し側で `* 0.72` などを掛ける。
	private func applyRendering(maxChipWidth: CGFloat, bodyFont: UIFont, traitCollection: UITraitCollection) {
		let safeMax = max(40, maxChipWidth)
		let title = displayTitle
		let rendered = Self.renderChip(title: title, bodyFont: bodyFont, maxChipWidth: safeMax, traitCollection: traitCollection)
		image = rendered.image
		let midY = (bodyFont.capHeight - rendered.size.height) / 2
		bounds = CGRect(x: 0, y: midY, width: rendered.size.width, height: rendered.size.height)
		accessibilityLabel = "\(title), link, \(linkURL.absoluteString)"
	}

	static func fallbackTitle(for url: URL) -> String {
		let host = url.host?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? ""
		let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		let label: String
		if host.isEmpty {
			label = url.absoluteString
		} else if path.isEmpty {
			label = host
		} else {
			let parts = path.split(separator: "/").map(String.init)
			if parts.count == 1 {
				label = "\(host)/\(parts[0])"
			} else if let first = parts.first, let last = parts.last {
				// 共有リンクなどはホストだけだと区別しづらいので「先頭セグメント＋ID 先頭」を見せる
				if last.count >= 8, last != first {
					let idPrefix = String(last.prefix(8))
					label = "\(host)/\(first) · \(idPrefix)…"
				} else {
					label = "\(host)/\(first)"
				}
			} else {
				label = "\(host)/\(path)"
			}
		}
		return truncatedDisplayTitle(label)
	}

	/// 表示用に短くする（書記素単位＋単語境界を優先して切り詰め）。
	static func truncatedDisplayTitle(_ raw: String, maxCharacters: Int = 60) -> String {
		let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.isEmpty { return "" }
		if t.count <= maxCharacters { return t }
		let cutEnd = t.index(t.startIndex, offsetBy: maxCharacters - 1)
		let prefixRange = t.startIndex ..< cutEnd
		let prefix = t[prefixRange]
		if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
			let headDist = prefix.distance(from: prefix.startIndex, to: lastSpace)
			if headDist >= max(10, maxCharacters - 12) {
				return String(prefix[..<lastSpace]) + "…"
			}
		}
		return String(prefix) + "…"
	}

	private static func renderChip(title: String, bodyFont: UIFont, maxChipWidth: CGFloat, traitCollection: UITraitCollection) -> (image: UIImage, size: CGSize) {
		let iconCfg = UIImage.SymbolConfiguration(font: bodyFont, scale: .small)
		let linkIcon = UIImage(systemName: "link", withConfiguration: iconCfg)?.withRenderingMode(.alwaysTemplate)
		let titleFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: UIFont.systemFont(ofSize: bodyFont.pointSize * 0.92, weight: .medium))
		let hPad: CGFloat = 8
		let iconSize: CGFloat = ceil(titleFont.lineHeight * 0.85)
		let gap: CGFloat = 5

		let maxTextW = max(40, maxChipWidth - hPad * 2 - iconSize - gap)
		let text = title as NSString
		let attrs: [NSAttributedString.Key: Any] = [
			.font: titleFont,
			.foregroundColor: UIColor.label
		]
		// 単一行に収めたいので height を 1 行分に固定し、`boundingRect` が改行を許さない計算をさせる。
		let singleLineHeight = titleFont.lineHeight + 2
		let rect = text.boundingRect(with: CGSize(width: maxTextW, height: singleLineHeight), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
		let textW = min(maxTextW, ceil(rect.width))
		let chipH = max(titleFont.lineHeight + 6, iconSize + 6)
		let chipW = min(maxChipWidth, hPad + iconSize + gap + textW + hPad)

		let format = UIGraphicsImageRendererFormat(for: traitCollection)
		format.opaque = false
		let renderer = UIGraphicsImageRenderer(size: CGSize(width: chipW, height: chipH), format: format)
		let img = renderer.image { ctx in
			let bg = UIBezierPath(roundedRect: CGRect(origin: .zero, size: CGSize(width: chipW, height: chipH)), cornerRadius: chipH / 2.4)
			UIColor.secondarySystemFill.setFill()
			bg.fill()
			UIColor.separator.withAlphaComponent(0.35).setStroke()
			bg.lineWidth = 1 / max(format.scale, 1)
			bg.stroke()

			let iconY = (chipH - iconSize) / 2
			if let linkIcon {
				let tinted = linkIcon.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
				tinted.draw(in: CGRect(x: hPad, y: iconY, width: iconSize, height: iconSize))
			}

			let textX = hPad + iconSize + gap
			// `lineBreakMode` は paragraph style 経由でしか効かないため、末尾省略は draw 側にも明示する。
			let p = NSMutableParagraphStyle()
			p.lineBreakMode = .byTruncatingTail
			var drawAttrs = attrs
			drawAttrs[.paragraphStyle] = p
			let textRect = CGRect(x: textX, y: (chipH - titleFont.lineHeight) / 2 - 1, width: textW, height: titleFont.lineHeight + 4)
			text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: drawAttrs, context: nil)
		}
		return (img, CGSize(width: chipW, height: chipH))
	}
}

extension MemoLinkChipAttachment {
	/// `UITextItem` / ジェスチャから URL を参照するためのエイリアス。
	var url: URL { linkURL }
}

// MARK: - リンクメタデータ取得 + ディスクキャッシュ

/// `LPMetadataProvider` で取得したページタイトルを URL → タイトルでキャッシュする。
/// - 同じ URL に対する重複 fetch は inFlight `Task` を共有して 1 回に集約する。
/// - 取得結果は `Library/Caches/scroll/link-titles.json` に永続化し、再起動後の初回表示でも fallback ではなく本物のタイトルを使えるようにする。
@MainActor
final class MemoLinkMetadataCache {
	static let shared = MemoLinkMetadataCache()

	/// 取得タイムアウト。LPMetadataProvider は内部で別途タイムアウトを持つが、
	/// ネットワーク不調時にチップ更新が無限に保留されないよう外側でも区切る。
	private let fetchTimeout: TimeInterval = 12

	/// 1 回の起動で同じ URL を何度も叩きにいかないための in-flight タスク。
	private var inFlight: [String: Task<String?, Never>] = [:]
	/// URL 文字列 → 取得済みタイトル。`nil` ではなく欠落で「未取得」を表現する。
	private var titles: [String: String] = [:]
	/// 最後にディスクへ書き出した時刻（こまめな書き出しを避けるためのデバウンス）。
	private var lastPersistAt: Date?
	private let persistMinInterval: TimeInterval = 4.0
	private var persistScheduled = false

	private let storageURL: URL = {
		let fm = FileManager.default
		let base = (fm.urls(for: .cachesDirectory, in: .userDomainMask).first
			?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!)
			.appendingPathComponent("scroll", isDirectory: true)
		try? fm.createDirectory(at: base, withIntermediateDirectories: true)
		return base.appendingPathComponent("link-titles.json")
	}()

	private init() {
		loadFromDisk()
	}

	func cachedTitle(for url: URL) -> String? {
		let key = url.absoluteString
		guard let t = titles[key], !t.isEmpty else { return nil }
		return t
	}

	/// 取得 → キャッシュ → ディスク永続化までを行う。
	/// 失敗（タイムアウト・タイトル空）時は nil を返し、キャッシュには記録しない（次回再試行できるように）。
	func fetchTitle(for url: URL) async -> String? {
		let key = url.absoluteString
		if let cached = titles[key], !cached.isEmpty { return cached }
		if let inflight = inFlight[key] {
			return await inflight.value
		}
		let timeout = fetchTimeout
		let task = Task<String?, Never> { @MainActor in
			defer { self.inFlight.removeValue(forKey: key) }
			let title = await Self.fetchPageTitle(for: url, timeout: timeout)
			guard let title, !title.isEmpty else { return nil }
			self.titles[key] = title
			self.schedulePersist()
			return title
		}
		inFlight[key] = task
		return await task.value
	}

	private nonisolated static func fetchPageTitle(for url: URL, timeout: TimeInterval) async -> String? {
		await withTaskGroup(of: String?.self) { group in
			group.addTask {
				await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
					let provider = LPMetadataProvider()
					provider.timeout = timeout
					provider.startFetchingMetadata(for: url) { metadata, _ in
						let raw = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
						cont.resume(returning: (raw?.isEmpty == false) ? raw : nil)
					}
				}
			}
			group.addTask {
				try? await Task.sleep(nanoseconds: UInt64((timeout + 1) * 1_000_000_000))
				return nil
			}
			let first = await group.next() ?? nil
			group.cancelAll()
			return first ?? nil
		}
	}

	private func loadFromDisk() {
		guard let data = try? Data(contentsOf: storageURL) else { return }
		guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
		titles = decoded
	}

	private func schedulePersist() {
		guard !persistScheduled else { return }
		persistScheduled = true
		// 連続して取得が走る初回起動時に毎回ディスク書き出しが起きないよう、最低間隔だけ間引く。
		let delay = nextPersistDelay()
		Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
			guard let self else { return }
			self.persistScheduled = false
			self.persistNow()
		}
	}

	private func nextPersistDelay() -> TimeInterval {
		guard let last = lastPersistAt else { return 0.5 }
		let elapsed = Date().timeIntervalSince(last)
		return max(0.5, persistMinInterval - elapsed)
	}

	private func persistNow() {
		let snapshot = titles
		let url = storageURL
		Task.detached(priority: .utility) {
			guard let data = try? JSONEncoder().encode(snapshot) else { return }
			try? data.write(to: url, options: .atomic)
		}
		lastPersistAt = Date()
	}
}
