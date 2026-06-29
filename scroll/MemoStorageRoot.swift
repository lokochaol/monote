//
//  MemoStorageRoot.swift
//  scroll
//

import Foundation

/// 本文ブロック (`block_*.json`)・添付ファイル (`attachments/`)・index.json をどこに置くか決めるレイヤ。
///
/// 保存先は端末ローカルの `Documents/memo_blocks` のみ。
nonisolated enum MemoStorageRoot {
	/// `Documents/` のローカル絶対 URL。
	static var localDocumentsURL: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
	}

	/// ローカル側の `memo_blocks` ディレクトリ URL。メモ本体の保存先。
	static var localMemoBlocksURL: URL {
		localDocumentsURL.appendingPathComponent("memo_blocks", isDirectory: true)
	}
}
