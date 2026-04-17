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
