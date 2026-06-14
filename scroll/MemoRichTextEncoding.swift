//
//  MemoRichTextEncoding.swift
//  scroll
//

import UIKit

enum MemoRichTextEncoding {
	static func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
		let font = UIFont.preferredFont(forTextStyle: .body)
		let paragraph = NSMutableParagraphStyle()
		paragraph.lineBreakMode = .byCharWrapping
		return [
			.font: font,
			.foregroundColor: UIColor.label,
			.paragraphStyle: paragraph
		]
	}

	/// 復元はアーカイブ優先（画像付きの再現性）、次に RTF、最後にプレーン。
	static func attributedString(rtfData: Data?, archiveData: Data?, plainFallback: String) -> NSAttributedString {
		if let data = archiveData, !data.isEmpty,
		   let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data),
		   decoded.length > 0 {
			return decoded
		}
		if let data = rtfData, !data.isEmpty,
		   let decoded = try? NSAttributedString(
		   	data: data,
		   	options: [.documentType: NSAttributedString.DocumentType.rtf],
		   	documentAttributes: nil
		   ) {
			if decoded.length == 0, !plainFallback.isEmpty {
				return NSAttributedString(string: plainFallback, attributes: defaultTypingAttributes())
			}
			return decoded
		}
		return NSAttributedString(string: plainFallback, attributes: defaultTypingAttributes())
	}

	nonisolated static func rtfData(from attributed: NSAttributedString) -> Data? {
		guard attributed.length > 0 else { return nil }
		let range = NSRange(location: 0, length: attributed.length)
		return try? attributed.data(
			from: range,
			documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
		)
	}

	nonisolated static func archivedAttributedData(from attributed: NSAttributedString) -> Data? {
		guard attributed.length > 0 else { return nil }
		return try? NSKeyedArchiver.archivedData(withRootObject: attributed, requiringSecureCoding: true)
	}

	nonisolated static func containsTextAttachment(_ attributed: NSAttributedString) -> Bool {
		var found = false
		attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, stop in
			if value is NSTextAttachment {
				found = true
				stop.pointee = true
			}
		}
		return found
	}

	/// RTF と必要に応じてアーカイブを生成。添付画像がある行はアーカイブも保存する。
	nonisolated static func persistPayload(from attributed: NSAttributedString) -> (rtf: Data?, archive: Data?) {
		guard attributed.length > 0 else { return (nil, nil) }
		let rtf = rtfData(from: attributed)
		let hasAttachment = containsTextAttachment(attributed)
		let archive: Data? = {
			if hasAttachment || rtf == nil {
				return archivedAttributedData(from: attributed)
			}
			return nil
		}()
		return (rtf, archive)
	}

	static func assignPersistence(_ attributed: NSAttributedString, to line: inout MemoLine) {
		let payload = persistPayload(from: attributed)
		line.richTextRTF = payload.rtf
		line.richTextArchive = payload.archive
	}

	/// `\n` / `\r\n` で分割（属性を行ごとに保持）
	static func attributedSplitByNewlines(_ attr: NSAttributedString) -> [NSAttributedString] {
		let ns = attr.string as NSString
		let fullLen = ns.length
		var segments: [NSAttributedString] = []
		var start = 0
		var i = 0
		while i < fullLen {
			let c = ns.character(at: i)
			if c == 10 || c == 13 {
				let range = NSRange(location: start, length: i - start)
				segments.append(attr.attributedSubstring(from: range))
				if c == 13, i + 1 < fullLen, ns.character(at: i + 1) == 10 {
					i += 2
				} else {
					i += 1
				}
				start = i
				continue
			}
			i += 1
		}
		segments.append(attr.attributedSubstring(from: NSRange(location: start, length: fullLen - start)))
		return segments
	}
}

extension MemoLine {
	func attributedContent() -> NSAttributedString {
		MemoRichTextEncoding.attributedString(rtfData: richTextRTF, archiveData: richTextArchive, plainFallback: text)
	}
}
