//
//  MemoEditorViewModel.swift
//  scroll
//

import Foundation
import Observation
import os
import SwiftUI

/// 改行分割などで MemoLineTextView へフォーカスを移すためのリクエスト（View が onChange で消費する）。
struct MemoEditorFocusRequest: Equatable {
	let lineId: UUID
	let caretUTF16: Int
}

@Observable
@MainActor
final class MemoEditorViewModel {
	private let persistence = MemoBlockPersistence()
	private var saveTask: Task<Void, Never>?
	/// 上方向プリフェッチの重複実行防止（非同期読み込み中）
	private var isLoadingPreviousBlock = false
	/// ヒステリシス: 一度読み込んだあと、先頭帯から十分離れるまで再トリガーしない
	private var prefetchRearmed = true
	/// 下方向トリムのヒステリシス: 一度落としたら、先頭付近へ戻るまで再トリガーしない
	private var trimRearmed = true
	private var isTrimmingLeadingBlock = false
	private weak var syncCoordinator: MemoSyncCoordinating?

	/// Undo / redo 用の履歴スタック。永続化されるので再起動後も残る。
	@ObservationIgnored private let undoManager = MemoEditorUndoManager()
	/// undo/redo 実行中は record をかけない。循環的な push を避けるためのフラグ。
	@ObservationIgnored private var isApplyingUndoRedo = false
	/// `MemoEditorView` が最後に通知してきたキャレット情報。View からのハンドラに渡しそびれない場面で参照する。
	@ObservationIgnored private var lastKnownCaret: (lineId: UUID, utf16: Int)?

	var linesPerBlock: Int = MemoBlockConfig.minLinesPerBlock
	var loadedBlockStart: Int = 0
	var loadedBlockEnd: Int = 0
	/// visibleLines[i] のグローバル行番号は globalLineOffset + i
	var visibleLines: [MemoLine] = []
	private(set) var totalPersistedLines: Int = 0
	private(set) var globalLineOffset: Int = 0

	var searchKeywordText: String = ""
	var searchHitContexts: [MemoSearchHitContext] = []
	var searchMessage: String?
	/// 検索キーワード（空ならハイライトなし）
	var searchHighlightKeyword: String?
	/// 検索結果からユーザーが選択した（ジャンプした）行。未選択なら nil。
	var searchHighlightGlobalLineIndex: Int?
	/// `searchHitContexts` から導出した「ヒットした行」の集合（表示側の高速判定用）。
	private(set) var searchHitGlobalLineIndexSet: Set<Int> = []

	var scrollAnchorLineId: UUID?
	var editorFocusRequest: MemoEditorFocusRequest?

	/// 上部バーの iCloud インジケータが参照する状態。`bootstrap` で初期化し、
	/// アカウント切り替えや Drive オフ／オンを `NSUbiquityIdentityDidChange` 経由で反映する。
	private(set) var iCloudStatus: MemoICloudStatus = .unknown
	/// メモ本体ファイルのいずれかが iCloud 送受信中と OS が報告しているとき `true`（ツールバーの回転表示用）。
	private(set) var iCloudTransferActive: Bool = false
	/// `NSUbiquityIdentityDidChange` の購読トークン。`deinit` で解除する。
	@ObservationIgnored private var ubiquityIdentityObserver: NSObjectProtocol?

	// MARK: - 複数行選択モード

	/// 選択モード（コピー・削除のための一括選択）に入っているか。
	/// `true` の間はフォーカス系・自動スクロール系の副作用をすべて抑止する。
	var isSelectionMode: Bool = false
	/// 現在選択されている行 ID（`visibleLines` 内）。モード解除時に必ず空へ戻す。
	var selectedLineIds: Set<UUID> = []

	/// 1 本のドラッグジェスチャ中、「最初に触れた行が未選択だったか選択済みだったか」でジェスチャ全体のモードが確定する。
	private enum DragSelectionMode { case adding, removing }
	private var dragSelectionMode: DragSelectionMode?
	/// ジェスチャ開始直前の `selectedLineIds`。範囲方式の基底状態として、
	/// extend のたびにこれと「最初に触れた行〜現在指の行」の範囲を `union` / `subtracting` して上書きする。
	/// これにより、なぞり戻しで範囲が縮むと、外れた行は基底状態へ自然に戻る。
	private var dragSelectionSnapshot: Set<UUID> = []
	/// ジェスチャ最初に触れた行の ID。
	private var dragFirstLineId: UUID?

	private var searchDebounceTask: Task<Void, Never>?
	/// 入力中の最新リッチ本文（永続化用）。キー入力ごとの RTF/Archive 生成を避けるためキャッシュする。
	/// `displayAttributed(for:)` 経由で `body` からも読まれるが、毎キー入力で更新されるため
	/// `@Observable` の依存トラッキング対象にすると `visibleLines` 代入と合わせて二重に invalidate が走る。
	/// 観測対象は `visibleLines` だけに絞り、ここの書き換えでは SwiftUI 側の再評価を誘発しない。
	@ObservationIgnored private var pendingRichByLineId: [UUID: NSAttributedString] = [:]

	/// ホットパス（改行なしのキー入力）で `visibleLines[idx]` への代入を遅延させるための
	/// 行単位パッチ。入力中は `text` / `modifiedAt` / `firstWrittenAt` の変更をここに積んでおき、
	/// `flushPendingVisibleUpdates()`（次の run loop 周回 or 明示呼び出し）で一括反映する。
	/// `@Observable` の invalidate を発生させないよう Observation 対象外にしている。
	@ObservationIgnored private var pendingLinePatches: [UUID: LinePatch] = [:]
	@ObservationIgnored private var idleFlushScheduled = false

	private struct LinePatch {
		var text: String
		var modifiedAt: Date
		/// 「今まで空行 → 今回初めて本文が入った」ときだけ非 nil（初筆時刻）。
		var firstWrittenAt: Date?
	}

	private struct DisplayAttrCacheEntry {
		var fingerprint: Int
		var attr: NSAttributedString
	}
	/// 表示用 attributed の復元キャッシュ（フォーカス移動やスクロールでの再計算を抑える）。
	/// `body` 評価中に `displayAttributed(for:)` から更新するため、観測対象外にして
	/// 「ビュー更新中の状態変更」警告を避ける。
	@ObservationIgnored private var displayAttrCacheByLineId: [UUID: DisplayAttrCacheEntry] = [:]

	/// `NSAttachmentCharacter` (U+FFFC) が含まれるかだけを見る超軽量判定。
	/// 画像・リンクチップ等の `NSTextAttachment` を貼ると本文 plain text にこの文字が入るため、
	/// `enumerateAttribute(.attachment, ...)` の属性ラン走査なしに添付有無を判定できる。
	private static func stringContainsAttachmentMarker(_ s: String) -> Bool {
		guard !s.isEmpty else { return false }
		for scalar in s.unicodeScalars where scalar.value == 0xFFFC {
			return true
		}
		return false
	}

	private func fingerprintForDisplay(line: MemoLine) -> Int {
		var h = Hasher()
		h.combine(line.text)
		h.combine(line.richTextRTF?.count ?? 0)
		h.combine(line.richTextArchive?.count ?? 0)
		// modifiedAt を入れると編集の反映漏れが起きにくい（ただし pending がある場合はそちらが優先される）
		h.combine(line.modifiedAt.timeIntervalSince1970)
		return h.finalize()
	}

	private func pruneDisplayCachesToVisible() {
		let ids = Set(visibleLines.map(\.id))
		displayAttrCacheByLineId = displayAttrCacheByLineId.filter { ids.contains($0.key) }
		// pendingRichByLineId は編集中の行のみのはずだが、念のため visible 範囲外も落とす
		pendingRichByLineId = pendingRichByLineId.filter { ids.contains($0.key) }
		pendingLinePatches = pendingLinePatches.filter { ids.contains($0.key) }
	}

	/// `visibleLines[idx].text` より新しい、pending 反映後の最新 plain text。
	/// パッチが無ければ素の値を返す。`updateLineRichContent` 内での差分計算などに使う。
	private func effectiveText(for line: MemoLine) -> String {
		pendingLinePatches[line.id]?.text ?? line.text
	}

