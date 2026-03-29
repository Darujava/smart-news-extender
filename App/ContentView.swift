import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var diagnostics = DiagnosticsViewModel()
    @StateObject private var history = ShareHistoryViewModel()
    @State private var isProcessing = false
    @State private var statusMessage = "SmartNewsの共有シートから記事を送ってください。"
    @State private var processingError: String?
    private struct ShareItem: Identifiable, Equatable {
        let id = UUID()
        let url: URL
    }
    @State private var shareItem: ShareItem?
    @State private var lastImportedURL: String?

    private let extractor = ArticleExtractor()
    private let pdfGenerator = PDFGenerator()
    private let webViewLoader = WebViewArticleLoader()
    private let pagePDFRenderer = WebPagePDFRenderer()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("SmartNews to GoodNotes")
                        .font(.largeTitle.bold())

                    Text("SmartNewsや他のニュースアプリの共有シートからURLを受け取り、記事を読みやすいPDFに整形してGoodNotesへ渡すためのアプリです。")
                        .font(.body)

                    VStack(alignment: .leading, spacing: 12) {
                        Label("SmartNewsで記事を開く", systemImage: "1.circle.fill")
                        Label("共有ボタンからこのアプリ拡張を選ぶ", systemImage: "2.circle.fill")
                        Label("PDF生成後にGoodNotesへ共有する", systemImage: "3.circle.fill")
                    }
                    .font(.headline)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("実装メモ")
                            .font(.title3.bold())
                        Text("・Share ExtensionはURLをApp Groupに保存")
                        Text("・本文抽出は軽量Readability + フォールバック方式")
                        Text("・PDFはA4サイズ相当で余白を広めに確保")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("現在の状態")
                            .font(.title3.bold())
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                        if !PendingShareStore.shared.isAvailable {
                            Text("App Group が未接続です。App と Share Extension の両方で `group.com.example.SmartNewsToGoodNotes` を有効にしてください。")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        if let lastImportedURL {
                            Text(lastImportedURL)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("共有履歴")
                                .font(.title3.bold())
                            Spacer()
                            if !history.records.isEmpty {
                                Button("消去", role: .destructive) {
                                    history.clear()
                                }
                            }
                        }

                        if history.records.isEmpty {
                            Text("共有されたURLはまだありません。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(history.records) { record in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.displayTitle)
                                        .font(.headline)
                                    Text(record.url)
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("診断ログ")
                                .font(.title3.bold())
                            Spacer()
                            Button("更新") {
                                diagnostics.reload()
                            }
                            Button("消去", role: .destructive) {
                                diagnostics.clear()
                            }
                        }

                        if diagnostics.entries.isEmpty {
                            Text("ログはまだありません。共有拡張を実行後に更新してください。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(diagnostics.entries) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(entry.level)  \(entry.timestamp.formatted(date: .omitted, time: .standard))")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(entry.message)
                                        .font(.footnote.monospaced())
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Home")
            .onAppear {
                diagnostics.reload()
                history.reload()
                checkPendingImport()
            }
            .sheet(item: $shareItem) { item in
                ActivityViewController(items: [item.url])
            }
            .alert("処理に失敗しました", isPresented: Binding(
                get: { processingError != nil },
                set: { if !$0 { processingError = nil } }
            )) {
                Button("閉じる", role: .cancel) { }
            } message: {
                Text(processingError ?? "")
            }
            .overlay {
                if isProcessing {
                    ZStack {
                        Color.black.opacity(0.18).ignoresSafeArea()
                        ProgressView(statusMessage)
                            .padding(24)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
        }
    }

    private func checkPendingImport() {
        guard !isProcessing, let articleURL = PendingShareStore.shared.consume() else {
            return
        }

        lastImportedURL = articleURL.absoluteString
        Task {
            await processArticle(from: articleURL)
        }
    }

    @MainActor
    private func processArticle(from url: URL) async {
        isProcessing = true
        processingError = nil
        statusMessage = "記事を取得しています…"
        diagnostics.reload()
        DiagnosticStore.shared.log("INFO", "App started processing shared URL: \(url.absoluteString)")

        do {
            let pdfURL: URL

            do {
                let article = try await extractor.extract(from: url)
                ShareHistoryStore.shared.updateTitle(for: url, title: article.title)
                statusMessage = "PDFを生成しています…"
                pdfURL = try await pdfGenerator.generatePDF(for: article)
            } catch {
                DiagnosticStore.shared.log("INFO", "Article extraction failed. Falling back to full-page PDF rendering.")
                statusMessage = "ページ全体をPDF化しています…"
                let renderedPage = try await pagePDFRenderer.renderPage(url: url, suggestedTitle: lastImportedURL)
                pdfURL = renderedPage.pdfURL
                if let title = renderedPage.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ShareHistoryStore.shared.updateTitle(for: url, title: title)
                }
            }

            statusMessage = "共有シートを開きます。"
            shareItem = ShareItem(url: pdfURL)
            DiagnosticStore.shared.log("INFO", "App generated PDF: \(pdfURL.lastPathComponent)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            processingError = message
            statusMessage = "処理に失敗しました。"
            DiagnosticStore.shared.log("ERROR", "App processing failed: \(message)")
        }

        diagnostics.reload()
        history.reload()
        isProcessing = false
    }
}

#Preview {
    ContentView()
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
