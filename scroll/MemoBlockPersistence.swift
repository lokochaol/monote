//
//  MemoBlockPersistence.swift
//  scroll
//

import Foundation
import CoreGraphics
import UIKit

// MARK: - ブロックファイル envelope（マジック付き圧縮ラッパ）

/// `block_*.json` のファイル形式を将来拡張できるようにする最小エンベロープ。
///
/// レイアウト:
/// ```
/// [4 bytes magic: 'M','B','L','K'][1 byte version][1 byte algorithm][payload...]
/// ```
/// - `algorithm = 0`: `payload` は無圧縮 JSON。
/// - `algorithm = 1`: `payload` は LZFSE で圧縮された JSON（`Foundation.NSData.compressed(using:)`）。
///
/// マジックを認識できないデータ（旧バージョンのプレーン JSON）はそのまま JSON とみなして読む。
/// これにより既存ユーザのブロックファイルは触らずに段階移行できる。
///
/// プロジェクトの default actor isolation が `MainActor` のため、`Task.detached` 内（nonisolated 文脈）
/// から触れるよう明示的に `nonisolated` を付ける。
nonisolated enum MemoBlockEnvelope {
	private static let magic: [UInt8] = [0x4D, 0x42, 0x4C, 0x4B] // "MBLK"
	private static let currentVersion: UInt8 = 1
	private static let algorithmRaw: UInt8 = 0
	private static let algorithmLZFSE: UInt8 = 1
	private static let headerSize = 6

	/// JSON バイト列を LZFSE で圧縮し、マジック付きでラップして返す。
	/// 圧縮に失敗した場合は raw（algorithm=0）でラップする。
	static func wrap(json: Data) -> Data {
		var out = Data()
		out.reserveCapacity(headerSize + json.count)
		out.append(contentsOf: magic)
		out.append(currentVersion)
		if let compressed = try? (json as NSData).compressed(using: .lzfse) as Data,
		   compressed.count < json.count {
			out.append(algorithmLZFSE)
			out.append(compressed)
		} else {
			// 既に十分小さいか圧縮失敗。無駄な解凍コストを払わせないため raw で書く。
			out.append(algorithmRaw)
			out.append(json)
		}
		return out
	}

	/// ファイルから読み出した生バイト列を JSON バイト列へ戻す。
	/// マジックがあればアルゴリズムに応じて解凍、無ければ旧プレーン JSON とみなす。
	static func unwrap(_ data: Data) -> Data? {
		guard data.count >= headerSize,
		      data[data.startIndex] == magic[0],
		      data[data.startIndex + 1] == magic[1],
		      data[data.startIndex + 2] == magic[2],
		      data[data.startIndex + 3] == magic[3]
		else {
			// 旧フォーマット（プレーン JSON）。空ファイルもここに来るので最低限の妥当性だけ見る。
			return data.isEmpty ? nil : data
		}
		let algorithm = data[data.startIndex + 5]
		let payload = data.subdata(in: (data.startIndex + headerSize) ..< data.endIndex)
		switch algorithm {
		case algorithmRaw:
			return payload
		case algorithmLZFSE:
			return (try? (payload as NSData).decompressed(using: .lzfse)) as Data?
		default:
			return nil
		}
	}
}

/// 1ブロックあたりの行数は画面高さ×10 / 行のおおよその高さから算出（最低限の下限あり）
enum MemoBlockConfig {
	static let minLinesPerBlock = 24
	static let approximateLineHeight: CGFloat = 26
	static let scrollHeightsPerBlock: CGFloat = 10

	static func linesPerBlock(screenHeight: CGFloat) -> Int {
		let raw = Int((screenHeight * scrollHeightsPerBlock) / approximateLineHeight)
		return max(minLinesPerBlock, raw)
	}
}

// `Task.detached` 内で `JSONEncoder.encode` / `JSONDecoder.decode` を呼ぶため、
// Codable / Sendable の conformance が MainActor に推論されないよう `nonisolated` を明示する。
fileprivate nonisolated struct BlockFile: Codable, Sendable {
	var lines: [MemoLine]
}

private nonisolated struct IndexFile: Codable, Sendable {
	var linesPerBlock: Int
	var totalLines: Int
}