	/// 次の run loop 周回で `flushPendingVisibleUpdates()` を 1 回だけ呼ぶよう予約する。
	/// バースト入力中は複数キーぶん溜めて最後に 1 度だけ SwiftUI 側を走らせる狙い。
	private func scheduleIdleFlushIfNeeded() {
		guard !idleFlushScheduled else { return }
		idleFlushScheduled = true
		// main.async は現在の runloop turn を抜けたあと（典型的には次の event 前の idle）に走る。
		// ユーザーのキー入力イベントは別の runloop turn でやって来るので、タイピングの合間に挟まる。
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			MainActor.assumeIsolated {
				self.flushPendingVisibleUpdates()
			}
		}
	}

	/// `pendingLinePatches` を `visibleLines` に一括反映する。
	/// ここで初めて `visibleLines` への書き込みが起き、SwiftUI に 1 回だけ invalidate が伝わる。
	/// - 改行分割・行マージ・削除・保存・undo スナップショットなど「最新 `visibleLines` が必要な処理」の直前で
	///   明示的に呼ぶと、model 全体の整合性を担保したままホットパスだけを遅延させられる。
	private func flushPendingVisibleUpdates() {
		idleFlushScheduled = false
		guard !pendingLinePatches.isEmpty else { return }
		let patches = pendingLinePatches
		pendingLinePatches = [:]

		var touched = false
		for (id, patch) in patches {
			guard let idx = visibleLines.firstIndex(where: { $0.id == id }) else { continue }
			var line = visibleLines[idx]
			var changed = false
			if line.text != patch.text {
				line.text = patch.text
				changed = true
			}
			if line.modifiedAt != patch.modifiedAt {
				line.modifiedAt = patch.modifiedAt
				changed = true
			}
			if let fwa = patch.firstWrittenAt, line.firstWrittenAt != fwa {
				line.firstWrittenAt = fwa
				changed = true
			}
			if changed {
				visibleLines[idx] = line
				touched = true
			}
		}
		if touched {
			updateTotalsAndBlocks()
		}
	}

	/// 行の表示に使う attributed。編集中は pending を返し、そうでなければ復元結果をキャッシュする。
	func displayAttributed(for line: MemoLine) -> NSAttributedString {
		if let pending = pendingRichByLineId[line.id] { return pending }
		let fp = fingerprintForDisplay(line: line)
		if let e = displayAttrCacheByLineId[line.id], e.fingerprint == fp {
			return e.attr
		}
		let decoded = MemoRichTextEncoding.attributedString(
			rtfData: line.richTextRTF,
			archiveData: line.richTextArchive,
			plainFallback: line.text
		)
		displayAttrCacheByLineId[line.id] = DisplayAttrCacheEntry(fingerprint: fp, attr: decoded)
		return decoded
	}

	func attachSyncCoordinator(_ coordinator: MemoSyncCoordinating?) {
		syncCoordinator = coordinator
	}

	/// `NSUbiquityIdentityDidChange` を購読する。Apple Account の切り替え／サインアウトが
	/// 起こったときに `iCloudStatus` を再評価し、必要なら次回起動以降のために設定値を倒す。
	/// `bootstrap` から 1 度だけ呼ぶ想定。多重購読を防ぐため、すでに登録済みなら何もしない。
	private func startObservingICloudIdentityIfNeeded() {
		guard ubiquityIdentityObserver == nil else { return }
		ubiquityIdentityObserver = NotificationCenter.default.addObserver(
			forName: .NSUbiquityIdentityDidChange,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				await self?.refreshICloudStatus()
			}
		}
	}

	deinit {
		if let token = ubiquityIdentityObserver {
			NotificationCenter.default.removeObserver(token)
		}
	}

	/// 現時点の Ubiquity Container 取得状況を見て `iCloudStatus` を更新する。
	/// - Apple Account にサインインしていて、Drive がオン、当アプリの iCloud Drive 利用も許可されているなら `.synced`。
	/// - どれかが満たされていなければ `.disabled`。
	/// `url(forUbiquityContainerIdentifier:)` が重い可能性があるので detached で叩く。
	func refreshICloudStatus() async {
		let canResolve = await Task.detached(priority: .utility) { () -> Bool in
			MemoStorageRoot.resolveICloudMemoBlocksURLBlocking() != nil
		}.value
		iCloudStatus = canResolve && persistence.isUsingICloudRoot ? .synced : .disabled
		await refreshICloudTransferState()
	}

	/// `ubiquitousItemIsUploading` / `IsDownloading` をメモ本体ファイルに対して走査する。I/O は utility で実行。
	func refreshICloudTransferState() async {
		guard persistence.isUsingICloudRoot else {
			iCloudTransferActive = false
			return
		}
		let root = persistence.rootURL
		let active = await Task.detached(priority: .utility) {
			MemoStorageInspector.memoDataHasActiveUbiquitousTransfer(rootURL: root)
		}.value
		iCloudTransferActive = active
	}

	/// アプリ内のトグルから iCloud 同期を切り替える。
	/// - ON にすると `MemoBlockPersistence` がローカル → iCloud へファイルを昇格する。
	/// - OFF にすると iCloud → ローカルに引き戻す（その分 iCloud Drive 上の `Documents/memo_blocks` は消える）。
	/// - 切り替え中は I/O が走るので `iCloudStatus` を一旦 `.unknown` に倒し、UI 側で「処理中」を表現する。
	/// - 戻り値は切り替え後に iCloud ルートを使っているか。
	@discardableResult
	func toggleICloudSync(enabled: Bool) async -> Bool {
		// 進行中であることをインジケータに反映。Drive 自体が使えないケースは ON でも結果は `.disabled`。
		iCloudStatus = .unknown
		// 切り替え前に保留中の保存を吐かせる。古いルートに対する書き込みが進行中のまま
		// マイグレーションが始まると、ファイルの片割れが残ったり flushed 状態がズレたりするのを防ぐ。
		await flushPendingSavesIfAny()
		let nowICloud = await persistence.setICloudEnabled(enabled)
		iCloudStatus = nowICloud ? .synced : .disabled
		await refreshICloudTransferState()
		return nowICloud
	}

	/// 切り替え前に保留中のセーブタスクを排出する。`saveTask` は最新の差分保存ジョブを 1 本だけ抱えるので、
	/// それを await すれば直近の編集はディスクに反映済みになる。タスクが無いときは何もしない。
	private func flushPendingSavesIfAny() async {
		await saveTask?.value
	}

	// MARK: - 診断 / 端末容量の能動解放

	/// 設定シートに表示する診断情報を取得する。
	/// I/O は detached で行うので呼び出し側はメインで await して問題ない。
	func fetchStorageDiagnostics() async -> MemoStorageDiagnostics {
		let rootURL = persistence.rootURL
		let isCloud = persistence.isUsingICloudRoot
		return await Task.detached(priority: .utility) {
			MemoStorageInspector.collectDiagnostics(rootURL: rootURL, isUsingICloudRoot: isCloud)
		}.value
	}

	/// 現在表示中のブロックだけを残し、それ以外の iCloud アイテムを端末から能動退避する。
	/// - ローカル運用中（`!isUsingICloudRoot`）は何もせず 0 を返す。
	/// - Returns: 退避を試みた件数。成功・失敗の合算。
	@discardableResult
	func evictUnusedICloudItems() async -> Int {
		// 「いま見ているレンジ」を keep する。先頭・末尾ブロックの両端 + index.json は触らない。
		var keep: Set<Int> = []
		if linesPerBlock > 0 {
			for b in loadedBlockStart ... loadedBlockEnd {
				keep.insert(b)
			}
		}
		return await persistence.evictUnusedICloudItems(keepBlockIndices: keep)
	}

	func bootstrap(screenHeight: CGFloat) async {
		linesPerBlock = MemoBlockConfig.linesPerBlock(screenHeight: screenHeight)
		// アカウント切り替えやサインアウトをアプリ実行中も拾えるよう、初回起動時に通知を購読しておく。
		startObservingICloudIdentityIfNeeded()
		// 設定で iCloud が有効、かつ Ubiquity Container が使えるなら、index.json を読む前にルートを iCloud 側へ切り替える。
		// 失敗時（iCloud 未サインイン等）はそのままローカルを使う。
		// 取得が長引くと UI 起動が遅れるため、軽いタイムアウト（500ms）で諦めてローカルにフォールバックする。
		await Self.runWithTimeout(milliseconds: 500) { [persistence] in
			await persistence.prepareStorageRootIfNeeded()
		}
		// インジケータ表示用の状態を確定させる。`prepareStorageRootIfNeeded` がタイムアウトでローカル
		// にフォールバックしていても、ここで再評価すれば「実は iCloud は使えていた」場合に正しい表示になる。
		iCloudStatus = persistence.isUsingICloudRoot ? .synced : .disabled
		await refreshICloudTransferState()
		let (savedLPB, total) = persistence.loadIndex()

		if savedLPB > 0, savedLPB != linesPerBlock, total > 0 {
			let all = persistence.loadAllLines(linesPerBlock: savedLPB, totalFromIndex: total)
			persistence.saveAllLines(all, linesPerBlock: linesPerBlock)
		}

		let (_, newTotal) = persistence.loadIndex()
		totalPersistedLines = newTotal

		if totalPersistedLines == 0 {
			visibleLines = [MemoLine()]
			pruneDisplayCachesToVisible()
			globalLineOffset = 0
			loadedBlockStart = 0
			loadedBlockEnd = 0
			totalPersistedLines = 1
			scheduleSave()
			undoManager.loadFromDisk(at: persistence.undoStackURL)
			return
		}

		let lastBlock = (totalPersistedLines - 1) / linesPerBlock
		loadedBlockStart = lastBlock
		loadedBlockEnd = lastBlock
		globalLineOffset = lastBlock * linesPerBlock
		visibleLines = persistence.loadBlock(lastBlock)
		pruneDisplayCachesToVisible()
		normalizeTrailingEmptyLineOnBootstrap()
		undoManager.loadFromDisk(at: persistence.undoStackURL)

		// 旧フォーマットのブロックを新フォーマット（外部添付ストア + LZFSE）に書き直すワンショット移行。
		// 起動の表示（先頭ブロック）には影響させたくないので、UI が立ち上がってから fire-and-forget で走らせる。
		// `migrateBlocksToCompressedFormatIfNeeded` は完了マーカーで二重実行をガードしているので毎回呼んでよい。
		Task { [persistence] in
			await persistence.migrateBlocksToCompressedFormatIfNeeded()
		}
		await refreshICloudTransferState()
	}

	/// 与えたクロージャをタイムアウト付きで走らせる。指定時間内に完了しなければ諦めて戻る。
	/// `prepareStorageRootIfNeeded()` のように「成功すれば良いが、外部要因で長引きうる」初期化を起動経路から呼ぶ用途。
	/// タイムアウト後もクロージャ側のタスクはバックグラウンドで継続させるため、戻り値は無視する。
	private static func runWithTimeout(milliseconds: UInt64, _ work: @MainActor @escaping () async -> Void) async {
		await withTaskGroup(of: Void.self) { group in
			group.addTask { @MainActor in await work() }
			group.addTask {
				try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
			}
			// どちらか早いほうの完了で戻る。残りはキャンセルしてリソース解放。
			_ = await group.next()
			group.cancelAll()
		}
	}

	private func blockCount(forTotalLines total: Int) -> Int {
		guard total > 0, linesPerBlock > 0 else { return 0 }
		return (total + linesPerBlock - 1) / linesPerBlock
	}

	/// 先頭ブロック相当のおおよその高さ（スクロール閾値用。実測より軽量）
	func estimatedFirstBlockHeight() -> CGFloat {
		guard linesPerBlock > 0 else { return MemoBlockConfig.approximateLineHeight }
		return CGFloat(linesPerBlock) * MemoBlockConfig.approximateLineHeight
	}

	/// 無限スクロール: スクロールビュー座標系における **コンテンツ先頭** の minY。
	/// 先頭がビュー上端付近では 0 に近く、下方向へスクロールするほど負に大きくなる想定。
	/// 先頭ブロックの「上から 1/5」以内が見えている帯（`>= -firstBlockHeight * 0.2`）で前ブロックを読み込む。
	func reportScrollForInfiniteScroll(contentTopY: CGFloat, firstBlockHeight: CGFloat, focusedLineId: UUID?) {
		guard loadedBlockStart > 0, firstBlockHeight > 1 else { return }
		if contentTopY < -firstBlockHeight * 0.35 {
			prefetchRearmed = true
		}
		guard prefetchRearmed, !isLoadingPreviousBlock else { return }
		guard contentTopY >= -firstBlockHeight * 0.2 else { return }

		let prev = loadedBlockStart - 1
		let anchorId = visibleLines.first?.id
		prefetchRearmed = false
		isLoadingPreviousBlock = true

		Task { [weak self] in
			guard let self else { return }
			let prefix = await persistence.loadBlockAsync(prev)
			await MainActor.run {
				self.isLoadingPreviousBlock = false
				guard self.loadedBlockStart > 0, self.loadedBlockStart - 1 == prev else {
					self.prefetchRearmed = true
					return
				}
				if prefix.isEmpty {
					self.loadedBlockStart = prev
					self.prefetchRearmed = true
					return
				}
				self.scrollAnchorLineId = anchorId
				self.loadedBlockStart = prev
				self.globalLineOffset = prev * self.linesPerBlock
				var merged = prefix
				merged.append(contentsOf: self.visibleLines)
				self.visibleLines = merged
				self.pruneDisplayCachesToVisible()
			}
		}
	}

	/// 無限スクロールで過去を読み込んで `visibleLines` が肥大化し続けるのを防ぐため、
	/// 十分下方向にスクロールしたら先頭ブロックを 1 つ落としてメモリ上限を作る。
	func reportScrollForWindowTrim(contentTopY: CGFloat, firstBlockHeight: CGFloat, focusedLineId: UUID?) {
		guard firstBlockHeight > 1 else { return }
		guard loadedBlockStart < loadedBlockEnd else { return }
		guard !isTrimmingLeadingBlock else { return }

		// 先頭付近まで戻ったら再アーム（振動防止）。
		if contentTopY > -firstBlockHeight * 0.85 {
			trimRearmed = true
		}
		guard trimRearmed else { return }

		// 先頭ブロックが十分見えなくなるほど下へ行ったら 1 ブロック落とす。
		guard contentTopY < -firstBlockHeight * 1.35 else { return }

		let removeCount = min(linesPerBlock, max(0, visibleLines.count))
		guard removeCount > 0, visibleLines.count > removeCount else { return }

		if let fid = focusedLineId, let idx = visibleLines.firstIndex(where: { $0.id == fid }), idx < removeCount {
			return
		}

		isTrimmingLeadingBlock = true
		trimRearmed = false
		let anchorId = visibleLines[removeCount].id

		visibleLines.removeFirst(removeCount)
		globalLineOffset += removeCount
		loadedBlockStart += 1
		pruneDisplayCachesToVisible()
		updateTotalsAndBlocks()
		scrollAnchorLineId = anchorId

		isTrimmingLeadingBlock = false
	}

	func consumeScrollAnchor() -> UUID? {
		let id = scrollAnchorLineId
		scrollAnchorLineId = nil
		return id
	}

	/// 末尾に空行を付けるのは、実データの最終行を含む表示中のみ（検索で途中ブロックだけ見せるときは付けない）
	private func isViewingDocumentTail() -> Bool {
		guard totalPersistedLines > 0 else { return true }
		return globalLineOffset + visibleLines.count >= totalPersistedLines
	}

	/// `UITextView` が空行でも `\n` のみを返すことがあり、それを空行とみなす。
	private func isEffectivelyEmptyLineText(_ text: String) -> Bool {
		text.isEmpty || text.allSatisfy(\.isNewline)
	}

	/// 文書末尾を表示しているとき、末尾の空行パターンを一貫させる（入力用の単一空行など）。
	private func normalizeTrailingEmptyLineIfViewingTail() {
		if visibleLines.isEmpty {
			visibleLines = [MemoLine()]
			return
		}
		guard isViewingDocumentTail() else { return }

		while visibleLines.count > 1,
		      let last = visibleLines.last,
		      let beforeLast = visibleLines.dropLast().last,
		      isEffectivelyEmptyLineText(last.text),
		      isEffectivelyEmptyLineText(beforeLast.text) {
			visibleLines.removeLast()
		}

		if let last = visibleLines.last, !isEffectivelyEmptyLineText(last.text) {
			visibleLines.append(MemoLine())
		}
	}

	/// 起動時のみ、文書末尾の空行をちょうど1行に正規化する。
	private func normalizeTrailingEmptyLineOnBootstrap() {
		normalizeTrailingEmptyLineIfViewingTail()
	}

	/// 表示が永続化された文書の末尾を含むか（末尾の入力用空行を置く対象か）。
	func isViewingPersistedDocumentTail() -> Bool {
		guard totalPersistedLines > 0 else { return true }
		return globalLineOffset + visibleLines.count >= totalPersistedLines
	}

	/// 文書末尾の入力用空行へフォーカスを合わせる準備。必要なら `ensureTrailingEmptyLine` で行を足す。
	func prepareEditorFocusAtBootstrap() -> UUID? {
		let before = visibleLines.count
		normalizeTrailingEmptyLineOnBootstrap()
		if visibleLines.count != before {
			totalPersistedLines = globalLineOffset + visibleLines.count
			updateTotalsAndBlocks()
			scheduleSave()
		}
		return visibleLines.last?.id
	}

	func currentTailLineId() -> UUID? {
		visibleLines.last?.id
	}

	func updateLineRichContent(id: UUID, attributed: NSAttributedString, caretUTF16: Int = 0) {
		let updateState = MemoSignpost.signposter.beginInterval("updateLineRichContent")
		defer { MemoSignpost.signposter.endInterval("updateLineRichContent", updateState) }

		/// 空行で勝手に `\n` のみが来ることがあるため、改行だけの内容は空として扱う。
		let normalized: NSAttributedString = {
			let s = attributed.string
			guard !s.isEmpty, s.allSatisfy(\.isNewline) else { return attributed }
			return NSAttributedString(string: "", attributes: MemoRichTextEncoding.defaultTypingAttributes())
		}()

		guard let idx = visibleLines.firstIndex(where: { $0.id == id }) else { return }
		// 変更前にキャレット情報だけでもキャッシュしておく（別経路の undo 記録で使える）。
		lastKnownCaret = (id, caretUTF16)

		// 差分が大きい（ペースト・画像挿入・タイムスタンプ挿入など）ときは
		// テキストタイピングとは別の undo ステップに区切る。
		// 「前回」の値は pending パッチが積まれていればそちらを優先する（バースト入力中も正確な差分で判定できる）。
		let previousLine = visibleLines[idx]
		let previousText = effectiveText(for: previousLine)
		let plain = normalized.string
		let previousLen = (previousText as NSString).length
		let newLen = (plain as NSString).length
		let delta = abs(newLen - previousLen)
		let attachmentState = MemoSignpost.signposter.beginInterval("containsTextAttachment")
		// 旧実装は `enumerateAttribute(.attachment, ...)` を毎キー2回（previous と new）呼んでいた。
		// 添付文字は plain text 側に U+FFFC（NSAttachmentCharacter）として必ず現れるため、
		// プレーン文字列の 1 パス走査に置き換えて属性ランの走査コストを省く。
		let previousHadAttachment = Self.stringContainsAttachmentMarker(previousText)
		let newHasAttachment = Self.stringContainsAttachmentMarker(plain)
		MemoSignpost.signposter.endInterval("containsTextAttachment", attachmentState)
		let recordKind: MemoEditorUndoManager.SnapshotKind =
			(delta > 4 || (newHasAttachment && !previousHadAttachment))
				? .structural
				: .textEdit

		// 改行を含むときだけは行数が変わる可能性があり、以降の split・フォーカス更新で
		// 正確な `visibleLines` が要るので、ここで pending を確定させる。
		// なおこの判定は先に行い、スナップショット取得のタイミングを「常に一貫した状態」に揃える。
		let plainScalars = plain.unicodeScalars
		let hasNewline = plainScalars.contains(where: { $0 == "\n" || $0 == "\r" })
		if hasNewline {
			flushPendingVisibleUpdates()
		}

		// pre-mutation スナップショットを記録（または既存 entry にコアレス）。
		// スナップショット内部は pending も含めて保持するため、ここまでに flush 済みなら undo も一貫する。
		recordUndoIfNeeded(kind: recordKind, focusedLineId: id, caretUTF16: caretUTF16)

		let now = Date()
		let wasEmpty = isEffectivelyEmptyLineText(previousText)
		// 重要: 入力ごとに RTF/Archive を生成すると重いので、ここでは plain の更新と
		// 永続化用の「最新 attributed」をキャッシュするだけに留める。
		pendingRichByLineId[id] = normalized

		if hasNewline {
			// 改行あり（主にペースト）: `visibleLines` を同期で更新して split → フォーカスを確定させる。
			var line = previousLine
			line.text = plain
			line.modifiedAt = now
			if wasEmpty, !plain.isEmpty {
				line.firstWrittenAt = now
			}
			visibleLines[idx] = line
			displayAttrCacheByLineId[id] = DisplayAttrCacheEntry(fingerprint: fingerprintForDisplay(line: line), attr: normalized)
			let splitState = MemoSignpost.signposter.beginInterval("handleAttributedMultilineSplit")
			let splitFocus = handleAttributedMultilineSplit(at: idx, using: normalized)
			MemoSignpost.signposter.endInterval("handleAttributedMultilineSplit", splitState)
			updateTotalsAndBlocks()
			scheduleSave()
			if let (fid, caret) = splitFocus {
				editorFocusRequest = MemoEditorFocusRequest(lineId: fid, caretUTF16: caret)
			} else if editorFocusRequest != nil {
				editorFocusRequest = nil
			}
			return
		}

		// ホットパス: 同一行内の通常入力。`visibleLines` の代入は遅延させ、
		// SwiftUI の body / 各行の `updateUIView` の再評価が毎キー走らないようにする。
		//
		// 表示は `displayAttributed(for:)` が pendingRich を最優先で返すため、
		// 遅延中も `UITextView` に渡るテキストは最新値（＝pending の内容）と一致する。
		// そもそも入力中の UITextView 自身が真のソースなので、画面上はキー入力即反映のまま。
		var patch = pendingLinePatches[id] ?? LinePatch(text: previousLine.text, modifiedAt: previousLine.modifiedAt, firstWrittenAt: nil)
		patch.text = plain
		patch.modifiedAt = now
		if wasEmpty, !plain.isEmpty, previousLine.firstWrittenAt == nil, patch.firstWrittenAt == nil {
			patch.firstWrittenAt = now
		}
		pendingLinePatches[id] = patch

		scheduleSave()
		// 頻繁に nil を代入すると @Observable が毎回 invalidate を発火するので、
		// 実際に値が残っているときだけクリアする。
		if editorFocusRequest != nil {
			editorFocusRequest = nil
		}
		scheduleIdleFlushIfNeeded()
	}

	func insertLineBreak(id: UUID, attributed: NSAttributedString, range: NSRange) {
		// 以降 `visibleLines` を増やすため、まずホットパスで溜めたパッチを反映して一貫した状態にする。
		flushPendingVisibleUpdates()
		guard let idx = visibleLines.firstIndex(where: { $0.id == id }) else { return }
		recordUndoIfNeeded(kind: .structural, focusedLineId: id, caretUTF16: range.location)

		let mutable = NSMutableAttributedString(attributedString: attributed)
		let replacement = NSAttributedString(string: "\n", attributes: MemoRichTextEncoding.defaultTypingAttributes())
		mutable.replaceCharacters(in: range, with: replacement)

		var line = visibleLines[idx]
		let segments = MemoRichTextEncoding.attributedSplitByNewlines(mutable)
		guard let first = segments.first else { return }

		line.text = first.string
		pendingRichByLineId[line.id] = first
		line.modifiedAt = Date()
		visibleLines[idx] = line

		let now = Date()
		let inserted: [MemoLine] = segments.dropFirst().map { seg in
			let text = seg.string
			let firstWrittenAt = now
			let newLine = MemoLine(text: text, firstWrittenAt: firstWrittenAt, modifiedAt: now)
			pendingRichByLineId[newLine.id] = seg
			return newLine
		}
		visibleLines.insert(contentsOf: inserted, at: idx + 1)
		updateTotalsAndBlocks()
		scheduleSave()

		let focusIndex = idx + min(1, inserted.count)
		guard focusIndex < visibleLines.count else { return }
		let focusLine = visibleLines[focusIndex]
		editorFocusRequest = MemoEditorFocusRequest(lineId: focusLine.id, caretUTF16: 0)
	}

	/// 改行を含む行を分割した場合、カーソルがあるべき最終セグメントの行 ID と UTF-16 オフセット。
	/// - Parameter attr: 今まさに適用しようとしている最新の attributed 内容。
	///   以前は `visibleLines[index].attributedContent()` を毎回再デコードしており、
	///   RTF 経由で 1 キーごとに数 ms 〜 数十 ms の固定コストが乗っていた。呼び出し側が持つ
	///   最新の attributed を渡すことで、ここでの RTF 再パースを完全に排除する。
	private func handleAttributedMultilineSplit(at index: Int, using attr: NSAttributedString) -> (UUID, Int)? {
		var line = visibleLines[index]
		guard attr.length > 0 else { return nil }
		// ほぼ常に「改行なし」で抜けるため、まず最も安い plain 文字列の走査で短絡判定する。
		// `shouldChangeTextIn:` 側で `\n` は弾いているので、ここに来るのはペーストなど例外ケースのみ。
		guard attr.string.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }

		let segments = MemoRichTextEncoding.attributedSplitByNewlines(attr)
		guard segments.count > 1 else { return nil }

		let first = segments[0]
		line.text = first.string
		pendingRichByLineId[line.id] = first
		displayAttrCacheByLineId[line.id] = DisplayAttrCacheEntry(fingerprint: fingerprintForDisplay(line: line), attr: first)
		line.modifiedAt = Date()
		visibleLines[index] = line

		let now = Date()
		let inserted: [MemoLine] = segments.dropFirst().map { seg in
			let t = seg.string
			let l = MemoLine(text: t, firstWrittenAt: now, modifiedAt: now)
			pendingRichByLineId[l.id] = seg
			displayAttrCacheByLineId[l.id] = DisplayAttrCacheEntry(fingerprint: fingerprintForDisplay(line: l), attr: seg)
			return l
		}
		visibleLines.insert(contentsOf: inserted, at: index + 1)
		let lastIndex = index + inserted.count
		let lastLine = visibleLines[lastIndex]
		let caret = (lastLine.text as NSString).length
		return (lastLine.id, caret)
	}

	/// 結合直後の文字列（改行で分割前）上の UTF-16 オフセットを、`handleAttributedMultilineSplit` 後の行 ID と行内オフセットへ写す。
	private func mapGlobalCaretAfterNewlineSplit(mergedLineStartIndex: Int, fullMerge: NSAttributedString, globalCaretUTF16: Int) -> (UUID, Int)? {
		let segments = MemoRichTextEncoding.attributedSplitByNewlines(fullMerge)
		guard segments.count > 1, mergedLineStartIndex + segments.count <= visibleLines.count else { return nil }

		let ns = fullMerge.string as NSString
		var g = 0
		for i in 0 ..< segments.count {
			let L = (segments[i].string as NSString).length
			if globalCaretUTF16 < g + L {
				let line = visibleLines[mergedLineStartIndex + i]
				let local = globalCaretUTF16 - g
				let maxLocal = (line.text as NSString).length
				return (line.id, max(0, min(local, maxLocal)))
			}
			if globalCaretUTF16 == g + L, i + 1 < segments.count {
				let line = visibleLines[mergedLineStartIndex + i + 1]
				return (line.id, 0)
			}
			g += L
			guard g < ns.length else { break }
			let c = ns.character(at: g)
			if c == 13, g + 1 < ns.length, ns.character(at: g + 1) == 10 {
				g += 2
			} else if c == 10 || c == 13 {
				g += 1
			} else {
				break
			}
		}
		let last = mergedLineStartIndex + segments.count - 1
		guard last < visibleLines.count else { return nil }
		let line = visibleLines[last]
		return (line.id, (line.text as NSString).length)
	}

	/// 行頭 Backspace: 現在行を直前行に結合する。戻り値はフォーカス先の行 ID と UTF-16 上のキャレット位置。
	func mergeLineWithPrevious(id: UUID) -> (lineId: UUID, caretUTF16: Int)? {
		// マージ元・マージ先の最新 plain text を正しく使うため、pending を確定してから処理する。
		flushPendingVisibleUpdates()
		guard visibleLines.count > 1, let idx = visibleLines.firstIndex(where: { $0.id == id }), idx > 0 else { return nil }
		recordUndoIfNeeded(kind: .structural, focusedLineId: id, caretUTF16: 0)
		var prev = visibleLines[idx - 1]
		let curr = visibleLines[idx]
		// 行頭 Backspace → 48ms 待ってこのマージが走る間に、フォーカスが移った直前行で
		// さらに Backspace が連打されることがある（キーリピート）。その編集は
		// `pendingRichByLineId` にだけ反映されていて、RTF/Archive はまだ古い内容のままなので、
		// `attributedContent()` を使うと直前に消した文字が復活してマージ結果が破綻する。
		// 最新の attributed は pending を優先して取り出す。
		let prevAttr = pendingRichByLineId[prev.id] ?? prev.attributedContent()
		let currAttr = pendingRichByLineId[curr.id] ?? curr.attributedContent()
		let merged = NSMutableAttributedString(attributedString: prevAttr)
		let joinCaretUTF16 = merged.length
		merged.append(currAttr)
		let fullMergeSnapshot = NSAttributedString(attributedString: merged)
		prev.text = merged.string
		pendingRichByLineId[prev.id] = merged
		displayAttrCacheByLineId[prev.id] = DisplayAttrCacheEntry(fingerprint: fingerprintForDisplay(line: prev), attr: merged)
		prev.modifiedAt = Date()
		visibleLines[idx - 1] = prev
		visibleLines.remove(at: idx)
		pendingRichByLineId.removeValue(forKey: curr.id)
		displayAttrCacheByLineId.removeValue(forKey: curr.id)
		let mergedIndex = idx - 1
		let splitFocus = handleAttributedMultilineSplit(at: mergedIndex, using: fullMergeSnapshot)
		updateTotalsAndBlocks()
		scheduleSave()
		if let splitFocus {
			if let mapped = mapGlobalCaretAfterNewlineSplit(mergedLineStartIndex: mergedIndex, fullMerge: fullMergeSnapshot, globalCaretUTF16: joinCaretUTF16) {
				return mapped
			}
			return splitFocus
		}
		guard mergedIndex < visibleLines.count else { return nil }
		let row = visibleLines[mergedIndex]
		let maxCaret = (row.text as NSString).length
		return (row.id, min(joinCaretUTF16, maxCaret))
	}

	func deleteEmptyLineIfNeeded(id: UUID) {
		// 対象行のテキストが本当に空か判定するため、pending を確定させる。
		flushPendingVisibleUpdates()
		guard visibleLines.count > 1, let idx = visibleLines.firstIndex(where: { $0.id == id }) else { return }
		guard visibleLines[idx].text.isEmpty else { return }
		let isLast = idx == visibleLines.count - 1
		if !isLast {
			recordUndoIfNeeded(kind: .structural, focusedLineId: id, caretUTF16: 0)
			visibleLines.remove(at: idx)
			updateTotalsAndBlocks()
			scheduleSave()
		}
	}

	private func updateTotalsAndBlocks() {
		let endGlobal = globalLineOffset + visibleLines.count
		totalPersistedLines = max(totalPersistedLines, endGlobal)
		loadedBlockStart = globalLineOffset / linesPerBlock
		loadedBlockEnd = (globalLineOffset + visibleLines.count - 1) / linesPerBlock
	}

	private func scheduleSave() {
		saveTask?.cancel()
		saveTask = Task { [weak self] in
			// `try?` で CancellationError を飲むと、キャンセルされた古いタスクまで `flushToDisk()` に進み、
			// しかも sleep が即復帰する関係で「打鍵ごとに即時 flush が積み上がる」挙動になる。
			// flushToDisk は内部で複数 await を挟むため MainActor リエントラントで多重 in-flight になり、
			// それぞれが visibleLines + ディスク末尾サフィックス全行を保持してメモリが破綻する。
			// ここでは Task.sleep の throw をそのまま伝播させて、キャンセル時は即座にタスクを終わらせる。
			do {
				try await Task.sleep(nanoseconds: 400_000_000)
			} catch {
				return
			}
			// sleep 完了後に別経路からキャンセルされていた場合も、念のため再チェックする。
			if Task.isCancelled { return }
			await self?.flushToDisk()
		}
	}

	private func mergeFullDocumentByLoadingAll() -> [MemoLine] {
		// 重要: 可視範囲で行の挿入/削除が起きると、以降のグローバル行がシフトする。
		// 旧実装の「ブロック単位で見えている範囲だけ差し替え」だと、未ロード領域がディスクの旧配置のまま残り、
		// 消したはずの空行が“復活”するなどの症状が出る。
		//
		// そこで、ディスク上の全行をベースに「ロードしているブロック範囲」を subrange 置換し、
		// visibleLines の増減（行の挿入/削除）を後続へ正しく反映させる。

		let (savedLPB, savedTotal) = persistence.loadIndex()
		let lpb = savedLPB > 0 ? savedLPB : linesPerBlock
		let diskTotal = max(0, savedTotal)

		var base: [MemoLine] = []
		if diskTotal > 0, lpb > 0 {
			base = persistence.loadAllLines(linesPerBlock: lpb, totalFromIndex: diskTotal)
		}

		if base.count < diskTotal {
			for _ in base.count ..< diskTotal {
				base.append(MemoLine())
			}
		}

		let blockSpan = max(1, loadedBlockEnd - loadedBlockStart + 1)
		let loadedDiskWindowMax = blockSpan * linesPerBlock
		let loadedDiskWindowCount = min(max(0, diskTotal - globalLineOffset), loadedDiskWindowMax)

		if globalLineOffset > base.count {
			for _ in base.count ..< globalLineOffset {
				base.append(MemoLine())
			}
		}

		let start = max(0, min(globalLineOffset, base.count))
		let end = max(start, min(start + loadedDiskWindowCount, base.count))
		base.replaceSubrange(start ..< end, with: visibleLines)
		return base
	}

	/// `mergeFullDocumentByLoadingAll()` と同じ論理結果になるよう、ディスクのサフィックスだけを読み込んで「保存対象の tail」を作る。
	/// - Returns: `prefixCount` はグローバル行の先頭側（ディスク未読）行数。返る `tail` は `prefixCount` からの連続配列。
	/// - Important: ディスク読み込みとデコードをバックグラウンドに逃がした async 版。flush 経路以外からは呼ばない想定。
	private func buildMergedTailForStorageAsync() async -> (prefixCount: Int, tail: [MemoLine], storageLinesPerBlock: Int) {
		let (savedLPB, savedTotal) = await persistence.loadIndexAsync()
		let lpb = savedLPB > 0 ? savedLPB : linesPerBlock
		let diskTotal = max(0, savedTotal)

		// ディスクが可視範囲の開始より短い場合は、旧経路へフォールバック（現状このケースはほぼ起きない想定）。
		guard diskTotal >= globalLineOffset else {
			let merged = mergeFullDocumentByLoadingAll()
			return (prefixCount: 0, tail: merged, storageLinesPerBlock: lpb)
		}

		let blockSpan = max(1, loadedBlockEnd - loadedBlockStart + 1)
		let loadedDiskWindowMax = blockSpan * linesPerBlock
		let loadedDiskWindowCount = min(max(0, diskTotal - globalLineOffset), loadedDiskWindowMax)

		let suffixStart = globalLineOffset + loadedDiskWindowCount
		let diskSuffix: [MemoLine] = await {
			guard suffixStart < diskTotal else { return [] }
			return await persistence.loadLinesFromGlobalIndexToEndAsync(
				startGlobalIndex: suffixStart,
				linesPerBlock: lpb,
				totalLines: diskTotal
			)
		}()

		var tail = visibleLines
		if !diskSuffix.isEmpty {
			tail.append(contentsOf: diskSuffix)
		}
		return (prefixCount: globalLineOffset, tail: tail, storageLinesPerBlock: lpb)
	}

	/// 永続化時は末尾の空行パディングを落とし、再起動で増殖しないようにする。
	private func normalizedDocumentForStorage(_ lines: [MemoLine]) -> [MemoLine] {
		var result = lines
		while let last = result.last, isEffectivelyEmptyLineText(last.text) {
			result.removeLast()
		}
		return result
	}

	/// 前回 undo スタックをディスクへ書き出した時刻。
	/// 本文保存 (`flushToDisk`) は 400ms ごとに起きるが、undo スタックの JSON エンコードは
	/// スタックが育つほどメインを長く占有する。履歴が失われるのは再起動前の最大このウィンドウ分だけなので、
	/// 数秒単位に間引いて体感ラグを避ける。
	@ObservationIgnored private var lastUndoStackPersistAt: Date?
	/// undo スタック書き出しの最小間隔（秒）。
	private let undoStackPersistMinInterval: TimeInterval = 4.0

	/// `flushToDisk()` が現在走っているかどうか。内部に複数の `await` を挟むため、
	/// 同じ MainActor 上でリエントラントに別インスタンスが始まりうる。複数 in-flight は
	/// それぞれが `visibleLines + ディスク末尾サフィックス` の大きな一時配列を保持するため、
	/// 連続入力時にメモリを数倍単位で押し上げ、iOS のメモリ超過 kill を招く原因になる。
	@ObservationIgnored private var isFlushingToDisk: Bool = false
	/// flushToDisk 実行中に次の保存要求が来たかどうか。完了後に 1 回だけ再スケジュールする。
	@ObservationIgnored private var pendingFlushAfterCurrent: Bool = false

	/// 最後に成功した flush で書き出した可視行数と総行数。
	/// 次の flush でこれらが変わっていなければ「行数に変化がない純粋な入力」と判断でき、
	/// ディスクのサフィックスをロードし直さずに可視ブロックだけを書き出すファストパスに入れる。
	/// 画像などを含む大きなドキュメントでは、1 回の flush で全サフィックスを `[MemoLine]` として
	/// メモリに展開する挙動が OOM の主因になりうるので、できる限りこの経路を通したい。
	@ObservationIgnored private var lastFlushedVisibleCount: Int = -1
	@ObservationIgnored private var lastFlushedTotalPersistedLines: Int = -1

	private func flushToDisk() async {
		// 既に別の flushToDisk が走っている間に呼ばれたら、今回はスキップし、
		// 現行の flush 完了後にまとめて 1 回だけ再スケジュールする。
		// こうすることで MainActor リエントラント時の重畳メモリ使用を回避できる。
		if isFlushingToDisk {
			pendingFlushAfterCurrent = true
			return
		}
		isFlushingToDisk = true
		defer {
			isFlushingToDisk = false
			if pendingFlushAfterCurrent {
				pendingFlushAfterCurrent = false
				scheduleSave()
			}
		}
		// ホットパスで積んだ行テキスト／更新時刻をまず `visibleLines` へ反映してから保存に進む。
		flushPendingVisibleUpdates()
		// 入力中に溜めた attributed を、ここでまとめてエンコードして永続化データへ反映する（バックグラウンド）。
		let pendingSnapshot = pendingRichByLineId
		let payloads: [UUID: (rtf: Data?, archive: Data?)] = await Task.detached(priority: .utility) {
			var out: [UUID: (rtf: Data?, archive: Data?)] = [:]
			out.reserveCapacity(pendingSnapshot.count)
			for (id, attr) in pendingSnapshot {
				out[id] = MemoRichTextEncoding.persistPayload(from: attr)
			}
			return out
		}.value

		if !payloads.isEmpty {
			// `visibleLines[i].xxx = ...` を行ごとに走らせると `@Observable` の invalidate が行数ぶん重なり、
			// SwiftUI に「この flush で N 回変わった」ように見えて body 再評価コストが嵩む。
			// ローカル配列に反映してから 1 回だけ `visibleLines` へ代入すれば invalidate は 1 回で済む。
			var updated = visibleLines
			var mutated = false
			for i in updated.indices {
				let id = updated[i].id
				guard let p = payloads[id] else { continue }
				if updated[i].richTextRTF != p.rtf {
					updated[i].richTextRTF = p.rtf
					mutated = true
				}
				if updated[i].richTextArchive != p.archive {
					updated[i].richTextArchive = p.archive
					mutated = true
				}
			}
			if mutated {
				visibleLines = updated
			}
			for id in payloads.keys {
				pendingRichByLineId.removeValue(forKey: id)
			}
		}

		// === ファストパス: 行数が変わっていない純粋な編集中はサフィックスに触れない ===
		//
		// 直前の flush 以降に `visibleLines` の行数も `totalPersistedLines` も変わっていなければ、
		// サフィックス（可視範囲より後ろのブロック）はディスク上でバイト列ごと既に正しい状態なので、
		// 読み出して書き戻す必要はまったくない。大きなドキュメント（特に画像添付を含むもの）では、
		// サフィックスの `[MemoLine]` への全展開が 1 回で数十〜数百 MB になり OOM の主因になる。
		// 末尾空行だけのトリム結果なら permanent change にはならないので、末尾空行の有無でも分岐する。
		let trailingEmptyCount = visibleLines.reversed().prefix(while: { isEffectivelyEmptyLineText($0.text) }).count
		let canUseFastPath: Bool = {
			guard lastFlushedVisibleCount >= 0,
			      lastFlushedTotalPersistedLines >= 0 else { return false }
			guard visibleLines.count == lastFlushedVisibleCount else { return false }
			guard totalPersistedLines == lastFlushedTotalPersistedLines else { return false }
			// 末尾空行トリムによって書き出す長さが変わるケースはファストパス対象外にする。
			// （`normalizedDocumentForStorage` が後ろを削ると loaded 外のブロックにも影響するため）
			guard trailingEmptyCount == 0 else { return false }
			return true
		}()

		if canUseFastPath {
			// 可視ブロックだけを書き出す。`tail = visibleLines` で十分。
			await persistence.saveVisibleBlocksOnlyAsync(
				startBlock: loadedBlockStart,
				linesFromStartBlock: visibleLines,
				linesPerBlock: linesPerBlock
			)
			// totalPersistedLines / lastFlushed* は変わっていないので更新不要。
			updateTotalsAndBlocks()
		} else {
			let (prefixCount, tailBeforeTrim, _) = await buildMergedTailForStorageAsync()
			let tail = normalizedDocumentForStorage(tailBeforeTrim)
			let computedTotal = prefixCount + tail.count
			totalPersistedLines = computedTotal

			// 先頭側ブロックは触らず、読み込み済み開始ブロックから末尾だけ上書きする。
			await persistence.saveBlocksFromBlockIndexAsync(
				startBlock: loadedBlockStart,
				linesFromStartBlock: tail,
				linesPerBlock: linesPerBlock,
				totalLines: computedTotal
			)
			// save が正常終了すれば index.json の内容は `computedTotal` と一致している。
			// `loadIndex()` を毎回叩くのは同期 JSON デコード分コストがかかるだけなので、冗長な読み戻しは省く。
			totalPersistedLines = computedTotal
			updateTotalsAndBlocks()
			// 次回ファストパス判定のためのベースラインを更新する。
			// ディスク上の総行数との一致を保つため、`updateTotalsAndBlocks` の max() による上書きを避け、
			// 今回書き込んだ `computedTotal` をそのまま記録する。
			lastFlushedVisibleCount = visibleLines.count
			lastFlushedTotalPersistedLines = computedTotal
		}
		// undo スタックは debounce より長い周期で書き出す。連続入力中は最初の 1 回以降の
		// encode をスキップでき、メインブロックの原因になりやすい最大 80 件 × visibleLines
		// の JSON エンコードを毎 400ms 走らせずに済む。
		let now = Date()
		let shouldPersistUndo: Bool = {
			guard let last = lastUndoStackPersistAt else { return true }
			return now.timeIntervalSince(last) >= undoStackPersistMinInterval
		}()
		if shouldPersistUndo {
			lastUndoStackPersistAt = now
			await undoManager.saveToDiskAsync(at: persistence.undoStackURL)
		}
		await syncCoordinator?.memoDidFlushToDisk(persistence: persistence, linesPerBlock: linesPerBlock, totalLines: totalPersistedLines)
	}

	func scheduleSearchHitRefresh() {
		searchDebounceTask?.cancel()
		searchDebounceTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 280_000_000)
			guard !Task.isCancelled else { return }
			refreshSearchHits()
		}
	}

	func refreshSearchHits() {
		let kw = searchKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !kw.isEmpty else {
			searchHitContexts = []
			searchMessage = nil
			searchHitGlobalLineIndexSet = []
			return
		}
		let (lpb, total) = persistence.loadIndex()
		guard lpb > 0, total > 0 else {
			searchHitContexts = []
			searchMessage = "No data"
			searchHitGlobalLineIndexSet = []
			return
		}
		searchHitContexts = persistence.searchKeywordLineContexts(
			keyword: kw,
			linesPerBlock: lpb,
			totalLines: total,
			options: .caseInsensitive
		)
		searchMessage = searchHitContexts.isEmpty ? "No matches" : "\(searchHitContexts.count) match\(searchHitContexts.count == 1 ? "" : "es")"
		searchHitGlobalLineIndexSet = Set(searchHitContexts.map(\.globalLineIndex))
	}

	func selectSearchHit(_ hit: MemoSearchHitContext) {
		let kw = searchKeywordText.trimmingCharacters(in: .whitespacesAndNewlines)
		searchHighlightKeyword = kw.isEmpty ? nil : kw
		searchHighlightGlobalLineIndex = hit.globalLineIndex
		prepareScrollToGlobalLine(hit.globalLineIndex)
	}

	/// 編集開始などで「選択中の検索ヒット（濃いハイライト）」だけ解除する。
	/// キーワードが残っている限り、他のヒット箇所のハイライト表示は維持する。
	func clearSearchSelectionHighlight() {
		searchHighlightGlobalLineIndex = nil
	}

	/// 検索結果のグローバル行インデックスへ移動（必要ならブロックを読み込む）
	func prepareScrollToGlobalLine(_ globalIndex: Int) {
		guard linesPerBlock > 0, totalPersistedLines > 0 else { return }
		let bc = max(1, blockCount(forTotalLines: totalPersistedLines))
		let targetBlock = min(max(0, globalIndex / linesPerBlock), bc - 1)
		loadedBlockStart = targetBlock
		loadedBlockEnd = targetBlock
		globalLineOffset = targetBlock * linesPerBlock
		visibleLines = persistence.loadBlock(targetBlock)
		pruneDisplayCachesToVisible()
		scrollAnchorLineId = lineId(atGlobalIndex: globalIndex)
	}

	private func lineId(atGlobalIndex gi: Int) -> UUID? {
		let li = gi - globalLineOffset
		guard li >= 0, li < visibleLines.count else { return nil }
		return visibleLines[li].id
	}

	// MARK: - 選択モードの制御

	func enterSelectionMode() {
		guard !isSelectionMode else { return }
		isSelectionMode = true
		selectedLineIds = []
		dragSelectionMode = nil
		dragSelectionSnapshot = []
		dragFirstLineId = nil
	}

	func exitSelectionMode() {
		guard isSelectionMode else { return }
		isSelectionMode = false
		selectedLineIds = []
		dragSelectionMode = nil
		dragSelectionSnapshot = []
		dragFirstLineId = nil
	}

	/// タップによる 1 行トグル。
	func toggleLineSelection(_ id: UUID) {
		guard isSelectionMode else { return }
		if selectedLineIds.contains(id) {
			selectedLineIds.remove(id)
		} else {
			selectedLineIds.insert(id)
		}
	}

	/// ドラッグの始点: 最初に触れた行の選択状態でジェスチャ全体のモード（追加 / 解除）を確定し、
	/// その時点の選択集合をスナップショットとして保持する。以後の extend は常にこのスナップショットを基底に再計算する。
	func beginDragSelection(at id: UUID) {
		guard isSelectionMode else { return }
		dragSelectionSnapshot = selectedLineIds
		dragFirstLineId = id
		dragSelectionMode = dragSelectionSnapshot.contains(id) ? .removing : .adding
		applyDragRange(to: id)
	}

	/// ドラッグ中の追従: 「最初に触れた行」と「現在の指の位置の行」の範囲を都度計算し、
	/// スナップショットに対して union（追加モード）/ subtracting（解除モード）して上書きする。
	/// これによりなぞり戻しで範囲が縮むと、外れた行は基底状態へ戻る。
	func extendDragSelection(to id: UUID) {
		guard isSelectionMode, dragSelectionMode != nil, dragFirstLineId != nil else { return }
		applyDragRange(to: id)
	}

	private func applyDragRange(to currentId: UUID) {
		guard let firstId = dragFirstLineId, let mode = dragSelectionMode else { return }
		guard let firstIdx = visibleLines.firstIndex(where: { $0.id == firstId }),
			  let currIdx = visibleLines.firstIndex(where: { $0.id == currentId })
		else { return }
		let lo = min(firstIdx, currIdx)
		let hi = max(firstIdx, currIdx)
		let rangeIds = Set(visibleLines[lo...hi].map { $0.id })
		switch mode {
		case .adding:
			selectedLineIds = dragSelectionSnapshot.union(rangeIds)
		case .removing:
			selectedLineIds = dragSelectionSnapshot.subtracting(rangeIds)
		}
	}

	func endDragSelection() {
		dragSelectionMode = nil
		dragSelectionSnapshot = []
		dragFirstLineId = nil
	}

	// MARK: - 選択行のコピー・削除

	/// 選択中の行をコピー用に表示順で集める。
	private func selectedLinesInDisplayOrder() -> [MemoLine] {
		guard !selectedLineIds.isEmpty else { return [] }
		return visibleLines.filter { selectedLineIds.contains($0.id) }
	}

	/// 選択行をプレーンテキスト＋リッチテキスト（RTFD）としてペーストボードに書き込む。
	/// 画像が含まれる場合は RTFD 側で運ばれる。
	func copySelectedLines() {
		let lines = selectedLinesInDisplayOrder()
		guard !lines.isEmpty else { return }

		let plain = lines.map { $0.text }.joined(separator: "\n")

		let combined = NSMutableAttributedString()
		for (i, line) in lines.enumerated() {
			if i > 0 {
				combined.append(NSAttributedString(string: "\n", attributes: MemoRichTextEncoding.defaultTypingAttributes()))
			}
			combined.append(displayAttributed(for: line))
		}

		let fullRange = NSRange(location: 0, length: combined.length)
		let rtfdData: Data? = try? combined.data(
			from: fullRange,
			documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
		)

		var item: [String: Any] = [:]
		let plainKey = "public.utf8-plain-text"
		let rtfdKey = "com.apple.flat-rtfd"
		item[plainKey] = plain
		if let rtfdData, !rtfdData.isEmpty {
			item[rtfdKey] = rtfdData
		}
		UIPasteboard.general.setItems([item])
	}

	/// 選択行を削除して永続化にも反映。削除後もフォーカスは一切当てない（呼び出し側で管理）。
	func deleteSelectedLines() {
		// 削除処理は `visibleLines` を直接触るため、pending を先に確定させる。
		flushPendingVisibleUpdates()
		guard !selectedLineIds.isEmpty else { return }
		let removeIds = selectedLineIds
		let removedCount = visibleLines.filter { removeIds.contains($0.id) }.count
		guard removedCount > 0 else { return }

		// 先頭に近い選択行をアンカーにしておき、undo/redo の復元時に近傍へスクロールできるようにする。
		let anchorId = visibleLines.first(where: { removeIds.contains($0.id) })?.id
		recordUndoIfNeeded(kind: .structural, focusedLineId: anchorId, caretUTF16: 0)

		let wasViewingTail = isViewingDocumentTail()

		visibleLines.removeAll { removeIds.contains($0.id) }
		for id in removeIds {
			pendingRichByLineId.removeValue(forKey: id)
			displayAttrCacheByLineId.removeValue(forKey: id)
		}
		selectedLineIds = []
		dragSelectionMode = nil
		dragSelectionSnapshot = []
		dragFirstLineId = nil

		// 可視範囲の中で閉じる削除なので、既存の総行数を削除分だけ減らす。
		// 最終的な整合は flushToDisk が `buildMergedTailForStorage` で再計算する。
		totalPersistedLines = max(0, totalPersistedLines - removedCount)

		// 表示が末尾を含むなら、入力用の空行パターンを維持する（既存の最低 1 行ルール）。
		// 末尾を含まないなら、可視が空になっても文書全体としては空ではないのでそのまま。
		if wasViewingTail {
			normalizeTrailingEmptyLineIfViewingTail()
		}

		// block インデックスの再計算。`max()` で縮まない total はすでに上で縮めてある。
		let endGlobal = globalLineOffset + visibleLines.count
		totalPersistedLines = max(totalPersistedLines, endGlobal)
		loadedBlockStart = globalLineOffset / max(1, linesPerBlock)
		let last = max(globalLineOffset, endGlobal - 1)
		loadedBlockEnd = last / max(1, linesPerBlock)

		scheduleSave()
	}

	// MARK: - Undo / Redo

	var canUndo: Bool { undoManager.canUndo }
	var canRedo: Bool { undoManager.canRedo }

	/// 選択モードへの遷移・フォーカス喪失など、「ここで履歴を区切りたい」場面で View から呼ぶ。
	func breakUndoCoalescing() {
		undoManager.breakCoalescing()
	}

	/// View 側のテキスト更新ハンドラから現在のキャレットを通知する。
	/// 直後に起きるかもしれない別経路（画像挿入など）の undo 記録にも使える。
	func noteCaret(lineId: UUID, utf16: Int) {
		lastKnownCaret = (lineId, utf16)
	}

	/// undo を実行する。押す前の現在状態を redo スタックへ退避し、履歴の直前状態へ巻き戻す。
	/// 呼び出し側はフォーカスとキーボードを自分で片付ける想定。
	/// - Returns: 操作対象付近をスクロールで見せるための行 ID（該当行が無ければ nil）。
	func performUndo(currentFocus: (lineId: UUID, utf16: Int)?) -> UUID? {
		guard let peeked = undoManager.peekUndo else { return nil }
		// 現在状態は redo スタックへ渡す。そのアンカーは今から undo しようとしている編集地点
		//（＝ peeked のアンカー）にそろえて、redo 時も同じ付近に戻せるようにする。
		let current = makeCurrentSnapshot(
			focusedLineId: peeked.focusedLineId,
			caretUTF16: currentFocus?.utf16 ?? 0,
			anchorGlobalIndex: peeked.anchorGlobalIndex,
			kind: .structural
		)
		guard let target = undoManager.popUndo(current: current) else { return nil }
		applySnapshot(target)
		return scrollTargetLineId(for: target)
	}

	func performRedo(currentFocus: (lineId: UUID, utf16: Int)?) -> UUID? {
		guard let peeked = undoManager.peekRedo else { return nil }
		let current = makeCurrentSnapshot(
			focusedLineId: peeked.focusedLineId,
			caretUTF16: currentFocus?.utf16 ?? 0,
			anchorGlobalIndex: peeked.anchorGlobalIndex,
			kind: .structural
		)
		guard let target = undoManager.popRedo(current: current) else { return nil }
		applySnapshot(target)
		return scrollTargetLineId(for: target)
	}

	private func recordUndoIfNeeded(kind: MemoEditorUndoManager.SnapshotKind, focusedLineId: UUID?, caretUTF16: Int) {
		guard !isApplyingUndoRedo else { return }
		let anchorIndex = anchorGlobalIndexForCurrentState(focusedLineId: focusedLineId)
		undoManager.recordIfNeeded(kind: kind) { [self] in
			// 実際にスナップショットを作るのはコアレス境界を超えたときだけ。
			// その場合に限り、ホットパスで溜めた `visibleLines` への未反映パッチを確定し、
			// 「このバーストより前」の一貫した状態を履歴として残す。
			flushPendingVisibleUpdates()
			return makeCurrentSnapshot(
				focusedLineId: focusedLineId,
				caretUTF16: caretUTF16,
				anchorGlobalIndex: anchorIndex,
				kind: kind
			)
		}
	}

	/// `focusedLineId` が示す行のグローバルインデックス。
	/// 明示的にない場合は `visibleLines` の中央行を使う（選択モード削除などの保険）。
	private func anchorGlobalIndexForCurrentState(focusedLineId: UUID?) -> Int? {
		if let fid = focusedLineId,
		   let localIdx = visibleLines.firstIndex(where: { $0.id == fid }) {
			return globalLineOffset + localIdx
		}
		guard !visibleLines.isEmpty else { return nil }
		return globalLineOffset + visibleLines.count / 2
	}

	/// 直近アーカイブした (line id -> (attributed の ObjectIdentifier, 得られたバイト列)) のキャッシュ。
	/// `pendingRichByLineId` の値は「最新の編集があった行」だけ新しいインスタンスに差し替わるため、
	/// 変更のない行は同一インスタンスが残る。identity 比較で変わっていない行の再アーカイブをスキップする。
	@ObservationIgnored private var undoArchiveCache: [UUID: (attrId: ObjectIdentifier, archive: Data)] = [:]

	private func makeCurrentSnapshot(
		focusedLineId: UUID?,
		caretUTF16: Int,
		anchorGlobalIndex: Int?,
		kind: MemoEditorUndoManager.SnapshotKind
	) -> MemoEditorUndoManager.Snapshot {
		// スナップショットの `visibleLines` と `pendingRich` の内容を揃えるため、
		// 呼び出し経路にかかわらず pending パッチを確定させてから採取する。
		flushPendingVisibleUpdates()
		var pending: [MemoEditorUndoManager.PendingRichEntry] = []
		pending.reserveCapacity(pendingRichByLineId.count)
		var nextCache: [UUID: (attrId: ObjectIdentifier, archive: Data)] = [:]
		nextCache.reserveCapacity(pendingRichByLineId.count)
		for (id, attr) in pendingRichByLineId {
			let attrId = ObjectIdentifier(attr)
			if let cached = undoArchiveCache[id], cached.attrId == attrId {
				pending.append(MemoEditorUndoManager.PendingRichEntry(lineId: id, archive: cached.archive))
				nextCache[id] = cached
				continue
			}
			if let data = MemoRichTextEncoding.archivedAttributedData(from: attr) {
				pending.append(MemoEditorUndoManager.PendingRichEntry(lineId: id, archive: data))
				nextCache[id] = (attrId, data)
			}
		}
		undoArchiveCache = nextCache
		return MemoEditorUndoManager.Snapshot(
			visibleLines: visibleLines,
			pendingRich: pending,
			globalLineOffset: globalLineOffset,
			loadedBlockStart: loadedBlockStart,
			loadedBlockEnd: loadedBlockEnd,
			totalPersistedLines: totalPersistedLines,
			focusedLineId: focusedLineId,
			caretUTF16: caretUTF16,
			anchorGlobalIndex: anchorGlobalIndex,
			capturedAt: Date(),
			kind: kind
		)
	}

	/// スナップショット適用後、その「操作された部分」へ近い行の ID を返す。
	/// - 既存の `focusedLineId` が restored visibleLines にあればそれを優先。
	/// - 無ければ `anchorGlobalIndex` を使って近傍の行にフォールバック。
	private func scrollTargetLineId(for snap: MemoEditorUndoManager.Snapshot) -> UUID? {
		if let fid = snap.focusedLineId,
		   visibleLines.contains(where: { $0.id == fid }) {
			return fid
		}
		guard !visibleLines.isEmpty else { return nil }
		guard let global = snap.anchorGlobalIndex else {
			return visibleLines[visibleLines.count / 2].id
		}
		let local = global - globalLineOffset
		let clamped = max(0, min(local, visibleLines.count - 1))
		return visibleLines[clamped].id
	}

	private func applySnapshot(_ snap: MemoEditorUndoManager.Snapshot) {
		isApplyingUndoRedo = true
		defer { isApplyingUndoRedo = false }

		// undo/redo 境界では現在のホットパス遅延を捨てる（復元後の state に上書きする意味はないため）。
		pendingLinePatches.removeAll()
		idleFlushScheduled = false

		visibleLines = snap.visibleLines
		globalLineOffset = snap.globalLineOffset
		loadedBlockStart = snap.loadedBlockStart
		loadedBlockEnd = snap.loadedBlockEnd
		totalPersistedLines = snap.totalPersistedLines

		// pending attr を復元。archive を NSAttributedString に戻す。
		var restored: [UUID: NSAttributedString] = [:]
		for entry in snap.pendingRich {
			if let attr = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: entry.archive) {
				restored[entry.lineId] = attr
			}
		}
		pendingRichByLineId = restored

		// 表示キャッシュは作り直す（fingerprint で自動的に次回 displayAttributed で再生成される）。
		displayAttrCacheByLineId.removeAll()
		// 選択モード中に undo/redo は走らない想定だが、念のため選択をクリア。
		selectedLineIds = []
		searchHighlightGlobalLineIndex = nil

		// 次回 visibleLines が変わってもキャッシュが visible に追従するように整理。
		pruneDisplayCachesToVisible()

		// ディスクへ書き戻す。undo/redo 自体も scheduleSave で 400ms 後にまとめて保存される。
		scheduleSave()
	}

}
