import Foundation

struct ArticleExtractor {
    func extract(from url: URL) async throws -> ArticleContent {
        let html = try await fetchHTML(from: url)
        return try parse(html: html, sourceURL: url)
    }

    private func fetchHTML(from url: URL) async throws -> String {
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, 200 ..< 400 ~= httpResponse.statusCode else {
            throw ArticlePipelineError.fetchFailed
        }

        if let html = String(data: data, encoding: .utf8) {
            return html
        }

        if let html = String(data: data, encoding: .shiftJIS) {
            return html
        }

        throw ArticlePipelineError.fetchFailed
    }

    private func parse(html: String, sourceURL: URL) throws -> ArticleContent {
        let cleanedHTML = sanitizeHTML(html)
        let title = extractTitle(from: cleanedHTML) ?? sourceURL.host ?? "Untitled Article"
        let articleHTML = extractBestArticleHTML(from: cleanedHTML)
        let bodyParagraphs = extractParagraphs(from: articleHTML)
        let imageURLs = extractImages(from: articleHTML, baseURL: sourceURL)

        let article = ArticleContent(
            sourceURL: sourceURL,
            title: title,
            bodyParagraphs: bodyParagraphs,
            imageURLs: imageURLs
        )

        guard article.hasReadableContent else {
            throw ArticlePipelineError.emptyContent
        }

        return article
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

        if bestScore > 120 {
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

    private func extractParagraphs(from html: String) -> [String] {
        let blockPattern = "(?is)<(p|h2|h3|blockquote|li)\\b[^>]*>(.*?)</\\1>"
        let paragraphs = allCaptures(in: html, pattern: blockPattern)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map(htmlToPlainText)
            .filter { $0.count > 20 }

        if !paragraphs.isEmpty {
            return paragraphs
        }

        return htmlToPlainText(html)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 20 }
    }

    private func extractImages(from html: String, baseURL: URL) -> [URL] {
        let patterns = [
            "(?is)<img\\b[^>]*src=[\"'](.*?)[\"'][^>]*>",
            "(?is)<img\\b[^>]*data-src=[\"'](.*?)[\"'][^>]*>"
        ]

        let urls = patterns.flatMap { pattern in
            allCaptures(in: html, pattern: pattern).compactMap { candidate in
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
