import SwiftUI
import UIKit
import WebKit

struct ContentView: View {
    @StateObject private var diagnostics = DiagnosticsViewModel()
    @StateObject private var history = ShareHistoryViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @State private var isProcessing = false
    @State private var statusMessage = "共有URLを待機中です。"
    @State private var processingError: String?
    @State private var shareItem: ShareItem?
    @State private var browserItem: BrowserItem?
    @State private var showingDebugPage = false
    @State private var lastImportedURL: String?

    private let pagePDFRenderer = WebPagePDFRenderer()

    var body: some View {
        NavigationStack {
            Group {
                if history.records.isEmpty {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView(
                            "共有履歴はまだありません",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("SmartNewsやSafariからURLを共有すると、ここに履歴が並びます。")
                        )
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("共有履歴はまだありません")
                                .font(.headline)
                            Text("SmartNewsやSafariからURLを共有すると、ここに履歴が並びます。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    List {
                        ForEach(history.records) { record in
                            SharedHistoryRow(
                                record: record,
                                openInArc: { openInArc(for: record.url) },
                                openInBrowserSheet: {
                                    if let url = URL(string: record.url) {
                                        browserItem = BrowserItem(url: url)
                                    }
                                }
                            )
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("共有履歴")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !history.records.isEmpty {
                        Button("消去", role: .destructive) {
                            history.clear()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Debug") {
                        showingDebugPage = true
                    }
                }
            }
            .onAppear {
                diagnostics.reload()
                history.reload()
                checkPendingImport()
            }
            .onChange(of: scenePhase) { newValue in
                if newValue == .active {
                    diagnostics.reload()
                    history.reload()
                    checkPendingImport()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                checkPendingImport()
            }
            .sheet(item: $shareItem) { item in
                ActivityViewController(items: [item.url])
            }
            .sheet(item: $browserItem) { item in
                BrowserSheet(
                    initialURL: item.url,
                    onGeneratePDF: { url, title in
                        Task {
                            await generatePDF(from: url, title: title)
                        }
                    }
                )
            }
            .sheet(isPresented: $showingDebugPage) {
                DebugPage(
                    statusMessage: statusMessage,
                    lastImportedURL: lastImportedURL,
                    pendingCount: PendingShareStore.shared.pendingCount,
                    diagnostics: diagnostics
                )
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
        guard !isProcessing, browserItem == nil, let articleURL = PendingShareStore.shared.consume() else {
            return
        }

        lastImportedURL = articleURL.absoluteString
        if isSmartNewsIntermediateURL(articleURL) {
            statusMessage = "SmartNews中継URLを受け取りました。Open in Browser 後に Safari 共有するのが最も確実です。"
        } else {
            statusMessage = "共有URLを受け取りました。表示中ページをPDF化できます。"
        }
        browserItem = BrowserItem(url: articleURL)
    }

    @MainActor
    private func generatePDF(from url: URL, title: String?) async {
        isProcessing = true
        processingError = nil
        statusMessage = "ページ全体をPDF化しています…"
        diagnostics.reload()
        DiagnosticStore.shared.log("INFO", "App started browser-based PDF flow for URL: \(url.absoluteString)")

        do {
            let renderedPage = try await pagePDFRenderer.renderPage(url: url, suggestedTitle: title ?? lastImportedURL)
            let resolvedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title : renderedPage.title)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolvedTitle, !resolvedTitle.isEmpty {
                ShareHistoryStore.shared.updateTitle(for: url, title: resolvedTitle)
            }

            statusMessage = "共有シートを開きます。"
            shareItem = ShareItem(url: renderedPage.pdfURL)
            DiagnosticStore.shared.log("INFO", "App generated PDF: \(renderedPage.pdfURL.lastPathComponent)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            processingError = message
            statusMessage = "処理に失敗しました。"
            DiagnosticStore.shared.log("ERROR", "App processing failed: \(message)")
        }

        diagnostics.reload()
        history.reload()
        isProcessing = false
        checkPendingImport()
    }

    private func openInArc(for rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        UIApplication.shared.open(url)
    }

    private func isSmartNewsIntermediateURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("smartnews.com") || host.contains("adj.st") || host.contains("adjust.com")
    }
}

#Preview {
    ContentView()
}

private struct ShareItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

private struct BrowserItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

private struct SharedHistoryRow: View {
    let record: SharedArticleRecord
    let openInArc: () -> Void
    let openInBrowserSheet: () -> Void

    private var isSmartNewsURL: Bool {
        let host = URL(string: record.url)?.host?.lowercased() ?? ""
        return host.contains("smartnews.com") || host.contains("adj.st") || host.contains("adjust.com")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                    if isSmartNewsURL {
                        Text("SmartNews中継URL")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("Arcで開く", action: openInArc)
                    .buttonStyle(.borderedProminent)
                    .font(.footnote.weight(.semibold))
            }

            Text(record.url)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            HStack {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("アプリ内ブラウザ") {
                    openInBrowserSheet()
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct BrowserSheet: View {
    let initialURL: URL
    let onGeneratePDF: (URL, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentURL: URL?
    @State private var currentTitle: String?
    @State private var reloadToken = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrowserWebView(
                    initialURL: initialURL,
                    reloadToken: reloadToken,
                    currentURL: $currentURL,
                    currentTitle: $currentTitle
                )

                Divider()

                VStack(spacing: 10) {
                    if let currentURL, isSmartNewsIntermediateURL(currentURL) {
                        SmartNewsInlineNotice()
                    }

                    Text(currentURL?.absoluteString ?? initialURL.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    HStack {
                        Button("再読込") {
                            reloadToken = UUID()
                        }
                        Spacer()
                        Button("PDF化") {
                            onGeneratePDF(currentURL ?? initialURL, currentTitle)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            .navigationTitle(currentTitle?.isEmpty == false ? currentTitle! : "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func isSmartNewsIntermediateURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("smartnews.com") || host.contains("adj.st") || host.contains("adjust.com")
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let initialURL: URL
    let reloadToken: UUID
    @Binding var currentURL: URL?
    @Binding var currentTitle: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BrowserWebView
        var lastReloadToken: UUID

        init(_ parent: BrowserWebView) {
            self.parent = parent
            self.lastReloadToken = parent.reloadToken
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.currentURL = webView.url
            parent.currentTitle = webView.title
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.currentURL = webView.url
            parent.currentTitle = webView.title
        }
    }
}

private struct SmartNewsInlineNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SmartNews中継ページ")
                .font(.headline)
            Text("このURLのままでは誘導ページになることがあります。SmartNews の `Open in Browser` 後に Safari 共有すると、PDF化が安定します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DebugPage: View {
    let statusMessage: String
    let lastImportedURL: String?
    let pendingCount: Int
    @ObservedObject var diagnostics: DiagnosticsViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("状態") {
                    Text(statusMessage)
                    if let lastImportedURL {
                        Text(lastImportedURL)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    Text("未処理URL: \(pendingCount)件")
                    if AppGroupConfig.identifier == nil {
                        Text("App Group未設定")
                            .foregroundStyle(.red)
                    }
                }

                Section("実装メモ") {
                    Text("Share ExtensionはURLをApp Groupにキュー保存")
                    Text("本体アプリでブラウザ表示し、表示中ページをPDF化")
                    Text("PDF化前に広告やナビゲーションを軽く除去")
                    Text("Arcで開くは外部ブラウザ起動です。Arc Searchを既定のブラウザにしているとArcで開きます。")
                }

                Section("診断ログ") {
                    ForEach(diagnostics.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(entry.level)  \(entry.timestamp.formatted(date: .omitted, time: .standard))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                    Button("ログを消去", role: .destructive) {
                        diagnostics.clear()
                    }
                }
            }
            .navigationTitle("Debug")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
}
