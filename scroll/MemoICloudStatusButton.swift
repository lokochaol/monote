//
//  MemoICloudStatusButton.swift
//  scroll
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 上部ツールバーに置く iCloud 同期インジケータ。
///
/// - 表示: 現在の `MemoICloudStatus` に応じて SF Symbol を切り替える。
/// - 操作: タップで設定シートを開き、その中で
///     1) アプリ側の「iCloud Drive で同期」トグル
///     2) iOS の設定アプリへの遷移ボタン
///     3) 診断情報と手動オペレーション（再マイグレーション・能動退避）
///   を提供する。
struct MemoICloudStatusButton: View {
	let status: MemoICloudStatus
	/// メモ本体のいずれかが iCloud 送受信中と OS が報告しているとき（ツールバーで回転表示）。
	let isTransferring: Bool
	/// 切り替え動作を駆動するクロージャ。`MemoEditorViewModel.toggleICloudSync` をそのまま橋渡しする想定。
	let onToggle: (Bool) async -> Void
	/// 設定シート用の診断情報取得 / 手動オペハンドラ。
	let onFetchDiagnostics: () async -> MemoStorageDiagnostics
	let onEvictUnused: () async -> Int

	@State private var showSheet = false

	var body: some View {
		Button { showSheet = true } label: {
			Image(systemName: symbolName)
				.symbolRenderingMode(.hierarchical)
				.font(.system(size: 17, weight: .medium))
				.foregroundStyle(tint)
				.symbolEffect(.rotate, options: .repeating, isActive: showsTransferAnimation)
				.accessibilityLabel(Text(accessibilityLabel))
				.accessibilityHint(Text("Open iCloud sync settings"))
		}
		.buttonStyle(.plain)
		.sheet(isPresented: $showSheet) {
			MemoICloudSettingsSheet(
				status: status,
				isTransferring: isTransferring,
				onToggle: onToggle,
				onFetchDiagnostics: onFetchDiagnostics,
				onEvictUnused: onEvictUnused,
				onClose: { showSheet = false }
			)
			.presentationDetents([.medium, .large])
			.presentationDragIndicator(.visible)
		}
	}

	// MARK: - 状態 → 見た目

	/// `.disabled` のときは転送フラグを無視（ローカル運用では意味が薄い）。
	private var showsTransferAnimation: Bool {
		isTransferring && (status == .synced || status == .unknown)
	}

	private var symbolName: String {
		if showsTransferAnimation { return "arrow.triangle.2.circlepath.icloud" }
		switch status {
		case .synced: return "icloud"
		case .disabled: return "icloud.slash"
		case .unknown: return "icloud"
		}
	}

	private var tint: Color {
		switch status {
		case .synced: return .accentColor
		case .disabled: return .secondary
		case .unknown: return .secondary.opacity(0.6)
		}
	}

	private var accessibilityLabel: String {
		if showsTransferAnimation { return "iCloud sync is active, transferring files" }
		switch status {
		case .synced: return "iCloud sync is on"
		case .disabled: return "iCloud sync is off"
		case .unknown: return "iCloud sync status is loading"
		}
	}
}

// MARK: - 設定シート

/// iCloud 同期のオン／オフ切り替えと、iOS 設定アプリへのショートカットを置いたシート。
///
/// - トグルを変えると `onToggle` が呼ばれ、`MemoBlockPersistence` がローカル ⇄ iCloud Drive で
///   ファイル移動を行う。所要時間はファイル数次第なので、その間はトグルを操作不能にする。
/// - 「Open iOS Settings」は `UIApplication.openSettingsURLString` で本アプリの設定ページに遷移。
///   そこから `Apple Account → iCloud → Apps Using iCloud` へ手動で進めば、当アプリ単位の
///   iCloud Drive 利用許可も切り替えられる（こちらは公開 API では deep link できないので導線だけ提供する）。
private struct MemoICloudSettingsSheet: View {
	let status: MemoICloudStatus
	let isTransferring: Bool
	let onToggle: (Bool) async -> Void
	let onFetchDiagnostics: () async -> MemoStorageDiagnostics
	let onEvictUnused: () async -> Int
	let onClose: () -> Void

	/// シートを開いた瞬間の設定値を初期値として持つ。以後は @State がソースオブトゥルース。
	@State private var isOn: Bool = MemoStorageRoot.prefersICloud
	/// 切り替え進行中。`true` の間はトグルを disable して連打を弾く。
	@State private var isApplying: Bool = false

