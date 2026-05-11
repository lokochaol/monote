//
//  MemoStorageRoot.swift
//  scroll
//

import Foundation

/// 設定シートに表示する診断情報。実機で「ローカル容量が思ったより減らない」ときに、
/// どのファイルがどこにあって何バイトかを目視確認するための一覧。
struct MemoStorageDiagnostics: Sendable {
	/// 現在使っているルートが iCloud Drive 配下か。
	var isUsingICloudRoot: Bool
	/// 表示用のルートパス（フル URL ではなくホーム以下の相対表現にしてある）。
	var rootDisplayPath: String
	/// `block_*.json` の数。
	var blockFileCount: Int
	/// `block_*.json` の合計バイト数（ローカル実体のサイズ。iCloud 退避済みのプレースホルダは小さい）。
	var blockTotalBytes: Int
	/// `attachments/` 直下のファイル数。
	var attachmentFileCount: Int
	/// `attachments/` 直下のファイルの合計バイト数。
	var attachmentTotalBytes: Int
	/// `index.json` のバイト数（存在しないときは 0）。
	var indexJsonBytes: Int
	/// `block_*.json` + `attachments/` + `index.json` の合計バイト数（メモ本体の目安）。
	var trackedTotalBytes: Int
	/// iCloud ルート時のみ。`ubiquitousItemIsUploaded == true` と判定されたファイルの合計バイト。
	/// OS が報告するメタデータに基づくため、ネットワーク状況で遅れや揺れがあり得る。
	var iCloudUploadedBytes: Int?
	/// iCloud ルート時のみ。上記以外（`false` / `nil`）のファイルの合計バイト。送信中・端末のみ・未確定を含む。
	var iCloudPendingBytes: Int?
	/// 取り残されているローカル `Documents/memo_blocks` のうち **メモ本体相当**
	/// （`block_*.json`・`attachments/**`・`index.json`）だけの件数とバイト数。
	/// `migration_*` や `undo_stack.json` など意図的にローカルに残すものは含めない。
	var leftoverLocalFileCount: Int
	/// メモ本体相当の取り残しの合計バイト数。
	var leftoverLocalBytes: Int
}

/// 上部バーのインジケータが表示する 3 つの状態。
/// - `.unknown`: 起動直後で iCloud の解決がまだ終わっていない（中立アイコン）。
/// - `.synced`: Ubiquity Container を取得できており、ブロック保存先が iCloud Drive を指している。
/// - `.disabled`: iCloud 未サインイン、Drive オフ、または当アプリの iCloud Drive をユーザがオフにしているなど。
enum MemoICloudStatus: Equatable, Sendable {
	case unknown
	case synced
	case disabled
}

/// 本文ブロック (`block_*.json`)・添付ファイル (`attachments/`)・index.json をどこに置くか決めるレイヤ。
///
/// 2 つの候補ルートがある:
/// - **ローカル**: `Documents/memo_blocks`
/// - **iCloud Drive**: `<ubiquityContainer>/Documents/memo_blocks`
///
/// 端末ストレージを節約したいユーザ向けに、iCloud が使えるなら iCloud を優先する。
/// 「Optimize iPhone Storage」相当の挙動が OS 任せで効くので、最近触っていないブロックは
/// 自動的にデバイスから退避され、見かけ容量が下がる。
nonisolated enum MemoStorageRoot {
	/// 既定で iCloud を使うかどうかを保持するフラグ。`true` のとき iCloud コンテナを優先。
	/// ユーザが明示的にオフにしたい場合は `false` を入れる。
	private static let preferICloudKey = "MemoPreferICloudStorage"

	/// 現セッションで iCloud ルートが有効化されたかをアプリ内で覚えておくキー。
	/// 一度成功した端末ではローカル → iCloud の移行を再度行わないようにするための目印。
	private static let activatedICloudKey = "MemoICloudStorageActivated"

	static var prefersICloud: Bool {
		get { UserDefaults.standard.object(forKey: preferICloudKey) as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: preferICloudKey) }
	}

	static var hasActivatedICloud: Bool {
		get { UserDefaults.standard.bool(forKey: activatedICloudKey) }
		set { UserDefaults.standard.set(newValue, forKey: activatedICloudKey) }
	}

	/// `Documents/` のローカル絶対 URL。
	static var localDocumentsURL: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
	}

	/// ローカル側の `memo_blocks` ディレクトリ URL。`MemoBlockPersistence` の旧来の保存先。
	static var localMemoBlocksURL: URL {
		localDocumentsURL.appendingPathComponent("memo_blocks", isDirectory: true)
	}

	/// iCloud (Ubiquity Container) 内の `Documents/memo_blocks` ディレクトリ URL を返す。
	/// - 注意: `url(forUbiquityContainerIdentifier:)` はメインスレッドから呼ぶと
	///   設定状況によっては数秒ブロックすることがある。必ず detached / background から呼ぶこと。
	/// - Returns: iCloud Drive 上のルート URL。コンテナが未設定 / iCloud 未サインインの場合は `nil`。
	static func resolveICloudMemoBlocksURLBlocking() -> URL? {
		guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
			return nil
		}
		return container
			.appendingPathComponent("Documents", isDirectory: true)
			.appendingPathComponent("memo_blocks", isDirectory: true)
	}
}

