import Foundation
import WebKit

@MainActor
final class WebPagePDFRenderer: NSObject {
    struct RenderedPage {
        let pdfURL: URL
        let title: String?
    }

    private var continuation: CheckedContinuation<URL, Error>?
    private var webView: WKWebView?
    private var containerView: UIView?
    private var outputURL: URL?
    private var remainingFollowCount = 2
    private var isFollowingRedirect = false

    func render(url: URL, suggestedTitle: String? = nil) async throws -> URL {
        try await renderPage(url: url, suggestedTitle: suggestedTitle).pdfURL
    }

    func renderPage(url: URL, suggestedTitle: String? = nil) async throws -> RenderedPage {
        let normalizedURL = normalizeRedirectURL(url) ?? url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let initialFrame = CGRect(x: 0, y: 0, width: 794, height: 1123)
        let containerView = UIView(frame: initialFrame)
        containerView.isHidden = true

        let webView = WKWebView(frame: initialFrame, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        containerView.addSubview(webView)

        self.webView = webView
        self.containerView = containerView
        self.remainingFollowCount = 2
        self.isFollowingRedirect = false
        self.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeFilename(suggestedTitle ?? "article"))
            .appendingPathExtension("pdf")

        let pdfURL = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            DiagnosticStore.shared.log("INFO", "Full-page PDF rendering started for URL: \(url.absoluteString)")
            if normalizedURL != url {
                DiagnosticStore.shared.log("INFO", "Full-page PDF normalized URL: \(normalizedURL.absoluteString)")
            }
            webView.load(URLRequest(url: normalizedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }

        let titleValue = try? await webView.evaluateJavaScriptAsync("document.title")
        return RenderedPage(pdfURL: pdfURL, title: titleValue as? String)
    }

    private func finish(with result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        self.webView?.navigationDelegate = nil
        self.webView = nil
        self.containerView = nil
        self.outputURL = nil
        continuation.resume(with: result)
    }

    private func inspectAndContinue(on webView: WKWebView) {
        let inspectionScript = """
        (() => {
          const text = (document.body?.innerText || '').trim();
          const html = document.documentElement ? document.documentElement.outerHTML : '';
          const links = Array.from(document.querySelectorAll('a[href]'))
            .map(a => a.href || '')
            .filter(Boolean);
          return {
            title: document.title || '',
            text,
            html,
            links
          };
        })();
        """

        webView.evaluateJavaScript(inspectionScript) { [weak self] result, _ in
            guard let self else { return }
            let currentURL = webView.url

            if let payload = result as? [String: Any],
               let currentURL,
               self.shouldFollowPublisherPage(payload: payload, currentURL: currentURL),
               let nextURL = self.publisherURL(from: payload, currentURL: currentURL),
               self.remainingFollowCount > 0 {
                self.remainingFollowCount -= 1
                self.isFollowingRedirect = true
                DiagnosticStore.shared.log("INFO", "Following publisher page for PDF: \(nextURL.absoluteString)")
                webView.load(URLRequest(url: nextURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
                return
            }

            self.cleanupPageAndRender(webView)
        }
    }

    private func cleanupPageAndRender(_ webView: WKWebView) {
        let cleanupScript = """
        (() => {
          const removeSelectors = [
            'header', 'nav', 'footer', 'aside', 'iframe',
            '[role="banner"]', '[role="navigation"]', '[role="complementary"]',
            '.ad', '.ads', '.advertisement', '.promo', '.recommend', '.recommended',
            '.related', '.share', '.sharing', '.social', '.cookie', '.cookies',
            '.comments', '.comment', '.sidebar', '.rail', '.ranking', '.breadcrumb',
            '#header', '#footer', '#nav', '#sidebar'
          ];
          for (const selector of removeSelectors) {
            document.querySelectorAll(selector).forEach(node => {
              node.style.display = 'none';
              node.style.visibility = 'hidden';
              node.style.height = '0';
              node.style.overflow = 'hidden';
            });
          }

          const style = document.createElement('style');
          style.innerHTML = `
            @page { size: A4; margin: 22px; }
            html, body {
              background: #fff !important;
              color: #111 !important;
              font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif !important;
              line-height: 1.65 !important;
            }
            img, figure, video {
              max-width: 100% !important;
              height: auto !important;
              break-inside: avoid !important;
            }
            article, main, [role="main"], .article-body, .post-content, .entry-content {
              max-width: 760px !important;
              margin: 0 auto !important;
            }
          `;
          document.head.appendChild(style);

          const mainCandidate = document.querySelector('article, main, [role="main"], .article-body, .post-content, .entry-content, .story-body');
          if (mainCandidate && mainCandidate.innerText && mainCandidate.innerText.trim().length > 240) {
            document.body.innerHTML = '';
            const wrapper = document.createElement('div');
            wrapper.style.maxWidth = '760px';
            wrapper.style.margin = '0 auto';
            wrapper.appendChild(mainCandidate.cloneNode(true));
            document.body.appendChild(wrapper);
          }

          return (document.body?.innerText || '').trim().length;
        })();
        """

        webView.evaluateJavaScript(cleanupScript) { [weak self] result, error in
            guard let self else { return }

            if let error {
                DiagnosticStore.shared.log("ERROR", "Page cleanup before PDF failed: \(error.localizedDescription)")
            }
            if let textLength = result as? Int {
                DiagnosticStore.shared.log("INFO", "Cleaned page text length: \(textLength)")
            }

            Task { @MainActor in
                do {
                    try await self.waitForRenderablePage(on: webView)
                    try await self.createPDF(from: webView)
                } catch {
                    self.finish(with: .failure(error))
                }
            }
        }
    }

    private func createPDF(from webView: WKWebView) async throws {
        guard let outputURL else {
            throw ArticlePipelineError.pdfGenerationFailed
        }

        let heightValue = try await webView.evaluateJavaScriptAsync(
            "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, 1600)"
        )
        let contentHeight = (heightValue as? NSNumber)?.doubleValue ?? 1600
        let targetSize = CGSize(width: 794, height: contentHeight)
        containerView?.frame = CGRect(origin: .zero, size: targetSize)
        webView.frame = CGRect(origin: .zero, size: targetSize)
        webView.scrollView.frame = webView.bounds
        webView.scrollView.contentSize = targetSize
        webView.setNeedsLayout()
        webView.layoutIfNeeded()

        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: targetSize)

        let pdfData = try await webView.pdf(configuration: configuration)
        DiagnosticStore.shared.log("INFO", "Generated PDF data size: \(pdfData.count) bytes")
        try pdfData.write(to: outputURL, options: .atomicWrite)
        DiagnosticStore.shared.log("INFO", "Full-page PDF created: \(outputURL.lastPathComponent)")
        finish(with: .success(outputURL))
    }

    private func waitForRenderablePage(on webView: WKWebView) async throws {
        let readyState = try await webView.evaluateJavaScriptAsync("document.readyState") as? String ?? "unknown"
        let textLength = try await webView.evaluateJavaScriptAsync("(document.body && document.body.innerText ? document.body.innerText.trim().length : 0)") as? NSNumber
        let imageCount = try await webView.evaluateJavaScriptAsync("(document.images ? document.images.length : 0)") as? NSNumber
        DiagnosticStore.shared.log(
            "INFO",
            "Render wait snapshot: readyState=\(readyState), textLength=\(textLength?.intValue ?? 0), imageCount=\(imageCount?.intValue ?? 0)"
        )
        try await Task.sleep(nanoseconds: 1_200_000_000)
    }

    private func shouldFollowPublisherPage(payload: [String: Any], currentURL: URL) -> Bool {
        guard let host = currentURL.host?.lowercased(),
              isIntermediateHost(host) else {
            return false
        }

        let text = (payload["text"] as? String ?? "").lowercased()
        return text.contains("smartnews") || text.count < 600
    }

    private func publisherURL(from payload: [String: Any], currentURL: URL) -> URL? {
        if let redirectURL = normalizeRedirectURL(currentURL), redirectURL != currentURL {
            return redirectURL
        }

        let links = payload["links"] as? [String] ?? []
        for link in links {
            guard let url = URL(string: link),
                  url.scheme?.hasPrefix("http") == true,
                  let host = url.host?.lowercased() else {
                continue
            }

            if isIntermediateHost(host) {
                continue
            }

            if url == currentURL {
                continue
            }

            return url
        }

        if let html = payload["html"] as? String,
           let extractedURL = extractPublisherURL(fromHTML: html, currentURL: currentURL) {
            return extractedURL
        }

        return nil
    }

    private func isIntermediateHost(_ host: String) -> Bool {
        host.contains("smartnews.com") || host.contains("adjust.com") || host.contains("adj.st")
    }

    private func normalizeRedirectURL(_ url: URL) -> URL? {
        var visited = Set<String>()
        var current = url

        while visited.insert(current.absoluteString).inserted {
            guard let next = nestedRedirectURL(in: current), next != current else {
                break
            }
            current = next
        }

        return current == url ? nil : current
    }

    private func nestedRedirectURL(in url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let items = components.queryItems, !items.isEmpty else {
            return nil
        }

        let keys = [
            "adj_redirect_ios",
            "adj_redirect",
            "adj_redirect_android",
            "adj_redirect_macos",
            "url",
            "redirect",
            "redirect_url",
            "target",
            "target_url",
            "dest",
            "destination"
        ]

        for key in keys {
            if let value = items.first(where: { $0.name == key })?.value,
               let url = decodedURL(from: value) {
                return url
            }
        }

        for item in items {
            if let value = item.value, let url = decodedURL(from: value) {
                return url
            }
        }

        return nil
    }

    private func decodedURL(from rawValue: String) -> URL? {
        let candidates = [
            rawValue,
            rawValue.removingPercentEncoding ?? rawValue,
            (rawValue.removingPercentEncoding ?? rawValue).removingPercentEncoding ?? rawValue
        ]

        for candidate in candidates {
            if let url = URL(string: candidate), url.scheme?.hasPrefix("http") == true {
                return url
            }
        }

        return nil
    }

    private func extractPublisherURL(fromHTML html: String, currentURL: URL) -> URL? {
        let patterns = [
            "(?is)https?:\\\\?/\\\\?/[^\\\"'<>\\s]+",
            "(?is)https?://[^\\\"'<>\\s]+",
            "(?is)href=[\"'](https?://[^\"']+)[\"']",
            "(?is)content=[\"'](https?://[^\"']+)[\"']"
        ]

        var candidates: [URL] = []
        for pattern in patterns {
            for match in allCaptures(in: html, pattern: pattern) {
                let normalized = match
                    .replacingOccurrences(of: "\\/", with: "/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))

                if let url = decodedURL(from: normalized),
                   let host = url.host?.lowercased(),
                   !isIntermediateHost(host),
                   url != currentURL {
                    candidates.append(url)
                }
            }
        }

        let ranked = candidates
            .map { ($0, scorePublisherURL($0)) }
            .sorted { lhs, rhs in lhs.1 > rhs.1 }

        return ranked.first?.0
    }

    private func scorePublisherURL(_ url: URL) -> Int {
        let absolute = url.absoluteString.lowercased()
        var score = 0

        if let host = url.host?.lowercased() {
            if !isIntermediateHost(host) { score += 10 }
            if host.contains("nypost.com") { score += 8 }
        }
        if absolute.contains("article") { score += 2 }
        if absolute.contains("utm_") { score -= 1 }
        if absolute.contains("smartnews") { score -= 10 }
        if absolute.contains("app") { score -= 4 }

        return score
    }

    private func allCaptures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            let captureIndex = match.numberOfRanges > 1 ? 1 : 0
            guard let captureRange = Range(match.range(at: captureIndex), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }

    private func safeFilename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "article" : cleaned
    }
}

@MainActor
extension WebPagePDFRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isFollowingRedirect = false
        if let currentURL = webView.url {
            DiagnosticStore.shared.log("INFO", "PDF web view loaded URL: \(currentURL.absoluteString)")
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.inspectAndContinue(on: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if ignoreCancelledNavigation(error) { return }
        DiagnosticStore.shared.log("ERROR", "PDF web view navigation failed: \(error.localizedDescription)")
        finish(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if ignoreCancelledNavigation(error) { return }
        DiagnosticStore.shared.log("ERROR", "PDF web view provisional navigation failed: \(error.localizedDescription)")
        finish(with: .failure(error))
    }

    private func ignoreCancelledNavigation(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled, isFollowingRedirect {
            DiagnosticStore.shared.log("INFO", "Ignored expected navigation cancellation during redirect follow.")
            return true
        }
        return false
    }
}

private extension WKWebView {
    func evaluateJavaScriptAsync(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }
}
#if DEBUG
import SwiftUI

private struct WebPagePDFRendererPreviewView: View {
    @State private var urlString: String = "https://www.example.com"
    @State private var status: String = "未実行"
    @State private var pdfURL: URL?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WebPagePDFRenderer プレビュー").font(.headline)
            TextField("URL を入力", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)

            HStack {
                Button(action: run) {
                    Label("PDF 生成", systemImage: "doc.richtext")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)

                if isRunning { ProgressView().progressViewStyle(.circular) }
            }

            Text("ステータス: \(status)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let pdfURL {
                Text("出力: \(pdfURL.lastPathComponent)")
                    .font(.caption)
                ShareLink(item: pdfURL) { Label("PDF を共有", systemImage: "square.and.arrow.up") }
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func run() {
        guard let url = URL(string: urlString) else {
            status = "URL が不正です"
            return
        }
        isRunning = true
        status = "生成中…"
        pdfURL = nil

        Task { @MainActor in
            let renderer = WebPagePDFRenderer()
            do {
                let result = try await renderer.renderPage(url: url)
                pdfURL = result.pdfURL
                status = "成功: \(result.title ?? "(無題)")"
            } catch {
                status = "失敗: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }
}

#Preview("WebPagePDFRenderer") {
    WebPagePDFRendererPreviewView()
}
#endif

