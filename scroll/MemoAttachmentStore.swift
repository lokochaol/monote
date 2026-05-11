//
//  MemoAttachmentStore.swift
//  scroll
//

import CryptoKit
import Foundation

/// 行アーカイブ (`MemoLine.richTextArchive`) から添付の生バイトを切り出して
/// `Documents/memo_blocks/attachments/<sha256-prefix>.<ext>` に保存する
/// コンテンツアドレス指定の共有ストア。
///
/// - 同じ SVG / 画像をどこに何度貼ってもファイル 1 つにまとまる（dedup）。
/// - アーカイブには参照（ハッシュ + 拡張子）だけが乗るので 1 行あたりの
///   `richTextArchive` が劇的に縮み、`MemoLine` を持ち回るときの RAM / COW コストが減る。
/// - `MemoBlockPersistence` の `rootURL` と同じ `memo_blocks/` 配下に置くため、
///   将来 iCloud Drive (Ubiquity Container) へ移行する際もそのまま付いてくる。
///
/// このストアは `NSCoding` の経路（バックグラウンドの persistence flush 等）から
/// 同期で叩かれるため、すべての API は `nonisolated` かつスレッドセーフな範囲に閉じる。
/// プロジェクトの default actor isolation が `MainActor` のため、明示的に `nonisolated` を付ける。
nonisolated enum MemoAttachmentStore {
	/// 拡張子のホワイトリスト（`/` 等の悪い文字を弾く目的を兼ねる）。
	/// 想定しないものが来たら `bin` に落とす。
	private static let allowedExtensions: Set<String> = ["svg", "png", "jpg", "jpeg", "heic", "gif", "webp", "bin"]

	/// `Documents/memo_blocks/attachments/` のフル URL。
	/// 同階層のブロックファイル群と一蓮托生にしたいので、`MemoBlockPersistence` と同じ親フォルダを使う。
	static let directoryURL: URL = {
		let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
		let url = base
			.appendingPathComponent("memo_blocks", isDirectory: true)
			.appendingPathComponent("attachments", isDirectory: true)
		try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}()

	/// 保存先 URL。`hex` には 32 文字（16 バイト）の小文字 16 進を想定。
	static func storedURL(forHashHex hex: String, ext: String) -> URL {
		let cleanedExt = sanitizedExtension(ext)
		return directoryURL.appendingPathComponent("\(hex).\(cleanedExt)")
	}

	/// 与えた `Data` を SHA-256 prefix(16 byte) でハッシュ化し、無ければファイルへ書き出してからハッシュ16進を返す。
	/// 既に同名ファイルが存在する場合は I/O を行わない（dedup）。
	@discardableResult
	static func write(data: Data, ext: String) -> String? {
		guard !data.isEmpty else { return nil }
		let hex = sha256HexPrefix(data)
		let url = storedURL(forHashHex: hex, ext: ext)
		let fm = FileManager.default
		if !fm.fileExists(atPath: url.path) {
			// 親ディレクトリが何らかの事情で消えていることもあり得るので、書き込み直前にも作る。
			try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
			try? data.write(to: url, options: .atomic)
		}
		return hex
	}

	/// `hex` + `ext` から `Data` を読み戻す。存在しない／読めないなら `nil`。
	static func read(hashHex: String, ext: String) -> Data? {
		let url = storedURL(forHashHex: hashHex, ext: sanitizedExtension(ext))
		return try? Data(contentsOf: url)
	}

	/// 与えた `Data` のハッシュ 16 進文字列を計算する。
	/// `write(data:ext:)` と一致する規則で算出するので、参照集合の構築に再利用できる。
	static func hashHexFor(data: Data) -> String {
		sha256HexPrefix(data)
	}

	/// `NSTextAttachment.fileType`（UTI 文字列）から保存用の拡張子を推測する。
	/// 未知の場合は `bin`。`/` を含むなど怪しい場合も `bin` に落とす。
	static func preferredExtension(forFileType fileType: String?) -> String {
		guard let raw = fileType?.lowercased(), !raw.isEmpty else { return "bin" }
		// 代表的な UTI のマッピング。網羅性より「拡張子で何の画像か分かる」ことを優先。
		switch raw {
		case "public.svg-image", "org.w3.scalable-vector-graphics-xml":
			return "svg"
		case "public.png":
			return "png"
		case "public.jpeg":
			return "jpg"
		case "public.heic":
			return "heic"
		case "com.compuserve.gif":
			return "gif"
		case "org.webmproject.webp", "public.webp":
			return "webp"
		default:
			break
		}
		// 末尾断片から推定（"public.png" 以外でも "png" を含む変種に保険的に効く）。
		for ext in allowedExtensions where raw.hasSuffix(ext) {
			return ext
		}
		return "bin"
	}

	// MARK: - Private

	private static func sanitizedExtension(_ ext: String) -> String {
		let lower = ext.lowercased()
		return allowedExtensions.contains(lower) ? lower : "bin"
	}

	/// SHA-256 の先頭 16 バイトを 32 文字の 16 進文字列にして返す。
	/// 衝突確率は実用上ゼロで、ファイル名が短くて済むのでこのプレフィックス長を採用。
	private static func sha256HexPrefix(_ data: Data) -> String {
		let digest = SHA256.hash(data: data)
		var hex = ""
		hex.reserveCapacity(32)
		for byte in digest.prefix(16) {
			hex.append(String(format: "%02x", byte))
		}
		return hex
	}
}
