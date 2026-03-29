import Foundation

struct ArticleExtractor {
    struct FetchResult {
        let html: String
        let finalURL: URL
    }

    func extract(from url: URL) async throws -> ArticleContent {
        let normalizedURL = normalizeInputURL(url)
        DiagnosticStore.shared.log("INFO", "Fetcher started for URL: \(url.absoluteString)")
        if normalizedURL != url {
            DiagnosticStore.shared.log("INFO", "Normalized input URL: \(normalizedURL.absoluteString)")
        }

        let initialResult = try await fetchHTML(from: normalizedURL)
        DiagnosticStore.shared.log("INFO", "Initial fetch final URL: \(initialResult.finalURL.absoluteString)")
        let resolvedResult = try await resolveIfNeeded(from: initialResult)
        DiagnosticStore.shared.log("INFO", "Resolved fetch URL: \(resolvedResult.finalURL.absoluteString)")
        DiagnosticStore.shared.log("INFO", "Resolved HTML text length: \(htmlToPlainText(resolvedResult.html).count)")
        return try extract(fromHTML: resolvedResult.html, sourceURL: resolvedResult.finalURL)
    }

    func extract(fromHTML html: String, sourceURL: URL) throws -> ArticleContent {
        try parse(html: html, sourceURL: sourceURL)
    }

    private func fetchHTML(from url: URL) async throws -> FetchResult {
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("ja,en-US;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, 200 ..< 400 ~= httpResponse.statusCode else {
            throw ArticlePipelineError.fetchFailed
        }

        if let html = String(data: data, encoding: .utf8) {
            return FetchResult(html: html, finalURL: response.url ?? url)
        }

        if let html = String(data: data, encoding: .shiftJIS) {
            return FetchResult(html: html, finalURL: response.url ?? url)
        }

        throw ArticlePipelineError.fetchFailed
    }

    private func resolveIfNeeded(from result: FetchResult) async throws -> FetchResult {
        if let redirectURL = normalizeRedirectURL(result.finalURL), redirectURL != result.finalURL {
            DiagnosticStore.shared.log("INFO", "Resolved redirect URL from final URL: \(redirectURL.absoluteString)")
            return try await fetchHTML(from: redirectURL)
        }

        if let externalArticleURL = extractExternalArticleURL(from: result.html, baseURL: result.finalURL) {
            DiagnosticStore.shared.log("INFO", "Resolved external article URL from HTML: \(externalArticleURL.absoluteString)")
            return try await fetchHTML(from: externalArticleURL)
        }

        guard shouldResolveSmartNews(url: result.finalURL, html: result.html),
              let destinationURL = extractDestinationURL(from: result.html, baseURL: result.finalURL) else {
            DiagnosticStore.shared.log("INFO", "No secondary destination URL found. Using initial response.")
            return result
        }

        guard destinationURL.host != result.finalURL.host || destinationURL.path != result.finalURL.path else {
            DiagnosticStore.shared.log("INFO", "Destination URL matched the fetched URL. Skipping refetch.")
            return result
        }

        DiagnosticStore.shared.log("INFO", "Secondary destination URL detected: \(destinationURL.absoluteString)")
        return try await fetchHTML(from: destinationURL)
    }

    private func parse(html: String, sourceURL: URL) throws -> ArticleContent {
        let cleanedHTML = sanitizeHTML(html)
        let title = extractTitle(from: html) ?? extractTitle(from: cleanedHTML) ?? sourceURL.host ?? "Untitled Article"
        let articleHTML = extractBestArticleHTML(from: cleanedHTML)
        let fallbackText = extractFallbackText(from: html) ?? extractFallbackText(from: cleanedHTML)
        let bodyParagraphs = extractParagraphs(from: articleHTML, fallbackHTML: cleanedHTML, fallbackText: fallbackText)
        let imageURLs = extractImages(from: articleHTML, fallbackHTML: html, baseURL: sourceURL)
        DiagnosticStore.shared.log("INFO", "Article title candidate: \(title)")
        DiagnosticStore.shared.log("INFO", "Extracted paragraphs: \(bodyParagraphs.count), images: \(imageURLs.count)")

        let article = ArticleContent(
            sourceURL: sourceURL,
            title: title,
            bodyParagraphs: bodyParagraphs,
            imageURLs: imageURLs
        )

        if isSmartNewsPreview(article: article) {
            DiagnosticStore.shared.log("ERROR", "Detected SmartNews preview content instead of publisher article.")
            throw ArticlePipelineError.emptyContent
        }

        guard article.hasReadableContent else {
            DiagnosticStore.shared.log("ERROR", "Readable content check failed for URL: \(sourceURL.absoluteString)")
            throw ArticlePipelineError.emptyContent
        }

        return article
    }

