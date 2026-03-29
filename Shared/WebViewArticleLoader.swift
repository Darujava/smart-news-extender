import Foundation
import WebKit

@MainActor
final class WebViewArticleLoader: NSObject {
    struct LoadedPage {
        let url: URL
        let html: String
        let extractedArticle: WebExtractedArticle?
    }

    private var continuation: CheckedContinuation<LoadedPage, Error>?
    private var webView: WKWebView?
    private var remainingFollowCount = 2

    func load(url: URL) async throws -> LoadedPage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.remainingFollowCount = 2
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
            self.extractReadableArticle(from: webView, finalURL: finalURL, html: html)
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

    private func extractReadableArticle(from webView: WKWebView, finalURL: URL, html: String) {
        let script = """
        (() => {
          const canonical = document.querySelector('link[rel="canonical"]')?.href || '';
          const ogTitle = document.querySelector('meta[property="og:title"]')?.content || '';
          const docTitle = ogTitle || document.title || '';
          const ogImage = document.querySelector('meta[property="og:image"]')?.content || '';
          const selectors = ['article', 'main', '[role="main"]', '.article-body', '.post-content', '.entry-content', '.story-body'];
          let root = null;
          for (const selector of selectors) {
            const candidate = document.querySelector(selector);
            if (candidate && candidate.innerText && candidate.innerText.trim().length > 120) {
              root = candidate;
              break;
            }
          }
          if (!root) root = document.body;
          const text = (root?.innerText || '').replace(/\\t/g, ' ').trim();
          const parts = text
            .split(/\\n{2,}/)
            .map(s => s.trim())
            .filter(Boolean)
            .filter(s => s.length > 20)
            .slice(0, 80);
          const images = Array.from(root?.querySelectorAll('img') || [])
            .map(img => img.currentSrc || img.src || img.getAttribute('data-src') || '')
            .filter(Boolean)
            .slice(0, 3);
          const links = Array.from(document.querySelectorAll('a[href]'))
            .map(a => a.href || '')
            .filter(Boolean);
          return {
            canonical,
            title: docTitle,
            paragraphs: parts,
            images,
            links
          };
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }

            if let error {
                DiagnosticStore.shared.log("ERROR", "WKWebView readable extraction failed: \(error.localizedDescription)")
                self.finish(with: .success(LoadedPage(url: finalURL, html: html, extractedArticle: nil)))
                return
            }

            guard let dictionary = result as? [String: Any] else {
                DiagnosticStore.shared.log("INFO", "WKWebView readable extraction returned no dictionary.")
                self.finish(with: .success(LoadedPage(url: finalURL, html: html, extractedArticle: nil)))
                return
            }

            let canonicalString = dictionary["canonical"] as? String
            let normalizedURL = URL(string: canonicalString ?? "") ?? finalURL
            let title = (dictionary["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let paragraphs = ((dictionary["paragraphs"] as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 20 }
            let imageURLs = ((dictionary["images"] as? [String]) ?? []).compactMap {
                URL(string: $0, relativeTo: normalizedURL)?.absoluteURL
            }

            let links = (dictionary["links"] as? [String]) ?? []
            let externalURL = self.preferredExternalURL(from: links, currentURL: normalizedURL)

            let extracted = WebExtractedArticle(
                sourceURL: normalizedURL,
                title: title.isEmpty ? (normalizedURL.host ?? "Untitled Article") : title,
                bodyParagraphs: paragraphs,
                imageURLs: imageURLs
            )

            DiagnosticStore.shared.log("INFO", "WKWebView readable extraction paragraphs: \(paragraphs.count)")
            if let first = paragraphs.first {
                DiagnosticStore.shared.log("INFO", "WKWebView first paragraph preview: \(String(first.prefix(160)))")
            }
            if self.shouldFollowExternalArticle(from: normalizedURL, article: extracted, links: links),
               let externalURL,
               self.remainingFollowCount > 0 {
                self.remainingFollowCount -= 1
                DiagnosticStore.shared.log("INFO", "WKWebView following external article URL: \(externalURL.absoluteString)")
                webView.load(URLRequest(url: externalURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
                return
            }

            self.finish(with: .success(LoadedPage(url: normalizedURL, html: html, extractedArticle: extracted.hasReadableContent ? extracted : nil)))
        }
    }

    private func shouldFollowExternalArticle(from url: URL, article: WebExtractedArticle, links: [String]) -> Bool {
        guard let host = url.host else { return false }
        let isSmartNewsPage = host.contains("smartnews.com") || host.contains("adjust.com")
        guard isSmartNewsPage else { return false }

        let joinedText = article.bodyParagraphs.joined(separator: " ").lowercased()
        let brandingSignals = ["smartnews", "article preview", "open in app", "download app"]
        let looksLikePreview = brandingSignals.contains { joinedText.contains($0) } || article.bodyParagraphs.count <= 2

        return looksLikePreview && preferredExternalURL(from: links, currentURL: url) != nil
    }

    private func preferredExternalURL(from links: [String], currentURL: URL) -> URL? {
        for link in links {
            guard let candidate = URL(string: link),
                  candidate.scheme?.hasPrefix("http") == true,
                  let host = candidate.host else {
                continue
            }

            if host.contains("smartnews.com") || host.contains("adjust.com") {
                continue
            }

            if candidate == currentURL {
                continue
            }

            return candidate
        }

        return nil
    }
}
