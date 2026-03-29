# SmartNews to GoodNotes (iOS)

SmartNews などの共有シートから URL を受け取り、iOS アプリ内で履歴管理しつつ、表示中のページを PDF 化して GoodNotes などへ共有するためのサンプル実装です。

現在の実装は「本文抽出を最優先に自動整形する」よりも、「共有された URL をアプリ内ブラウザで確認し、表示中ページを PDF 化する」運用を中心にしています。

## 現在の仕様
- Share Extension は共有 URL を受け取り、App Group 経由で本体アプリへ保存する
- 本体アプリは共有履歴を一覧表示する
- 各履歴行から次ができる
  - `Arcで開く`
  - `アプリ内ブラウザ` で開く
- アプリ内ブラウザで表示中のページを PDF 化して共有シートへ渡せる
- SmartNews の中継 URL は検出して注意表示する
- 診断ログや内部メモは `Debug` ページへ分離している

## 重要な制約
- SmartNews の共有 URL は `l.smartnews.com` や `smartnews.com/article/...` の中継 URL になることがある
- SmartNews アプリの `Open in Browser` と完全に同じ URL 解決を、このアプリ内だけで再現するのは難しい
- そのため SmartNews 記事は次の運用が最も安定する
  1. SmartNews で `Open in Browser`
  2. Safari で元記事を開く
  3. Safari から共有
  4. 本アプリで PDF 化

## プロジェクト構成

### App ターゲット
- `App/SmartNewsToGoodNotesApp.swift`
- `App/ContentView.swift`
- `App/Info.plist`
- `App/SmartNewsToGoodNotes.entitlements`

### Share Extension ターゲット
- `ShareExtension/ShareViewController.swift`
- `ShareExtension/Info.plist`
- `ShareExtension/SmartNewsToGoodNotesShare.entitlements`

### Shared
- `Shared/Models.swift`
- `Shared/Diagnostics.swift`
- `Shared/PendingShareStore.swift`
- `Shared/ShareHistoryStore.swift`
- `Shared/ArticleExtractor.swift`
- `Shared/PDFGenerator.swift`
- `Shared/WebViewArticleLoader.swift`
- `Shared/WebPagePDFRenderer.swift`

### Xcode プロジェクト
- `SmartNewsToGoodNotes.xcodeproj`

## セットアップ

### 1. App Group を有効化
App 本体と Share Extension の両方で `App Groups` を追加し、同じ group ID を有効にしてください。

現在コードで使っている ID:
- `group.com.example.SmartNewsToGoodNotes`

対象ファイル:
- `App/SmartNewsToGoodNotes.entitlements`
- `ShareExtension/SmartNewsToGoodNotesShare.entitlements`
- `Shared/Diagnostics.swift`

### 2. Signing
両ターゲットで Team と Bundle Identifier を調整してください。

### 3. 外部依存
- 外部ライブラリ不要
- 標準フレームワークのみ

## 動作フロー

### SmartNews / 他アプリから共有
1. 記事 URL を共有
2. Share Extension が URL を App Group のキューへ保存
3. 本体アプリを開く
4. 本体アプリが未処理 URL を読み込む
5. アプリ内ブラウザでページ確認
6. `PDF化` を押して共有シートへ送る

### 履歴から再実行
1. 本体アプリの `共有履歴` を開く
2. 任意の URL を選ぶ
3. `Arcで開く` または `アプリ内ブラウザ` を使う
4. 必要なら PDF 化

## 実装ポイント

### `ShareViewController.swift`
- Share Extension の入口
- `public.url` / `public.plain-text` から URL を抽出
- `PendingShareStore` に保存

### `PendingShareStore.swift`
- 共有 URL の未処理キュー
- 以前は 1 件だけ保持していたが、現在は複数 URL を順に処理できる

### `ShareHistoryStore.swift`
- 共有履歴の保存
- URL とタイトル、共有日時を保持

### `ContentView.swift`
- メイン UI
- 共有履歴リスト
- アプリ内ブラウザ起動
- PDF 化開始
- `Debug` ページ表示

### `WebPagePDFRenderer.swift`
- `WKWebView` で表示中ページを PDF 化
- 広告、ヘッダー、サイドバーなどを軽く除去
- SmartNews / adjust / adj.st の中継 URL をある程度追跡

### `Diagnostics.swift`
- App Group 上の診断ログ保存
- `Debug` ページで表示

## UI 方針
- メイン画面は `共有履歴` を主役にする
- 履歴のタイトル右側に `Arcで開く` を配置
- ログや内部情報は `Debug` ページへ分離

## Arc について
- 現在の `Arcで開く` は外部ブラウザ起動です
- iOS 側で Arc Search を既定ブラウザにしている場合、Arc で開く運用を想定しています
- Arc 専用の公開 URL scheme を前提にした実装ではありません

## 既知の制約
- SmartNews の中継 URL は、元記事 URL に自動解決できない場合がある
- SmartNews の誘導ページをそのまま PDF 化すると、白紙や誘導ページ PDF になることがある
- Safari 共有前提のほうが安定する

## 今後の改善候補
- 履歴行から再 PDF 化をワンタップ化
- Arc 専用の安定した起動方法が確認できれば実装差し替え
- ブラウザ内で「現在ページを保存」だけでなく、印刷プレビューに近い調整 UI を追加
- 履歴の検索・ピン留め