/// メモをブロックファイルに分割して永続化する
@MainActor
final class MemoBlockPersistence {
	/// 現在の保存先ルート。端末ローカル `Documents/memo_blocks/`。
	private(set) var rootURL: URL
	/// `rootURL` と同期する `index.json` の URL。
	private(set) var indexURL: URL

	init(fileManager: FileManager = .default) {
		let local = MemoStorageRoot.localMemoBlocksURL
		try? fileManager.createDirectory(at: local, withIntermediateDirectories: true)
		rootURL = local
		indexURL = local.appendingPathComponent("index.json")
	}

	/// アンドゥ履歴を保存するファイルの URL。
	/// 本文のブロックファイルと同じディレクトリに相乗りする。
	var undoStackURL: URL {
		rootURL.appendingPathComponent("undo_stack.json")
	}

	// MARK: - 旧データの新フォーマット移行

	/// マイグレーション完了マーカー。次回以降の起動で重複して走らせないために、
	/// 移行が一通り終わったタイミングでこのファイルを置く。
	/// 名前にバージョンを入れているので、将来別の片方向移行を足しても並存できる。
	private var migrationFlagURL: URL {
		rootURL.appendingPathComponent("migration_v1_externalize_lzfse.done")
	}

	/// 既存の `block_*.json` を「外部添付ストア + LZFSE 圧縮」の新フォーマットで一気に書き直す。
	/// - 旧フォーマット (プレーン JSON + アーカイブ内に SVG/画像のバイトを埋め込み) のままだと、
	///   ユーザがそのブロックを編集するまで容量が縮まない。マイグレーションで全部一度通せば、
	///   未編集ブロックも添付バイトが外部ストアに退避され、ファイルサイズが大きく落ちる。
	/// - 完了マーカーを置いて二重実行を避ける。途中で kill されても、次回起動時に未処理ブロックから続行する。
	/// - すべての I/O・JSON / アーカイブ処理は detached で行い、メインスレッドはブロックしない。
	func migrateBlocksToCompressedFormatIfNeeded() async {
		let rootURL = self.rootURL
		let flagURL = self.migrationFlagURL
		let fm = FileManager.default
		if fm.fileExists(atPath: flagURL.path) { return }

		await Task.detached(priority: .utility) {
			guard let names = try? fm.contentsOfDirectory(atPath: rootURL.path) else { return }
			let blockNames = names.filter { $0.hasPrefix("block_") && $0.hasSuffix(".json") }
			guard !blockNames.isEmpty else {
				// データ自体が無いなら次回以降スキップさせるためのマーカーだけ置く。
				try? Data().write(to: flagURL, options: .atomic)
				return
			}
			let encoder = JSONEncoder()
			let decoder = JSONDecoder()
			for name in blockNames {
				let url = rootURL.appendingPathComponent(name)
				guard let raw = try? Data(contentsOf: url),
				      let json = MemoBlockEnvelope.unwrap(raw),
				      let file = try? decoder.decode(BlockFile.self, from: json)
				else { continue }
				let migrated = file.lines.map(MemoBlockPersistence.migratedLineExternalizingAttachments)
				let migratedFile = BlockFile(lines: migrated)
				guard let newJSON = try? encoder.encode(migratedFile) else { continue }
				let wrapped = MemoBlockEnvelope.wrap(json: newJSON)
				// 既に新形式 + 添付外出し済みでも `wrap` 自身がべき等なので、安全に書き戻せる。
				try? wrapped.write(to: url, options: .atomic)
			}
			try? Data().write(to: flagURL, options: .atomic)
		}.value
	}

