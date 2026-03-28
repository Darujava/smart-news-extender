import Foundation
import UIKit

struct PDFGenerator {
    struct Layout {
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let margin: CGFloat = 56
        let paragraphSpacing: CGFloat = 16
        let titleSpacing: CGFloat = 24
        let imageHeight: CGFloat = 220
        let annotationSpace: CGFloat = 28
    }

    private let layout = Layout()

    func generatePDF(for article: ArticleContent) async throws -> URL {
        let imageDatas = try await loadImages(from: article.imageURLs)
        let renderedImages = imageDatas.compactMap(UIImage.init(data:))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeFilename(article.title))
            .appendingPathExtension("pdf")

        let renderer = UIGraphicsPDFRenderer(bounds: layout.pageRect)

        do {
            try renderer.writePDF(to: fileURL) { context in
                var cursorY = layout.margin

                func beginPageIfNeeded(for height: CGFloat) {
                    let limit = layout.pageRect.height - layout.margin
                    if cursorY + height > limit {
                        context.beginPage()
                        cursorY = layout.margin
                    }
                }

                context.beginPage()

                let titleAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: UIColor.label
                ]
                let bodyAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: UIColor.label
                ]
                let metaAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel
                ]

                let contentWidth = layout.pageRect.width - (layout.margin * 2)

                let titleRect = boundingRect(
                    for: article.title,
                    width: contentWidth,
                    attributes: titleAttributes
                )
                article.title.draw(
                    in: CGRect(x: layout.margin, y: cursorY, width: contentWidth, height: titleRect.height),
                    withAttributes: titleAttributes
                )
                cursorY += titleRect.height + 8

                let meta = article.sourceURL.absoluteString
                let metaRect = boundingRect(for: meta, width: contentWidth, attributes: metaAttributes)
                meta.draw(
                    in: CGRect(x: layout.margin, y: cursorY, width: contentWidth, height: metaRect.height),
                    withAttributes: metaAttributes
                )
                cursorY += metaRect.height + layout.titleSpacing

                for image in renderedImages {
                    beginPageIfNeeded(for: layout.imageHeight + layout.paragraphSpacing)
                    let imageRect = fittedImageRect(for: image, y: cursorY, width: contentWidth)
                    image.draw(in: imageRect)
                    cursorY = imageRect.maxY + layout.paragraphSpacing
                }

                for paragraph in article.bodyParagraphs {
                    let paragraphRect = boundingRect(
                        for: paragraph,
                        width: contentWidth,
                        attributes: bodyAttributes
                    )
                    beginPageIfNeeded(for: paragraphRect.height + layout.annotationSpace + layout.paragraphSpacing)
                    paragraph.draw(
                        in: CGRect(x: layout.margin, y: cursorY, width: contentWidth, height: paragraphRect.height),
                        withAttributes: bodyAttributes
                    )
                    cursorY += paragraphRect.height + layout.annotationSpace

                    let guidePath = UIBezierPath()
                    guidePath.move(to: CGPoint(x: layout.margin, y: cursorY))
                    guidePath.addLine(to: CGPoint(x: layout.pageRect.width - layout.margin, y: cursorY))
                    UIColor.systemGray4.setStroke()
                    guidePath.lineWidth = 0.5
                    guidePath.stroke()
                    cursorY += layout.paragraphSpacing
                }
            }
        } catch {
            throw ArticlePipelineError.pdfGenerationFailed
        }

        return fileURL
    }

    private func loadImages(from urls: [URL]) async throws -> [Data] {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            for url in urls {
                group.addTask {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard let httpResponse = response as? HTTPURLResponse, 200 ..< 400 ~= httpResponse.statusCode else {
                        return nil
                    }
                    return data
                }
            }

            var results: [Data] = []
            for try await data in group {
                if let data {
                    results.append(data)
                }
            }
            return results
        }
    }

    private func boundingRect(
        for string: String,
        width: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGRect {
        let attributed = NSAttributedString(string: string, attributes: attributes)
        return attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral
    }

    private func fittedImageRect(for image: UIImage, y: CGFloat, width: CGFloat) -> CGRect {
        let aspectRatio = image.size.height / max(image.size.width, 1)
        let height = min(layout.imageHeight, width * aspectRatio)
        return CGRect(x: layout.margin, y: y, width: width, height: height)
    }

    private func safeFilename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "article" : cleaned
    }
}
