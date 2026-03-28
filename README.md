# SmartNews to GoodNotes (iOS)

このフォルダにはShare Extensionを含む最小実装のSwiftコードを配置しています。
Xcodeで `App` ターゲットと `Share Extension` ターゲットを作成し、以下のファイルを追加してターゲットに紐づけてください。

## 1) 依存関係
- 追加の外部ライブラリは不要
- 標準フレームワークのみで開けるようにしてあります

## 2) 追加するファイル
- App ターゲット
  - App/SmartNewsToGoodNotesApp.swift
  - App/ContentView.swift
  - App/Info.plist
  - Shared/Models.swift
  - Shared/ArticleExtractor.swift
  - Shared/PDFGenerator.swift

- Share Extension ターゲット
  - ShareExtension/ShareViewController.swift
  - ShareExtension/Info.plist
  - Shared/Models.swift
  - Shared/ArticleExtractor.swift
  - Shared/PDFGenerator.swift

## 3) Share Extension 設定
- Extension Point: Share Extension
- Principal Class: ShareViewController
- Activation Rule: Web URL (Max 1)
- `NSExtensionPrincipalClass` は `$(PRODUCT_MODULE_NAME).ShareViewController`
- Storyboardは不要

## 4) 実装内容
- `ArticleExtractor.swift`
  - URL先HTMLを取得
  - 正規表現ベースで不要要素を除去
  - タイトル、本文、画像URLを抽出
- `PDFGenerator.swift`
  - A4相当サイズでPDF化
  - 書き込み用の余白とガイド線を追加
- `ShareViewController.swift`
  - 共有URLを受け取る
  - 非同期で記事抽出とPDF生成を行う
  - `UIActivityViewController` でGoodNotes等へ共有

## 5) 動作
- SmartNewsで記事を開く → 共有 → 本アプリ拡張を選択
- PDFを生成して共有シートを表示

## 6) 今後の拡張候補
- App Groupを使ってホストアプリ側に履歴を保存
- `WKWebView` の `createPDF` と抽出PDFを切り替えられるようにする
- サイトごとの抽出ルールを追加して精度を上げる

## 7) 注意
- スクレイピングは対象サイトの利用規約に従ってください