	@State private var diagnostics: MemoStorageDiagnostics?
	@State private var lastEvictedCount: Int?

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Toggle(isOn: bindingToToggle) {
						Label {
							Text("iCloud Drive で同期")
						} icon: {
							Image(systemName: isOn ? "icloud" : "icloud.slash")
						}
					}
					.disabled(isApplying)
				} header: {
					Text("ストレージ")
				} footer: {
					Text(footerText)
				}

				diagnosticsSection

				Section {
					Button(action: openAppSettings) {
						Label("iOS の設定を開く", systemImage: "gear")
					}
				} footer: {
					Text("このアプリの iCloud のオン／オフは、設定アプリの Apple Account → iCloud から確認できます。")
				}
			}
			.navigationTitle("iCloud 同期")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button(action: onClose) { Text("完了") }
				}
			}
			.overlay(alignment: .center) {
				if isApplying {
					ProgressView()
						.controlSize(.large)
						.padding(20)
						.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
				}
			}
			.task { await refreshDiagnostics() }
		}
	}

	@ViewBuilder
	private var diagnosticsSection: some View {
		Section {
			if let d = diagnostics {
				if d.isUsingICloudRoot, isTransferring {
					HStack {
						Image(systemName: "arrow.triangle.2.circlepath.icloud")
							.symbolEffect(.rotate, options: .repeating, isActive: true)
							.foregroundStyle(.secondary)
						Text("iCloud と送受信中です")
							.foregroundStyle(.secondary)
					}
				}
				diagnosticsRow(label: "保存先", value: d.isUsingICloudRoot ? "iCloud" : "この iPhone")
				diagnosticsRow(label: "メモの合計", value: formatBytes(d.trackedTotalBytes))
				if d.isUsingICloudRoot, let u = d.iCloudUploadedBytes, let p = d.iCloudPendingBytes {
					diagnosticsRow(label: "クラウドに反映済み", value: formatBytes(u))
					diagnosticsRow(label: "iCloud未アップロードのデータ", value: formatBytes(p))
				} else if !d.isUsingICloudRoot {
					diagnosticsRow(label: "クラウド同期", value: "オフ（この端末のみ）")
				}
				if let evicted = lastEvictedCount {
					diagnosticsRow(label: "直前の退避", value: "\(evicted) 件を端末から退避")
				}
			} else {
				HStack {
					ProgressView().controlSize(.small)
					Text("読み込み中…").foregroundStyle(.secondary)
				}
			}

			Button {
				Task { @MainActor in
					await refreshDiagnostics()
				}
			} label: {
				Label("情報を更新", systemImage: "arrow.clockwise")
			}

			if diagnostics?.isUsingICloudRoot == true {
				Button {
					Task { @MainActor in
						isApplying = true
						lastEvictedCount = await onEvictUnused()
						await refreshDiagnostics()
						isApplying = false
					}
				} label: {
					Label("使っていない分を端末から退避", systemImage: "arrow.up.bin")
				}
				.disabled(isApplying)
			}
		} header: {
			Text("容量の目安")
		} footer: {
			Text("数値はおおよそです。送受信中は上部の雲アイコンが回転します。")
		}
	}

	private func diagnosticsRow(label: String, value: String) -> some View {
		HStack {
			Text(label)
			Spacer()
			Text(value).foregroundStyle(.secondary).monospacedDigit()
		}
	}

	private func refreshDiagnostics() async {
		diagnostics = await onFetchDiagnostics()
	}

	private func formatBytes(_ bytes: Int) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
	}

	/// `Toggle` から直接書き込まれる `Bool` バインディング。書き換え時に async コールバックを駆動する。
	/// `@State` を素直に Toggle に渡すと async な切り替え結果（成功 / 失敗）を反映できないため、
	/// カスタムバインディング経由で setter を奪い、apply 完了後に @State を最終値で上書きする。
	private var bindingToToggle: Binding<Bool> {
		Binding(
			get: { isOn },
			set: { newValue in
				isOn = newValue
				Task { @MainActor in
					isApplying = true
					await onToggle(newValue)
					// `prepareStorageRootIfNeeded` が `false` を返したら（iCloud 未サインイン等）、
					// ユーザの意図通りには切り替わらないので UI も実態に合わせて戻す。
					isOn = MemoStorageRoot.prefersICloud
					isApplying = false
				}
			}
		)
	}

	private var footerText: String {
		switch (isOn, status) {
		case (true, .synced):
			return "メモは iCloud Drive に保存され、サインイン中のすべての端末で共有されます。古いブロックは自動的に端末から退避され、デバイスのストレージを節約できます。"
		case (true, .disabled):
			return "iCloud Drive を使うように設定されていますが、現在は利用できません。サインイン状態と Apple Account 設定の iCloud Drive を確認してください。"
		case (true, .unknown):
			return "iCloud の状態を確認しています…"
		case (false, _):
			return "メモはこの端末にだけ保存されます。容量を空けたいときは iCloud 同期を有効にしてください。"
		}
	}

	private func openAppSettings() {
		#if canImport(UIKit)
		guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
		UIApplication.shared.open(url)
		#endif
	}
}
