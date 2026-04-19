//
//  MemoBlockPersistence.swift
//  scroll
//

import Foundation
import CoreGraphics

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

fileprivate struct BlockFile: Codable {
	var lines: [MemoLine]
}

private struct IndexFile: Codable {
	var linesPerBlock: Int
	var totalLines: Int
}

/// メモをブロックファイルに分割して永続化する
@MainActor
final class MemoBlockPersistence {
	private let rootURL: URL
	private let indexURL: URL

	init(fileManager: FileManager = .default) {
		let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
		rootURL = base.appendingPathComponent("memo_blocks", isDirectory: true)
		indexURL = rootURL.appendingPathComponent("index.json")
		try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
	}

	/// アンドゥ履歴を保存するファイルの URL。
	/// 本文のブロックファイルと同じディレクトリに相乗りする。
	var undoStackURL: URL {
		rootURL.appendingPathComponent("undo_stack.json")
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
		guard let file = try? JSONDecoder().decode(BlockFile.self, from: data) else { return [] }
		return file.lines
	}

	func saveBlock(_ index: Int, lines: [MemoLine]) {
		let file = BlockFile(lines: lines)
		if let data = try? JSONEncoder().encode(file) {
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
			if let data = try? JSONEncoder().encode(file) {
				blockPayloads[b] = data
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
		let blockCount = max(1, (max(0, totalLines) + linesPerBlock - 1) / linesPerBlock)

		var blockPayloads: [Int: Data] = [:]
		if startBlock < blockCount {
			for b in startBlock ..< blockCount {
				let startInTail = (b - startBlock) * linesPerBlock
				if startInTail >= linesFromStartBlock.count {
					let file = BlockFile(lines: [])
					if let data = try? JSONEncoder().encode(file) {
						blockPayloads[b] = data
					}
					continue
				}
				let endInTail = min(startInTail + linesPerBlock, linesFromStartBlock.count)
				let slice = Array(linesFromStartBlock[startInTail ..< endInTail])
				let file = BlockFile(lines: slice)
				if let data = try? JSONEncoder().encode(file) {
					blockPayloads[b] = data
				}
			}
		}
		let idx = IndexFile(linesPerBlock: linesPerBlock, totalLines: max(0, totalLines))
		let indexPayload = try? JSONEncoder().encode(idx)

		await Task.detached(priority: .utility) {
			func blockURL(_ index: Int) -> URL {
				rootURL.appendingPathComponent("block_\(index).json")
			}

			if startBlock < blockCount {
				for b in startBlock ..< blockCount {
					if let data = blockPayloads[b] {
						try? data.write(to: blockURL(b), options: .atomic)
					}
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
