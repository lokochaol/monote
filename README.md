# Monote

縦スクロール中心の長文メモ／ジャーナル向け **iOS アプリ** です。1 行ずつ `UITextView` で編集し、ブロック単位で JSON に永続化します。データは端末ローカルの `Documents` に保存します。

## 概要

- **編集体験**: SwiftUI の `ScrollView` / `LazyVStack` と UIKit のテキストビューを組み合わせ、フォーカス行・キーボード・無限スクロールに合わせたスクロール制御。
- **データ**: 本文は `block_*.json` と `index.json`、画像などは `attachments/` に分割保存。リッチテキストは独自エンコード（RTF・アーカイブ・プレーンのフォールバック）で復元。
- **保存先**: 端末ローカルの `Documents/memo_blocks` のみ。クラウド同期は行いません。
- **その他**: リンク用チップ、SVG 埋め込み、カメラからの添付、Undo スタック、検索 UI など（実装は `scroll/` 配下を参照）。

## 技術スタック

| 区分 | 内容 |
|------|------|
| 言語・ランタイム | Swift 5、Swift 6 系の並行性オプション（例: `MainActor` 既定隔離） |
| UI | **SwiftUI**（`NavigationStack`、シート等）＋ **UIKit**（`UITextView`、一部 `UIViewController`） |
| 永続化 | `FileManager`、JSON ブロック、`UserDefaults`（設定フラグ） |
| パッケージ | **Swift Package Manager**。主な依存は [SVGKit](https://github.com/SVGKit/SVGKit)（SVG の表示・挿入）。解決結果は `Package.resolved` に固定。 |
| ログ・計測 | `os`（`Logger` / Signpost）、依存経由で **swift-log** / **CocoaLumberjack** |
| その他 | **Combine**、`async` / `await`、カスタム Undo、添付ストア抽象化 |

対象 **SDK / デプロイメント** は Xcode プロジェクトの `IPHONEOS_DEPLOYMENT_TARGET` に従います（新しい iOS 向け API を前提にした構成です）。

## ビルド

1. **Xcode** で `scroll.xcodeproj` を開く。
2. ルートの `LocalOverrides.xcconfig.example` を `LocalOverrides.xcconfig` にコピーし、**Apple Developer Team ID** を設定する（`DEVELOPMENT_TEAM`）。このファイルは `.gitignore` 済みでリポジトリに含めません。
3. 署名は自分のチーム用のバンドル ID に合わせて調整する必要があります。公開クローンでは `PRODUCT_BUNDLE_IDENTIFIER` が作者環境向けのままの場合があります。

```bash
cp LocalOverrides.xcconfig.example LocalOverrides.xcconfig
# エディタで DEVELOPMENT_TEAM を編集
```

コマンドラインからのビルド例:

```bash
xcodebuild -scheme scroll -destination 'generic/platform=iOS Simulator' build
```

## リポジトリ構成（抜粋）

| パス | 説明 |
|------|------|
| `scroll/` | アプリソース（エディタ、永続化等） |
| `scroll.xcodeproj/` | Xcode プロジェクト・SPM ワークスペース共有データ |
| `Info.plist` | バンドル設定 |
| `Base.xcconfig` | プロジェクト共通の xcconfig（`LocalOverrides` を任意インクルード） |
| `docs/` | ポリシー・サポート用 HTML など |
