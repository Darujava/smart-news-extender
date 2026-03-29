import Foundation

struct ArticleContent: Sendable {
    let sourceURL: URL
    let title: String
    let bodyParagraphs: [String]
    let imageURLs: [URL]

    var hasReadableContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !bodyParagraphs.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WebExtractedArticle: Sendable {
    let sourceURL: URL
    let title: String
    let bodyParagraphs: [String]
    let imageURLs: [URL]

    var asArticleContent: ArticleContent {
        ArticleContent(
            sourceURL: sourceURL,
            title: title,
            bodyParagraphs: bodyParagraphs,
            imageURLs: imageURLs
        )
    }

    var hasReadableContent: Bool {
        asArticleContent.hasReadableContent
    }
}

enum ArticlePipelineError: LocalizedError {
    case invalidURL
    case unsupportedInput
    case fetchFailed
    case parsingFailed
    case emptyContent
    case pdfGenerationFailed
    case hostAppLaunchFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "有効なURLを受け取れませんでした。"
        case .unsupportedInput:
            return "共有された項目はURLとして扱えませんでした。"
        case .fetchFailed:
            return "記事の取得に失敗しました。通信状況を確認してください。"
        case .parsingFailed:
            return "記事本文の解析に失敗しました。"
        case .emptyContent:
            return "記事本文を抽出できませんでした。"
        case .pdfGenerationFailed:
            return "PDFの生成に失敗しました。"
        case .hostAppLaunchFailed:
            return "本体アプリを開けませんでした。アプリを削除して再インストールしてから、もう一度試してください。"
        }
    }
}
