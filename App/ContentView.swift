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
    @State private var searchText = ""

    private let pagePDFRenderer = WebPagePDFRenderer()

    private let accent = Color(red: 0.80, green: 0.35, blue: 0.12)
    private let accentDark = Color(red: 0.38, green: 0.14, blue: 0.05)
    private let backgroundTop = Color(red: 0.98, green: 0.95, blue: 0.92)
    private let backgroundBottom = Color(red: 0.92, green: 0.87, blue: 0.82)
    private let cardBackground = Color(red: 1.0, green: 0.995, blue: 0.99)
    private let primaryText = Color(red: 0.12, green: 0.09, blue: 0.08)
    private let secondaryText = Color(red: 0.29, green: 0.22, blue: 0.18)
    private let subtleBorder = Color(red: 0.86, green: 0.78, blue: 0.72)

    private var filteredRecords: [SharedArticleRecord] {
        let records = history.records
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }

        return records.filter { record in
            record.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
            record.url.localizedCaseInsensitiveContains(trimmed) ||
            record.domain.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var smartNewsCount: Int {
        history.records.filter { isSmartNewsIntermediateURLString($0.url) }.count
    }

    private var pinnedCount: Int {
        history.records.filter(\.isPinned).count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [backgroundTop, backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        StatusCard(
                            pendingCount: PendingShareStore.shared.pendingCount,
                            pinnedCount: pinnedCount,
                            smartNewsCount: smartNewsCount,
                            lastImportedURL: lastImportedURL,
                            accent: accent,
                            accentDark: accentDark
                        )

                        SearchField(
                            text: $searchText,
                            accent: accent,
                            cardBackground: cardBackground,
                            primaryText: primaryText,
                            secondaryText: secondaryText,
                            subtleBorder: subtleBorder
                        )

                        if filteredRecords.isEmpty {
                            EmptyHistoryCard(
                                accent: accent,
                                cardBackground: cardBackground,
                                primaryText: primaryText,
                                secondaryText: secondaryText
                            )
                        } else {
                            LazyVStack(spacing: 14) {
                                ForEach(filteredRecords) { record in
                                    HistoryCard(
                                        record: record,
                                        accent: accent,
                                        accentDark: accentDark,
                                        cardBackground: cardBackground,
                                        primaryText: primaryText,
                                        secondaryText: secondaryText,
                                        subtleBorder: subtleBorder,
                                        isSmartNewsURL: isSmartNewsIntermediateURLString(record.url),
                                        openInArc: { openInArc(for: record.url) },
                                        openInBrowserSheet: {
                                            if let url = URL(string: record.url) {
                                                browserItem = BrowserItem(url: url)
                                            }
                                        },
                                        pinToggle: {
                                            history.togglePin(record)
                                        },
                                        rerender: {
                                            if let url = URL(string: record.url) {
                                                Task {
                                                    await generatePDF(from: url, title: record.title)
                                                }
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("PDFix")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !history.records.isEmpty {
                        Button("消去", role: .destructive) {
                            history.clear()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingDebugPage = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                }
            }
            .tint(accent)
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
                    },
                    accent: accent,
                    cardBackground: cardBackground,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    subtleBorder: subtleBorder
                )
            }
            .sheet(isPresented: $showingDebugPage) {
                DebugPage(
                    statusMessage: statusMessage,
                    lastImportedURL: lastImportedURL,
                    pendingCount: PendingShareStore.shared.pendingCount,
                    diagnostics: diagnostics,
                    accent: accent,
                    primaryText: primaryText,
                    secondaryText: secondaryText
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
                        Color.black.opacity(0.24).ignoresSafeArea()
                        ProgressView(statusMessage)
                            .tint(accent)
                            .padding(24)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
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
            statusMessage = "SmartNews中継URLを受け取りました。Open in Browser 後に Safari 共有が最も確実です。"
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
        isSmartNewsIntermediateURLString(url.absoluteString)
    }

    private func isSmartNewsIntermediateURLString(_ rawURL: String) -> Bool {
        let host = URL(string: rawURL)?.host?.lowercased() ?? ""
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

private struct StatusCard: View {
    let pendingCount: Int
    let pinnedCount: Int
    let smartNewsCount: Int
    let lastImportedURL: String?
    let accent: Color
    let accentDark: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PDFix Workspace")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .textCase(.uppercase)
                        .tracking(1.1)
                    Text(pendingCount > 0 ? "新しい共有URLを処理できます" : "履歴からすぐ再実行できます")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
            }

            HStack(spacing: 12) {
                MetricPill(label: "Pending", value: "\(pendingCount)")
                MetricPill(label: "Pinned", value: "\(pinnedCount)")
                MetricPill(label: "Needs Browser", value: "\(smartNewsCount)")
            }

            if let lastImportedURL {
                Text(lastImportedURL)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
            }
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [accent, accentDark, Color.black.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: accent.opacity(0.32), radius: 28, y: 16)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.70))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SearchField: View {
    @Binding var text: String
    let accent: Color
    let cardBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let subtleBorder: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(accent)
            TextField("タイトルやドメインで検索", text: $text)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(secondaryText)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(subtleBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
    }
}

private struct EmptyHistoryCard: View {
    let accent: Color
    let cardBackground: Color
    let primaryText: Color
    let secondaryText: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(accent)
            Text("共有履歴はまだありません")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)
            Text("SmartNewsやSafariからURLを共有すると、ここにカード形式で並びます。")
                .font(.footnote)
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: accent.opacity(0.08), radius: 10, y: 4)
        .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
    }
}

private struct HistoryCard: View {
    let record: SharedArticleRecord
    let accent: Color
    let accentDark: Color
    let cardBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let subtleBorder: Color
    let isSmartNewsURL: Bool
    let openInArc: () -> Void
    let openInBrowserSheet: () -> Void
    let pinToggle: () -> Void
    let rerender: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if isSmartNewsURL {
                        Text("Needs Browser")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(accent.opacity(0.16), in: Capsule())
                    }

                    Text(record.displayTitle)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(primaryText)
                        .lineLimit(3)

                    Text(record.domain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Button(action: pinToggle) {
                        Image(systemName: record.isPinned ? "pin.fill" : "pin")
                            .font(.headline)
                    }
                    .foregroundStyle(record.isPinned ? accent : secondaryText)

                    Button("Arcで開く", action: openInArc)
                        .buttonStyle(.borderedProminent)
                        .tint(accentDark)
                        .font(.footnote.weight(.bold))
                }
            }

            Text(record.url)
                .font(.footnote.monospaced())
                .foregroundStyle(secondaryText)
                .lineLimit(2)
                .textSelection(.enabled)

            HStack {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                Spacer()
                Button("ブラウザ確認", action: openInBrowserSheet)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(primaryText)
                Button("再度PDF化", action: rerender)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent)
            }
        }
        .padding(18)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(subtleBorder, lineWidth: 1)
        )
        .shadow(color: accent.opacity(0.10), radius: 10, y: 4)
        .shadow(color: .black.opacity(0.10), radius: 24, y: 12)
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
    let accent: Color
    let cardBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let subtleBorder: Color

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
                        SmartNewsInlineNotice(
                            accent: accent,
                            primaryText: primaryText,
                            secondaryText: secondaryText
                        )
                    }

                    Text(currentURL?.absoluteString ?? initialURL.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundStyle(secondaryText)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    HStack {
                        Button("再読込") {
                            reloadToken = UUID()
                        }
                        .foregroundStyle(primaryText)
                        Spacer()
                        Button("PDF化") {
                            onGeneratePDF(currentURL ?? initialURL, currentTitle)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                    }
                }
                .padding()
                .background(cardBackground)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(subtleBorder.opacity(0.9))
                        .frame(height: 1)
                }
            }
            .navigationTitle(currentTitle?.isEmpty == false ? currentTitle! : "PDFix Browser")
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
    let accent: Color
    let primaryText: Color
    let secondaryText: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SmartNews中継ページ")
                .font(.headline.weight(.bold))
                .foregroundStyle(primaryText)
            Text("このURLのままでは誘導ページになることがあります。SmartNews の `Open in Browser` 後に Safari 共有すると、PDF化が安定します。")
                .font(.footnote)
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DebugPage: View {
    let statusMessage: String
    let lastImportedURL: String?
    let pendingCount: Int
    @ObservedObject var diagnostics: DiagnosticsViewModel
    let accent: Color
    let primaryText: Color
    let secondaryText: Color

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
                                .foregroundStyle(secondaryText)
                            Text(entry.message)
                                .font(.footnote.monospaced())
                                .foregroundStyle(primaryText)
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
            .tint(accent)
        }
    }
}