/// ローカル ⇄ iCloud 間の片方向ファイル移行を司る薄いヘルパ。
nonisolated enum MemoCloudStorageMigrator {
	/// ローカルの `memo_blocks/` 配下を iCloud Drive 側へ昇格させる。
	/// - 既に同名ファイルが iCloud 側にあれば、ローカル側は最終的に削除される（`setUbiquitous` の挙動）。
	/// - `migration_v1_externalize_lzfse.done` のような端末ローカル限定マーカーは移動しない。
	/// - `undo_stack.json` は端末ごとの履歴なので移動しない。
	/// - 失敗は握り潰し、移行できたぶんだけ進める。次回起動時にも再試行される。
	static func migrateLocalToICloudBlocking(localRoot: URL, ubiquityRoot: URL) {
		let fm = FileManager.default
		guard fm.fileExists(atPath: localRoot.path) else { return }
		try? fm.createDirectory(at: ubiquityRoot, withIntermediateDirectories: true)

		guard let entries = try? fm.contentsOfDirectory(at: localRoot, includingPropertiesForKeys: nil, options: []) else {
			return
		}
		for entry in entries {
			let name = entry.lastPathComponent
			if shouldSkipForCloud(name: name) { continue }

			let dest = ubiquityRoot.appendingPathComponent(name)
			var isDir: ObjCBool = false
			fm.fileExists(atPath: entry.path, isDirectory: &isDir)
			if isDir.boolValue {
				// `attachments/` のようなサブディレクトリは中身ごと再帰的に上げる。
				migrateLocalToICloudBlocking(localRoot: entry, ubiquityRoot: dest)
				// 中身を移し終えたら空ディレクトリだけ残るので、ここでは削除しない（OS にまかせる）。
			} else {
				do {
					try fm.setUbiquitous(true, itemAt: entry, destinationURL: dest)
				} catch {
					// 既に dest がある場合などは setUbiquitous が失敗する。ローカル側は触らないでスキップ。
					continue
				}
			}
		}
	}

	/// iCloud Drive 上の `memo_blocks/` 配下を端末ローカルへ引き戻す。
	/// - `setUbiquitous(false, ...)` は iCloud から削除しつつローカルへ移すので、これだけで両方が片付く。
	/// - 未ダウンロードのファイルが含まれている場合、システムが必要に応じてダウンロードを走らせる。
	///   ネットワーク等で失敗したアイテムはスキップして他を進める。次回以降に再試行できる。
	static func migrateICloudToLocalBlocking(ubiquityRoot: URL, localRoot: URL) {
		let fm = FileManager.default
		guard fm.fileExists(atPath: ubiquityRoot.path) else { return }
		try? fm.createDirectory(at: localRoot, withIntermediateDirectories: true)

		guard let entries = try? fm.contentsOfDirectory(at: ubiquityRoot, includingPropertiesForKeys: nil, options: []) else {
			return
		}
		for entry in entries {
			let name = entry.lastPathComponent
			if shouldSkipForCloud(name: name) { continue }

			let dest = localRoot.appendingPathComponent(name)
			var isDir: ObjCBool = false
			fm.fileExists(atPath: entry.path, isDirectory: &isDir)
			if isDir.boolValue {
				migrateICloudToLocalBlocking(ubiquityRoot: entry, localRoot: dest)
			} else {
				do {
					try fm.setUbiquitous(false, itemAt: entry, destinationURL: dest)
				} catch {
					continue
				}
			}
		}
	}

	/// 端末ローカルだけに存在すべきファイル（マイグレーションマーカー・undo 履歴）を判定する。
	private static func shouldSkipForCloud(name: String) -> Bool {
		if name.hasPrefix("migration_") { return true }
		if name == "undo_stack.json" { return true }
		if name.hasPrefix(".") { return true } // .DS_Store 等
		return false
	}
}