	/// 行 1 行ぶんの `richTextArchive` を読み直して再アーカイブする。
	/// 再アーカイブ中に `MemoSVGAttachment` / `MemoPreviewImageAttachment` の `encode(with:)` が走り、
	/// 新フォーマットで添付バイトが `MemoAttachmentStore` 配下へ退避され、アーカイブにはハッシュ参照だけが残る。
	/// - 失敗系（unarchive 不能・新アーカイブのほうが大きい等）はすべて元の行を返す。データ損失を絶対に出さない。
	private nonisolated static func migratedLineExternalizingAttachments(_ line: MemoLine) -> MemoLine {
		guard let archive = line.richTextArchive, !archive.isEmpty else { return line }
		guard let attr = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: archive),
		      attr.length > 0
		else { return line }
		guard let newArchive = try? NSKeyedArchiver.archivedData(withRootObject: attr, requiringSecureCoding: true),
		      !newArchive.isEmpty
		else { return line }
		// 添付を持たない行（フォントだけのリッチ情報など）は再アーカイブしても縮まないか、
		// むしろ NSKeyedArchiver の側のメタが微増するケースもある。確実に得をするときだけ差し替える。
		guard newArchive.count < archive.count else { return line }
		var updated = line
		updated.richTextArchive = newArchive
		return updated
	}

	func loadIndex() -> (linesPerBlock: Int, totalLines: Int) {
		guard let data = try? Data(contentsOf: indexURL),
		      let idx = try? JSONDecoder().decode(IndexFile.self, from: data)
		else {
			return (0, 0)
		}
		return (idx.linesPerBlock, idx.totalLines)
	}

	private func saveIndex(linesPerBlock: Int, totalLines: Int) {
		let idx = IndexFile(linesPerBlock: linesPerBlock, totalLines: totalLines)
		if let data = try? JSONEncoder().encode(idx) {
			try? data.write(to: indexURL, options: .atomic)
		}
	}

	private func blockURL(_ index: Int) -> URL {
		rootURL.appendingPathComponent("block_\(index).json")
	}

	func loadBlock(_ index: Int) -> [MemoLine] {
		let url = blockURL(index)
		guard let data = try? Data(contentsOf: url) else { return [] }
		return decodeBlockData(data)
	}

	/// 無限スクロール用: 生データ読み込みをバックグラウンドに逃がし、デコードは MainActor で行う
	func loadBlockAsync(_ index: Int) async -> [MemoLine] {
		let url = blockURL(index)
		let data = await Task.detached(priority: .utility) {
			try? Data(contentsOf: url)
		}.value
		guard let data else { return [] }
		return decodeBlockData(data)
	}

	private func decodeBlockData(_ data: Data) -> [MemoLine] {
		guard let json = MemoBlockEnvelope.unwrap(data) else { return [] }
		guard let file = try? JSONDecoder().decode(BlockFile.self, from: json) else { return [] }
		return file.lines
	}

	func saveBlock(_ index: Int, lines: [MemoLine]) {
		let file = BlockFile(lines: lines)
		if let json = try? JSONEncoder().encode(file) {
			let data = MemoBlockEnvelope.wrap(json: json)
			try? data.write(to: blockURL(index), options: .atomic)
		}
	}

	/// 全行をブロックに分割して保存（起動時またはインデックス不整合時）
	func saveAllLines(_ all: [MemoLine], linesPerBlock: Int) {
		guard linesPerBlock > 0 else { return }
		let blockCount = max(1, (all.count + linesPerBlock - 1) / linesPerBlock)
		for b in 0 ..< blockCount {
			let start = b * linesPerBlock
			let end = min(start + linesPerBlock, all.count)
			let slice = Array(all[start ..< end])
			saveBlock(b, lines: slice)
		}
		// 余分な古いブロックファイルを削除
		let fm = FileManager.default
		if let names = try? fm.contentsOfDirectory(atPath: rootURL.path) {
			for name in names where name.hasPrefix("block_") && name.hasSuffix(".json") {
				let numStr = name.dropFirst(6).dropLast(5)
				if let n = Int(numStr), n >= blockCount {
					try? fm.removeItem(at: blockURL(n))
				}
			}
		}
		saveIndex(linesPerBlock: linesPerBlock, totalLines: all.count)
	}

	/// UI を止めないため、エンコード＆ファイル書き込みをバックグラウンドで行う版。
	/// 呼び出し側は完了を await してから index を読み直すこと。
	/// JSON のエンコードは MainActor、ファイル I/O のみ `Task.detached`。
	func saveAllLinesAsync(_ all: [MemoLine], linesPerBlock: Int) async {
		guard linesPerBlock > 0 else { return }
		let rootURL = self.rootURL
		let indexURL = self.indexURL
		let blockCount = max(1, (all.count + linesPerBlock - 1) / linesPerBlock)

		var blockPayloads: [Int: Data] = [:]
		for b in 0 ..< blockCount {
			let start = b * linesPerBlock
			let end = min(start + linesPerBlock, all.count)
			let slice = Array(all[start ..< end])
			let file = BlockFile(lines: slice)
			if let json = try? JSONEncoder().encode(file) {
				blockPayloads[b] = MemoBlockEnvelope.wrap(json: json)
			}
		}
		let idx = IndexFile(linesPerBlock: linesPerBlock, totalLines: all.count)
		let indexPayload = try? JSONEncoder().encode(idx)

		await Task.detached(priority: .utility) {
			func blockURL(_ index: Int) -> URL {
				rootURL.appendingPathComponent("block_\(index).json")
			}

			for b in 0 ..< blockCount {
				if let data = blockPayloads[b] {
					try? data.write(to: blockURL(b), options: .atomic)
				}
			}

			let fm = FileManager.default
			if let names = try? fm.contentsOfDirectory(atPath: rootURL.path) {
				for name in names where name.hasPrefix("block_") && name.hasSuffix(".json") {
					let numStr = name.dropFirst(6).dropLast(5)
					if let n = Int(numStr), n >= blockCount {
						try? fm.removeItem(at: blockURL(n))
					}
				}
			}

			if let indexPayload {
				try? indexPayload.write(to: indexURL, options: .atomic)
			}
		}.value
	}

	func loadAllLines(linesPerBlock: Int, totalFromIndex: Int) -> [MemoLine] {
		guard linesPerBlock > 0, totalFromIndex > 0 else { return [] }
		let blockCount = (totalFromIndex + linesPerBlock - 1) / linesPerBlock
		var out: [MemoLine] = []
		out.reserveCapacity(totalFromIndex)
		for b in 0 ..< blockCount {
			out.append(contentsOf: loadBlock(b))
		}
		return out
	}

	/// `startGlobalIndex` から末尾までの行をロードする（全文は読まない）。
	/// - Important: `linesPerBlock` と `totalLines` は `index.json` と整合している前提。
	func loadLinesFromGlobalIndexToEnd(startGlobalIndex: Int, linesPerBlock: Int, totalLines: Int) -> [MemoLine] {
		guard linesPerBlock > 0, totalLines > 0 else { return [] }
		guard startGlobalIndex >= 0, startGlobalIndex < totalLines else { return [] }

		let startBlock = startGlobalIndex / linesPerBlock
		let startOff = startGlobalIndex % linesPerBlock
		let blockCount = (totalLines + linesPerBlock - 1) / linesPerBlock

		var out: [MemoLine] = []
		out.reserveCapacity(max(0, totalLines - startGlobalIndex))

		for b in startBlock ..< blockCount {
			var lines = loadBlock(b)
			if b == startBlock, startOff > 0 {
				if startOff < lines.count {
					lines.removeFirst(startOff)
				} else {
					lines = []
				}
			}
			if lines.isEmpty { continue }
			out.append(contentsOf: lines)
			if startGlobalIndex + out.count >= totalLines { break }
		}

		let allowed = max(0, totalLines - startGlobalIndex)
		if out.count > allowed {
			out.removeLast(out.count - allowed)
		}
		return out
	}

	/// `startBlock` 以前のブロックは触らず、`startBlock` 以降を `linesFromStartBlock` で上書きして index を更新する。
	/// - Important: `linesFromStartBlock` はグローバル行 `startBlock * linesPerBlock` からの連続配列であること。
	/// - Note: JSON エンコード／書き込みをまとめて detached に逃がすため、メインスレッドでの所要時間は
	///   主に `linesFromStartBlock`（値型の COW 配列）を detached へ受け渡すだけで済む。
	func saveBlocksFromBlockIndexAsync(
		startBlock: Int,
		linesFromStartBlock: [MemoLine],
		linesPerBlock: Int,
		totalLines: Int
	) async {
		guard linesPerBlock > 0 else { return }
		guard startBlock >= 0 else { return }
		let rootURL = self.rootURL
		let indexURL = self.indexURL
		let normalizedTotal = max(0, totalLines)
		let blockCount = max(1, (normalizedTotal + linesPerBlock - 1) / linesPerBlock)

		await Task.detached(priority: .utility) {
			func blockURL(_ index: Int) -> URL {
				rootURL.appendingPathComponent("block_\(index).json")
			}

			let encoder = JSONEncoder()
			if startBlock < blockCount {
				for b in startBlock ..< blockCount {
					let startInTail = (b - startBlock) * linesPerBlock
					let file: BlockFile
					if startInTail >= linesFromStartBlock.count {
						file = BlockFile(lines: [])
					} else {
						let endInTail = min(startInTail + linesPerBlock, linesFromStartBlock.count)
						file = BlockFile(lines: Array(linesFromStartBlock[startInTail ..< endInTail]))
					}
					guard let json = try? encoder.encode(file) else { continue }
					let data = MemoBlockEnvelope.wrap(json: json)
					try? data.write(to: blockURL(b), options: .atomic)
				}
			}

			let fm = FileManager.default
			if let names = try? fm.contentsOfDirectory(atPath: rootURL.path) {
				for name in names where name.hasPrefix("block_") && name.hasSuffix(".json") {
					let numStr = name.dropFirst(6).dropLast(5)
					if let n = Int(numStr), n >= blockCount {
						try? fm.removeItem(at: blockURL(n))
					}
				}
			}

			let idx = IndexFile(linesPerBlock: linesPerBlock, totalLines: normalizedTotal)
			if let indexPayload = try? encoder.encode(idx) {
				try? indexPayload.write(to: indexURL, options: .atomic)
			}
		}.value
	}

	/// `startBlock` 以降の **`linesFromStartBlock` に含まれる範囲だけ** をディスクに書き出す版。
	/// - 重要: この関数は「サフィックス（`linesFromStartBlock` で覆われない既存ブロック）」を触らない。
	///   行数が変わっていない純粋な入力中は、サフィックスのバイト列と `index.json` の内容はすでに正しいので、
	///   それらを読み込んで書き戻す無駄な I/O とメモリ使用を省ける。
	/// - Precondition: 呼び出し側で「行数（`totalLines`）に変化がない」ことを確認してから呼ぶこと。
	///   サイズが変わっている状態で呼ぶとサフィックスが古い配置のまま残って整合が崩れる。
	func saveVisibleBlocksOnlyAsync(
		startBlock: Int,
		linesFromStartBlock: [MemoLine],
		linesPerBlock: Int
	) async {
		guard linesPerBlock > 0, startBlock >= 0 else { return }
		let rootURL = self.rootURL
		// `linesFromStartBlock` が占めるブロック範囲だけを書き出す。
		let blockSpan = max(1, (linesFromStartBlock.count + linesPerBlock - 1) / linesPerBlock)
		let endBlockExclusive = startBlock + blockSpan

		await Task.detached(priority: .utility) {
			func blockURL(_ index: Int) -> URL {
				rootURL.appendingPathComponent("block_\(index).json")
			}
			let encoder = JSONEncoder()
			for b in startBlock ..< endBlockExclusive {
				let startInTail = (b - startBlock) * linesPerBlock
				guard startInTail < linesFromStartBlock.count else { continue }
				let endInTail = min(startInTail + linesPerBlock, linesFromStartBlock.count)
				let file = BlockFile(lines: Array(linesFromStartBlock[startInTail ..< endInTail]))
				guard let json = try? encoder.encode(file) else { continue }
				let data = MemoBlockEnvelope.wrap(json: json)
				try? data.write(to: blockURL(b), options: .atomic)
			}
		}.value
	}

	/// `loadLinesFromGlobalIndexToEnd` のディスク I/O 部分を detached に逃がした版。
	/// メインスレッドでは Data の受け渡しだけに留め、複数ブロック分の JSON デコードもバックグラウンドで行う。
	func loadLinesFromGlobalIndexToEndAsync(startGlobalIndex: Int, linesPerBlock: Int, totalLines: Int) async -> [MemoLine] {
		guard linesPerBlock > 0, totalLines > 0 else { return [] }
		guard startGlobalIndex >= 0, startGlobalIndex < totalLines else { return [] }
		let rootURL = self.rootURL
		return await Task.detached(priority: .utility) { () -> [MemoLine] in
			func blockURL(_ index: Int) -> URL {
				rootURL.appendingPathComponent("block_\(index).json")
			}

			let startBlock = startGlobalIndex / linesPerBlock
			let startOff = startGlobalIndex % linesPerBlock
			let blockCount = (totalLines + linesPerBlock - 1) / linesPerBlock
			let decoder = JSONDecoder()
			var out: [MemoLine] = []
			out.reserveCapacity(max(0, totalLines - startGlobalIndex))
			for b in startBlock ..< blockCount {
				guard let raw = try? Data(contentsOf: blockURL(b)) else { continue }
				guard let json = MemoBlockEnvelope.unwrap(raw) else { continue }
				guard var lines = (try? decoder.decode(BlockFile.self, from: json))?.lines else { continue }
				if b == startBlock, startOff > 0 {
					if startOff < lines.count {
						lines.removeFirst(startOff)
					} else {
						lines = []
					}
				}
				if lines.isEmpty { continue }
				out.append(contentsOf: lines)
				if startGlobalIndex + out.count >= totalLines { break }
			}
			let allowed = max(0, totalLines - startGlobalIndex)
			if out.count > allowed {
				out.removeLast(out.count - allowed)
			}
			return out
		}.value
	}

	/// `loadIndex` を detached で読む版（メイン同期の JSON デコードを避ける）。
	func loadIndexAsync() async -> (linesPerBlock: Int, totalLines: Int) {
		let indexURL = self.indexURL
		return await Task.detached(priority: .utility) { () -> (Int, Int) in
			guard let data = try? Data(contentsOf: indexURL),
			      let idx = try? JSONDecoder().decode(IndexFile.self, from: data)
			else { return (0, 0) }
			return (idx.linesPerBlock, idx.totalLines)
		}.value
	}

	/// 検索用：ディスク上の全ブロックを順に読み、マッチした行のグローバルインデックスを返す
	func searchKeyword(
		_ keyword: String,
		linesPerBlock: Int,
		totalLines: Int,
		options: String.CompareOptions = []
	) -> [Int] {
		guard !keyword.isEmpty, linesPerBlock > 0, totalLines > 0 else { return [] }
		var results: [Int] = []
		var globalIndex = 0
		let blockCount = (totalLines + linesPerBlock - 1) / linesPerBlock
		for b in 0 ..< blockCount {
			let lines = loadBlock(b)
			for line in lines {
				if line.text.range(of: keyword, options: options) != nil {
					results.append(globalIndex)
				}
				globalIndex += 1
				if globalIndex >= totalLines { return results }
			}
		}
		return results
	}

	func lineTextAtGlobalIndex(_ globalIndex: Int, linesPerBlock: Int, totalLines: Int) -> String {
		guard globalIndex >= 0, globalIndex < totalLines, linesPerBlock > 0 else { return "" }
		let b = globalIndex / linesPerBlock
		let off = globalIndex % linesPerBlock
		let block = loadBlock(b)
		guard off < block.count else { return "" }
		return block[off].text
	}

	/// キーワードにヒットした行ごとに前行・当行・翌行のテキストを返す（一覧用）
	func searchKeywordLineContexts(
		keyword: String,
		linesPerBlock: Int,
		totalLines: Int,
		options: String.CompareOptions = .caseInsensitive
	) -> [MemoSearchHitContext] {
		let hits = searchKeyword(keyword, linesPerBlock: linesPerBlock, totalLines: totalLines, options: options)
		return hits.map { i in
			MemoSearchHitContext(
				globalLineIndex: i,
				previousLine: i > 0 ? lineTextAtGlobalIndex(i - 1, linesPerBlock: linesPerBlock, totalLines: totalLines) : "",
				matchLine: lineTextAtGlobalIndex(i, linesPerBlock: linesPerBlock, totalLines: totalLines),
				nextLine: i + 1 < totalLines ? lineTextAtGlobalIndex(i + 1, linesPerBlock: linesPerBlock, totalLines: totalLines) : ""
			)
		}
	}
}

/// 検索ヒット 1 件分（前行・当行・翌行）
struct MemoSearchHitContext: Identifiable, Hashable, Sendable {
	var id: Int { globalLineIndex }
	let globalLineIndex: Int
	let previousLine: String
	let matchLine: String
	let nextLine: String
}