    private func shouldResolveSmartNews(url: URL, html: String) -> Bool {
        if let host = url.host,
           host.contains("smartnews.com") || host.contains("adjust.com") {
            return true
        }

        let textLength = htmlToPlainText(html).count
        return textLength < 120
    }

    private func extractDestinationURL(from html: String, baseURL: URL) -> URL? {
        let patterns = [
            "(?is)<meta[^>]*http-equiv=[\"']refresh[\"'][^>]*content=[\"'][^\"']*url=(.*?)[\"'][^>]*>",
            "(?is)<link[^>]*rel=[\"']canonical[\"'][^>]*href=[\"'](.*?)[\"'][^>]*>",
            "(?is)<meta[^>]*property=[\"']og:url[\"'][^>]*content=[\"'](.*?)[\"'][^>]*>",
            "(?is)window\\.location(?:\\.href)?\\s*=\\s*[\"'](.*?)[\"']",
            "(?is)location\\.replace\\([\"'](.*?)[\"']\\)"
        ]

        for pattern in patterns {
            if let capture = firstCapture(in: html, pattern: pattern),
               let url = URL(string: capture, relativeTo: baseURL)?.absoluteURL,
               let host = url.host,
               !host.contains("smartnews.com") {
                return url
            }
        }

        return nil
    }

