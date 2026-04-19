//
//  MemoLinkChip.swift
//  scroll
//

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
		var title: String
		var token: String
	}

	/// `contents` 先頭に「絶対 URL + 改行」を載せ、JSON 部分が欠損しても URL だけ復元できるようにする。
	private static let contentsURLLineDelimiter = "\n".utf8.first!

	private(set) var linkURL: URL
	private(set) var displayTitle: String
	/// メタデータ取得完了後に同一添付を特定する。
	let refreshToken: UUID

	/// 表示は常に `linkURL` 由来の短いラベルのみ。開く URL は `linkURL`（と `.link` フォールバック）。
	init(url: URL, bodyFont: UIFont, containerWidth: CGFloat, traitCollection: UITraitCollection) {
		let truncated = Self.fallbackTitle(for: url)
		let token = UUID()
		let payload = ContentsPayload(urlString: url.absoluteString, title: truncated, token: token.uuidString)
		let jsonData = (try? JSONEncoder().encode(payload)) ?? Data()
		var data = (url.absoluteString + "\n").data(using: .utf8) ?? Data()
		data.append(jsonData)
		self.linkURL = url
		self.displayTitle = truncated
		self.refreshToken = token
		super.init(data: data, ofType: Self.contentsUTI)
		applyRendering(bodyFont: bodyFont, containerWidth: containerWidth, traitCollection: traitCollection)
	}

	override init(data contentData: Data?, ofType uti: String?) {
		if let contentData, !contentData.isEmpty, let parsed = Self.decodeAttachmentContents(contentData) {
			self.linkURL = parsed.url
			self.displayTitle = Self.fallbackTitle(for: parsed.url)
			self.refreshToken = parsed.token
		} else {
			// デコード不能な添付のフォールバック。`about:` 等は `openURL` が 115 を返すため使わない。
			self.linkURL = URL(string: "scroll:link-chip-invalid")!
			self.displayTitle = ""
			self.refreshToken = UUID()
		}
		super.init(data: contentData, ofType: uti)
		let font = UIFont.preferredFont(forTextStyle: .body)
		applyRendering(bodyFont: font, containerWidth: 280, traitCollection: UITraitCollection.current)
	}

	required init?(coder: NSCoder) {
		guard let urlString = coder.decodeObject(of: NSString.self, forKey: Coding.url) as String?,
		      let u = URL(string: urlString),
		      coder.decodeObject(of: NSString.self, forKey: Coding.title) != nil
		else {
			return nil
		}
		let tokStr = coder.decodeObject(of: NSString.self, forKey: Coding.token) as String?
		let tok = tokStr.flatMap { UUID(uuidString: $0) } ?? UUID()
		self.linkURL = u
		self.displayTitle = Self.fallbackTitle(for: u)
		self.refreshToken = tok
		super.init(coder: coder)
		let w = CGFloat(coder.decodeDouble(forKey: Coding.layoutW))
		let h = CGFloat(coder.decodeDouble(forKey: Coding.layoutH))
		let font = UIFont.preferredFont(forTextStyle: .body)
		let cw = w > 0 ? w : 280
		setDisplayTitle(Self.fallbackTitle(for: u), bodyFont: font, containerWidth: cw, traitCollection: UITraitCollection.current)
		if h > 0, let img = image {
			let midY = (font.capHeight - img.size.height) / 2
			bounds = CGRect(x: 0, y: midY, width: img.size.width, height: img.size.height)
		}
	}

	override class var supportsSecureCoding: Bool { true }

	override func encode(with coder: NSCoder) {
		super.encode(with: coder)
		coder.encode(linkURL.absoluteString as NSString, forKey: Coding.url)
		coder.encode(Self.fallbackTitle(for: linkURL) as NSString, forKey: Coding.title)
		coder.encode(refreshToken.uuidString as NSString, forKey: Coding.token)
		coder.encode(Double(bounds.width > 0 ? bounds.width : (image?.size.width ?? 0)), forKey: Coding.layoutW)
		coder.encode(Double(bounds.height > 0 ? bounds.height : (image?.size.height ?? 0)), forKey: Coding.layoutH)
	}

	func setDisplayTitle(_ title: String, bodyFont: UIFont, containerWidth: CGFloat, traitCollection: UITraitCollection = .current) {
		displayTitle = Self.truncatedDisplayTitle(title)
		applyRendering(bodyFont: bodyFont, containerWidth: containerWidth, traitCollection: traitCollection)
	}

	/// `openURL` 用に外部ブラウザで開ける http(s) か。
	static func isOpenableHTTPURL(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return false }
		return true
	}

	private static func decodeAttachmentContents(_ contentData: Data) -> (url: URL, token: UUID)? {
		if let nl = contentData.firstIndex(of: contentsURLLineDelimiter) {
			let headData = contentData[..<nl]
			let tail = contentData[contentData.index(after: nl)...]
			if let head = String(data: Data(headData), encoding: .utf8),
			   let u = URL(string: head), !head.isEmpty {
				if tail.isEmpty {
					return (u, UUID())
				}
				if let p = try? JSONDecoder().decode(ContentsPayload.self, from: Data(tail)) {
					let tok = UUID(uuidString: p.token) ?? UUID()
					return (u, tok)
				}
				return (u, UUID())
			}
		}
		if let p = try? JSONDecoder().decode(ContentsPayload.self, from: contentData),
		   let u = URL(string: p.urlString) {
			let tok = UUID(uuidString: p.token) ?? UUID()
			return (u, tok)
		}
		if let s = String(data: contentData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
		   let u = URL(string: s), u.host != nil {
			return (u, UUID())
		}
		return nil
	}

	private func applyRendering(bodyFont: UIFont, containerWidth: CGFloat, traitCollection: UITraitCollection) {
		let rendered = Self.renderChip(title: displayTitle, bodyFont: bodyFont, maxChipWidth: containerWidth * 0.72, traitCollection: traitCollection)
		image = rendered.image
		let midY = (bodyFont.capHeight - rendered.size.height) / 2
		bounds = CGRect(x: 0, y: midY, width: rendered.size.width, height: rendered.size.height)
		accessibilityLabel = "\(displayTitle), link, \(linkURL.absoluteString)"
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
	static func truncatedDisplayTitle(_ raw: String, maxCharacters: Int = 30) -> String {
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
		let rect = text.boundingRect(with: CGSize(width: maxTextW, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
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
			let textRect = CGRect(x: textX, y: (chipH - titleFont.lineHeight) / 2 - 1, width: textW, height: titleFont.lineHeight + 4)
			text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
		}
		return (img, CGSize(width: chipW, height: chipH))
	}
}

extension MemoLinkChipAttachment {
	/// `UITextItem` / ジェスチャから URL を参照するためのエイリアス。
	var url: URL { linkURL }
}
