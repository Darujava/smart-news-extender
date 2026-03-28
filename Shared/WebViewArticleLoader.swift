import Foundation
import WebKit

@MainActor
final class WebViewArticleLoader: NSObject {
    struct LoadedPage {
        let url: URL
        let html: String
    }

    private var continuation: CheckedContinuation<LoadedPage, Error>?
    private var webView: WKWebView?

    func load(url: URL) async throws -> LoadedPage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            DiagnosticStore.shared.log("INFO", "WKWebView fallback started for URL: \(url.absoluteString)")
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
    }

    private func finish(with result: Result<LoadedPage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        self.webView?.navigationDelegate = nil
        self.webView = nil
        continuation.resume(with: result)
    }
}

@MainActor
extension WebViewArticleLoader: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let currentURL = webView.url
        DiagnosticStore.shared.log("INFO", "WKWebView finished loading URL: \(currentURL?.absoluteString ?? "nil")")

        webView.evaluateJavaScript("document.documentElement.outerHTML.toString()") { [weak self] result, error in
            guard let self else { return }

            if let error {
                DiagnosticStore.shared.log("ERROR", "WKWebView JS evaluation failed: \(error.localizedDescription)")
                self.finish(with: .failure(error))
                return
            }

            guard let html = result as? String, let finalURL = currentURL else {
                DiagnosticStore.shared.log("ERROR", "WKWebView returned no HTML or URL.")
                self.finish(with: .failure(ArticlePipelineError.fetchFailed))
                return
            }

            DiagnosticStore.shared.log("INFO", "WKWebView HTML text length: \(html.count)")
            self.finish(with: .success(LoadedPage(url: finalURL, html: html)))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DiagnosticStore.shared.log("ERROR", "WKWebView navigation failed: \(error.localizedDescription)")
        finish(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DiagnosticStore.shared.log("ERROR", "WKWebView provisional navigation failed: \(error.localizedDescription)")
        finish(with: .failure(error))
    }
}