    private func extractExternalArticleURL(from html: String, baseURL: URL) -> URL? {
        guard let host = baseURL.host?.lowercased(),
              host.contains("smartnews.com") || host.contains("adjust.com") else {
            return nil
        }

        let patterns = [
            "(?is)href=[\"'](https?://[^\"']+)[\"']",
            "(?is)content=[\"'](https?://[^\"']+)[\"']",
            "(?is)https?:\\\\?/\\\\?/[^\\\"'<>\\s]+",
            "(?is)https?://[^\\\"'<>\\s]+"
        ]

        var candidates: [URL] = []
        for pattern in patterns {
            for raw in allCaptures(in: html, pattern: pattern) {
                let normalized = raw
                    .replacingOccurrences(of: "\\/", with: "/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))

                if let candidate = decodedURL(from: normalized),
                   isLikelyPublisherURL(candidate, comparedTo: baseURL) {
                    candidates.append(candidate)
                }
            }
        }

        let scoredCandidates = candidates
            .map { ($0, scoreExternalURL($0)) }
            .sorted { lhs, rhs in lhs.1 > rhs.1 }

        return scoredCandidates.first?.0
    }

    private func normalizeInputURL(_ url: URL) -> URL {
        normalizeRedirectURL(url) ?? url
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

        let preferredKeys = [
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

        for key in preferredKeys {
            if let value = items.first(where: { $0.name == key })?.value,
               let candidate = decodedURL(from: value) {
                return candidate
            }
        }

        for item in items {
            if let value = item.value, let candidate = decodedURL(from: value) {
                return candidate
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

    private func isLikelyPublisherURL(_ url: URL, comparedTo baseURL: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }

        if host.contains("smartnews.com") || host.contains("adjust.com") {
            return false
        }

        if url == baseURL {
            return false
        }

        let blockedHosts = [
            "apple.com",
            "itunes.apple.com",
            "apps.apple.com",
            "facebook.com",
            "instagram.com",
            "twitter.com",
            "x.com"
        ]

        return !blockedHosts.contains(where: host.contains)
    }

    private func scoreExternalURL(_ url: URL) -> Int {
        let absolute = url.absoluteString.lowercased()
        var score = 0

        if let host = url.host?.lowercased(), !host.contains("smartnews.com") {
            score += 8
        }
        if absolute.contains("placement=article-preview-social") { score -= 10 }
        if absolute.contains("/article/") { score -= 6 }
        if absolute.contains("utm_source=share_ios_other") { score += 4 }
        if absolute.contains("news") || absolute.contains("article") { score += 2 }

        return score
    }

    private func sanitizeHTML(_ html: String) -> String {
        var result = html
        let blockPatterns = [
            "(?is)<script\\b[^>]*>.*?</script>",
            "(?is)<style\\b[^>]*>.*?</style>",
            "(?is)<noscript\\b[^>]*>.*?</noscript>",
            "(?is)<iframe\\b[^>]*>.*?</iframe>",
            "(?is)<svg\\b[^>]*>.*?</svg>",
            "(?is)<header\\b[^>]*>.*?</header>",
            "(?is)<footer\\b[^>]*>.*?</footer>",
            "(?is)<nav\\b[^>]*>.*?</nav>",
            "(?is)<aside\\b[^>]*>.*?</aside>",
            "(?is)<form\\b[^>]*>.*?</form>"
        ]

        for pattern in blockPatterns {
            result = replacing(pattern: pattern, in: result, with: " ")
        }

        return result
    }

    private func extractTitle(from html: String) -> String? {
        let patterns = [
            "(?is)<meta[^>]*property=[\"']og:title[\"'][^>]*content=[\"'](.*?)[\"'][^>]*>",
            "(?is)<meta[^>]*content=[\"'](.*?)[\"'][^>]*property=[\"']og:title[\"'][^>]*>",
            "(?is)<meta[^>]*name=[\"']twitter:title[\"'][^>]*content=[\"'](.*?)[\"'][^>]*>",
            "(?is)<h1\\b[^>]*>(.*?)</h1>",
            "(?is)<title\\b[^>]*>(.*?)</title>"
        ]

        for pattern in patterns {
            if let raw = firstCapture(in: html, pattern: pattern) {
                let normalized = htmlToPlainText(raw)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }

        return nil
    }

    private func extractBestArticleHTML(from html: String) -> String {
        let strongPatterns = [
            "(?is)<article\\b[^>]*>(.*?)</article>",
            "(?is)<main\\b[^>]*>(.*?)</main>",
            "(?is)<section\\b[^>]*>(.*?)</section>",
            "(?is)<div\\b[^>]*class=[\"'][^\"']*(article-body|articleBody|post-content|entry-content|story-body)[^\"']*[\"'][^>]*>(.*?)</div>"
        ]

        var bestMatch = ""
        var bestScore = 0

        for pattern in strongPatterns {
            for match in allCaptures(in: html, pattern: pattern) {
                let score = readabilityScore(for: match)
                if score > bestScore {
                    bestScore = score
                    bestMatch = match
                }
            }
        }

        if bestScore > 80 {
            return bestMatch
        }

        return html
    }

    private func readabilityScore(for html: String) -> Int {
        let paragraphCount = allCaptures(in: html, pattern: "(?is)<p\\b[^>]*>(.*?)</p>").count
        let imageCount = allCaptures(in: html, pattern: "(?is)<img\\b[^>]*>").count
        let textLength = htmlToPlainText(html).count
        return textLength + (paragraphCount * 80) + (imageCount * 20)
    }

    private func extractParagraphs(from html: String, fallbackHTML: String, fallbackText: String?) -> [String] {
        let blockPattern = "(?is)<(p|h2|h3|blockquote|li)\\b[^>]*>(.*?)</\\1>"
        let paragraphs = allCaptures(in: html, pattern: blockPattern)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map(htmlToPlainText)
            .filter { $0.count > 8 }

        if !paragraphs.isEmpty {
            return normalizeParagraphs(paragraphs)
        }

        let fallbackParagraphs = htmlToPlainText(html)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 8 }

        if !fallbackParagraphs.isEmpty {
            return normalizeParagraphs(fallbackParagraphs)
        }

        let broaderParagraphs = htmlToPlainText(fallbackHTML)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 12 }

        if !broaderParagraphs.isEmpty {
            return normalizeParagraphs(broaderParagraphs)
        }

        if let fallbackText, !fallbackText.isEmpty {
            return normalizeParagraphs(splitFallbackText(fallbackText))
        }

        return []
    }

    private func extractImages(from html: String, fallbackHTML: String, baseURL: URL) -> [URL] {
        let patterns = [
            "(?is)<img\\b[^>]*src=[\"'](.*?)[\"'][^>]*>",
            "(?is)<img\\b[^>]*data-src=[\"'](.*?)[\"'][^>]*>",
            "(?is)<meta[^>]*property=[\"']og:image[\"'][^>]*content=[\"'](.*?)[\"'][^>]*>"
        ]

        let candidateHTML = html.count > fallbackHTML.count / 3 ? html : fallbackHTML
        let urls = patterns.flatMap { pattern in
            allCaptures(in: candidateHTML, pattern: pattern).compactMap { candidate in
                URL(string: candidate, relativeTo: baseURL)?.absoluteURL
            }
        }

        var unique: [URL] = []
        var seen = Set<String>()

        for url in urls {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                unique.append(url)
            }
            if unique.count == 3 {
                break
            }
        }

        return unique
    }

    private func extractFallbackText(from html: String) -> String? {
        let jsonLDBodies = allCaptures(in: html, pattern: "(?is)<script\\b[^>]*type=[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>")
            .compactMap(extractArticleBodyFromJSONLD)

        if let bestJSON = jsonLDBodies.max(by: { $0.count < $1.count }), bestJSON.count > 20 {
            return bestJSON
        }

        let metaPatterns = [
            "(?is)<meta[^>]*name=[\"']description[\"'][^>]*content=[\"'](.*?)[\"'][^>]*>",
            "(?is)<meta[^>]*property=[\"']og:description[\"'][^>]*content=[\"'](.*?)[\"'][^>]*>",
            "(?is)<meta[^>]*name=[\"']twitter:description[\"'][^>]*content=[\"'](.*?)[\"'][^>]*>"
        ]

        for pattern in metaPatterns {
            if let capture = firstCapture(in: html, pattern: pattern) {
                let normalized = htmlToPlainText(capture)
                if normalized.count > 20 {
                    return normalized
                }
            }
        }

        return nil
    }

    private func extractArticleBodyFromJSONLD(_ jsonText: String) -> String? {
        guard let data = jsonText.data(using: .utf8) else {
            return nil
        }

        if let object = try? JSONSerialization.jsonObject(with: data) {
            return findArticleBody(in: object)
        }

        return nil
    }

    private func findArticleBody(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let articleBody = dictionary["articleBody"] as? String {
                let normalized = htmlToPlainText(articleBody)
                if !normalized.isEmpty {
                    return normalized
                }
            }

            for value in dictionary.values {
                if let match = findArticleBody(in: value) {
                    return match
                }
            }
        }

        if let array = object as? [Any] {
            for item in array {
                if let match = findArticleBody(in: item) {
                    return match
                }
            }
        }

        return nil
    }

    private func splitFallbackText(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: "\n。!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 12 }
    }

    private func normalizeParagraphs(_ paragraphs: [String]) -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let collapsed = replacing(pattern: "\\s{2,}", in: trimmed, with: " ")
            if seen.insert(collapsed).inserted {
                normalized.append(collapsed)
            }
        }