/// 診断情報を取りまとめるヘルパ。すべて `nonisolated` で詰め込み、UI 側からは
/// `Task.detached` 経由で呼ぶ前提。
nonisolated enum MemoStorageInspector {
	static func collectDiagnostics(rootURL: URL, isUsingICloudRoot: Bool) -> MemoStorageDiagnostics {
		let (blockCount, blockBytes) = inventoryFlat(in: rootURL, prefix: "block_", suffix: ".json")
		let attachmentsURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
		let (attCount, attBytes) = inventoryDirectoryRecursiveFilesOnly(attachmentsURL)
		let indexBytes = fileSizeIfExists(rootURL.appendingPathComponent("index.json"))
		let trackedTotal = blockBytes + attBytes + indexBytes
		let (uploaded, pending): (Int?, Int?) = {
			guard isUsingICloudRoot else { return (nil, nil) }
			return memoDataUploadBreakdown(rootURL: rootURL)
		}()
		let leftoverRoot = MemoStorageRoot.localMemoBlocksURL
		let (leftoverCount, leftoverBytes): (Int, Int) = {
			if !isUsingICloudRoot { return (0, 0) }
			if leftoverRoot.path == rootURL.path { return (0, 0) }
			return memoDataLeftoverOnLocalDisk(localRoot: leftoverRoot)
		}()
		return MemoStorageDiagnostics(
			isUsingICloudRoot: isUsingICloudRoot,
			rootDisplayPath: displayPath(rootURL),
			blockFileCount: blockCount,
			blockTotalBytes: blockBytes,
			attachmentFileCount: attCount,
			attachmentTotalBytes: attBytes,
			indexJsonBytes: indexBytes,
			trackedTotalBytes: trackedTotal,
			iCloudUploadedBytes: uploaded,
			iCloudPendingBytes: pending,
			leftoverLocalFileCount: leftoverCount,
			leftoverLocalBytes: leftoverBytes
		)
	}

	/// メモ本体（`block_*.json`・`attachments/**`・`index.json`）の URL を列挙する。
	/// 転送状態の走査とアップロード内訳で同じ集合を使う。
	private static func memoDataFileURLs(rootURL: URL) -> [URL] {
		var urls: [URL] = []
		let fm = FileManager.default
		if let names = try? fm.contentsOfDirectory(atPath: rootURL.path) {
			for name in names where name.hasPrefix("block_") && name.hasSuffix(".json") {
				urls.append(rootURL.appendingPathComponent(name))
			}
		}
		urls.append(rootURL.appendingPathComponent("index.json"))
		let attDir = rootURL.appendingPathComponent("attachments", isDirectory: true)
		if fm.fileExists(atPath: attDir.path),
		   let enumerator = fm.enumerator(at: attDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
			for case let url as URL in enumerator {
				var isDir: ObjCBool = false
				guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
				urls.append(url)
			}
		}
		return urls
	}

	/// いずれかのメモ本体ファイルが iCloud との送受信中（OS が報告するフラグ）なら `true`。
	static func memoDataHasActiveUbiquitousTransfer(rootURL: URL) -> Bool {
		for url in memoDataFileURLs(rootURL: rootURL) {
			guard FileManager.default.fileExists(atPath: url.path) else { continue }
			guard let vals = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey]) else { continue }
			if vals.ubiquitousItemIsUploading == true || vals.ubiquitousItemIsDownloading == true {
				return true
			}
		}
		return false
	}

	/// `block_*.json`・`attachments/**`・`index.json` だけを対象に、
	/// iCloud サーバへアップロード済み（`ubiquitousItemIsUploaded == true`）のバイトと、
	/// それ以外（`false` / `nil`＝送信中・端末のみ・未確定）のバイトに分ける。
	/// `trackedTotalBytes` と同じ集合なので、`uploaded + pending` は理論上 `trackedTotal` と一致する。
	private static func memoDataUploadBreakdown(rootURL: URL) -> (uploaded: Int, pending: Int) {
		var uploaded = 0
		var pending = 0
		for url in memoDataFileURLs(rootURL: rootURL) {
			classifyUploadState(url: url, uploaded: &uploaded, pending: &pending)
		}
		return (uploaded, pending)
	}

	/// iCloud 運用中にローカル `Documents/memo_blocks` に残っている **メモ本体ファイル**だけを数える。
	/// `migration_*` / `undo_stack.json` は意図的にローカルに置くため対象外。
	private static func memoDataLeftoverOnLocalDisk(localRoot: URL) -> (count: Int, bytes: Int) {
		let (blockCount, blockBytes) = inventoryFlat(in: localRoot, prefix: "block_", suffix: ".json")
		let attachmentsURL = localRoot.appendingPathComponent("attachments", isDirectory: true)
		let (attCount, attBytes) = inventoryDirectoryRecursiveFilesOnly(attachmentsURL)
		let indexURL = localRoot.appendingPathComponent("index.json")
		let indexBytes = fileSizeIfExists(indexURL)
		let indexCount = FileManager.default.fileExists(atPath: indexURL.path) ? 1 : 0
		return (blockCount + attCount + indexCount, blockBytes + attBytes + indexBytes)
	}

	private static func classifyUploadState(url: URL, uploaded: inout Int, pending: inout Int) {
		guard FileManager.default.fileExists(atPath: url.path) else { return }
		guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemIsUploadedKey]),
		      let size = vals.fileSize
		else { return }
		if vals.ubiquitousItemIsUploaded == true {
			uploaded += size
		} else {
			pending += size
		}
	}

	private static func fileSizeIfExists(_ url: URL) -> Int {
		let fm = FileManager.default
		guard fm.fileExists(atPath: url.path) else { return 0 }
		guard let attrs = try? fm.attributesOfItem(atPath: url.path),
		      let size = attrs[.size] as? NSNumber
		else { return 0 }
		return size.intValue
	}

	/// ディレクトリ配下の通常ファイルだけを再帰的に数える。ディレクトリ自体はサイズに含めない。
	private static func inventoryDirectoryRecursiveFilesOnly(_ dir: URL) -> (count: Int, bytes: Int) {
		let fm = FileManager.default
		guard fm.fileExists(atPath: dir.path) else { return (0, 0) }
		guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
			return (0, 0)
		}
		var count = 0
		var bytes = 0
		for case let url as URL in enumerator {
			let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
			guard values?.isRegularFile == true else { continue }
			if let size = values?.fileSize {
				count += 1
				bytes += size
			}
		}
		return (count, bytes)
	}

	private static func inventoryFlat(in dir: URL, prefix: String, suffix: String) -> (count: Int, bytes: Int) {
		let fm = FileManager.default
		guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return (0, 0) }
		var count = 0
		var bytes = 0
		for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
			let url = dir.appendingPathComponent(name)
			if let attrs = try? fm.attributesOfItem(atPath: url.path),
			   let size = attrs[.size] as? NSNumber {
				count += 1
				bytes += size.intValue
			}
		}
		return (count, bytes)
	}

	private static func displayPath(_ url: URL) -> String {
		let home = NSHomeDirectory()
		let path = url.path
		if path.hasPrefix(home) {
			return "~" + path.dropFirst(home.count)
		}
		return path
	}
}
