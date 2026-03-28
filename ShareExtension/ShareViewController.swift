import Social
import SwiftUI
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    private let extractor = ArticleExtractor()
    private let pdfGenerator = PDFGenerator()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        Task {
            await handleSharedContent()
        }
    }

    private func configureUI() {
        view.backgroundColor = .systemBackground
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.text = "記事を取得してPDFを生成しています…"

        view.addSubview(spinner)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    @MainActor
    private func updateStatus(_ text: String) {
        statusLabel.text = text
    }

    private func handleSharedContent() async {
        do {
            let url = try await extractSharedURL()
            await updateStatus("記事を解析しています…")
            let article = try await extractor.extract(from: url)

            await updateStatus("PDFを生成しています…")
            let pdfURL = try await pdfGenerator.generatePDF(for: article)

            await updateStatus("共有シートを開いています…")
            await presentShareSheet(for: pdfURL)
        } catch {
            await presentError(error)
        }
    }

    private func extractSharedURL() async throws -> URL {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            throw ArticlePipelineError.unsupportedInput
        }

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let item = try await attachment.loadItem(forTypeIdentifier: UTType.url.identifier)
                if let url = item as? URL {
                    return url
                }
                if let string = item as? String, let url = URL(string: string) {
                    return url
                }
            }

            if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                let item = try await attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                if let string = item as? String,
                   let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return url
                }
            }
        }

        throw ArticlePipelineError.invalidURL
    }

    @MainActor
    private func presentShareSheet(for pdfURL: URL) {
        let controller = UIActivityViewController(activityItems: [pdfURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }

        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }

        present(controller, animated: true)
    }

    @MainActor
    private func presentError(_ error: Error) {
        spinner.stopAnimating()
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let alert = UIAlertController(title: "処理に失敗しました", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default) { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: error)
        })
        present(alert, animated: true)
    }
}

private extension NSItemProvider {
    func loadItem(forTypeIdentifier typeIdentifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: item)
            }
        }
    }
}