        return normalized
    }

    private func isSmartNewsPreview(article: ArticleContent) -> Bool {
        guard let host = article.sourceURL.host?.lowercased(), host.contains("smartnews.com") else {
            return false
        }

        let joined = ([article.title] + article.bodyParagraphs).joined(separator: " ").lowercased()
        let brandingSignals = [
            "smartnews",
            "article-preview-social",
            "open in app",
            "download app"
        ]

        let mostlyBranding = brandingSignals.contains { joined.contains($0) }
        let veryShort = article.bodyParagraphs.count <= 2
        return mostlyBranding || veryShort
    }

    private func htmlToPlainText(_ html: String) -> String {
        let breakAdjusted = replacing(pattern: "(?i)<br\\s*/?>", in: html, with: "\n")
        let blockAdjusted = replacing(pattern: "(?i)</(p|div|h1|h2|h3|blockquote|li|article|section|main)>", in: breakAdjusted, with: "\n")
        let stripped = replacing(pattern: "(?is)<[^>]+>", in: blockAdjusted, with: " ")
        let decoded = decodeHTMLEntities(in: stripped)
        let compactNewlines = replacing(pattern: "\\n{3,}", in: decoded, with: "\n\n")
        let compactSpaces = replacing(pattern: "[ \\t]{2,}", in: compactNewlines, with: " ")
        return compactSpaces.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(in text: String) -> String {
        let entities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]

        return entities.reduce(text) { partial, pair in
            partial.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }

    private func allCaptures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            let captureIndex = match.numberOfRanges > 2 ? 2 : 1
            guard match.numberOfRanges > captureIndex,
                  let captureRange = Range(match.range(at: captureIndex), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        allCaptures(in: text, pattern: pattern).first
    }

    private func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
