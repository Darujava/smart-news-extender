import Social
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import os

final class ShareViewController: UIViewController {
    private let logger = Logger(subsystem: "com.example.SmartNewsToGoodNotes", category: "ShareExtension")
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let logTextView = UITextView()

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

        logTextView.translatesAutoresizingMaskIntoConstraints = false
        logTextView.isEditable = false
        logTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logTextView.backgroundColor = .secondarySystemBackground
        logTextView.layer.cornerRadius = 14
        logTextView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        view.addSubview(spinner)
        view.addSubview(statusLabel)
        view.addSubview(logTextView)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            logTextView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])

        refreshVisibleLogs()
    }

    @MainActor
    private func updateStatus(_ text: String) {
        statusLabel.text = text
    }

    private func handleSharedContent() async {
        do {
            let url = try await extractSharedURL()
            logInfo("Selected shared URL: \(url.absoluteString)")
            guard PendingShareStore.shared.save(url) else {
                throw ArticlePipelineError.hostAppLaunchFailed
            }
            logInfo("Saved shared URL into App Group store.")
            await updateStatus("URLを保存しました。本体アプリを開いて処理を続けてください。")
            spinner.stopAnimating()
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            logError("Share flow failed: \(error.localizedDescription)")
            await presentError(error)
        }
    }

    private func extractSharedURL() async throws -> URL {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            logError("No NSExtensionItem attachments found.")
            throw ArticlePipelineError.unsupportedInput
        }

        logInfo("Share extension received \(attachments.count) attachment(s).")

        for (index, attachment) in attachments.enumerated() {
            let identifiers = attachment.registeredTypeIdentifiers.joined(separator: ", ")
            logInfo("Attachment \(index) registered types: \(identifiers)")

            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let item = try await attachment.loadItem(forTypeIdentifier: UTType.url.identifier)
                loggerLoadedItem(item, typeIdentifier: UTType.url.identifier, index: index)
                if let url = item as? URL {
                    return url
                }
                if let string = item as? String, let url = URL(string: string) {
                    return url
                }
            }

            if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                let item = try await attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                loggerLoadedItem(item, typeIdentifier: UTType.plainText.identifier, index: index)
                if let string = item as? String,
                   let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return url
                }
            }

            if attachment.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
                let item = try await attachment.loadItem(forTypeIdentifier: UTType.propertyList.identifier)
                loggerLoadedItem(item, typeIdentifier: UTType.propertyList.identifier, index: index)
            }
        }

        logError("Failed to resolve a valid URL from shared attachments.")
        throw ArticlePipelineError.invalidURL
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

    private func loggerLoadedItem(_ item: NSSecureCoding?, typeIdentifier: String, index: Int) {
        let itemType = item.map { String(describing: type(of: $0)) } ?? "nil"
        logInfo("Attachment \(index) loaded item for \(typeIdentifier): type=\(itemType)")

        if let url = item as? URL {
            logInfo("Attachment \(index) URL value: \(url.absoluteString)")
        } else if let string = item as? String {
            logInfo("Attachment \(index) string value: \(string)")
        } else if let dictionary = item as? NSDictionary {
            logInfo("Attachment \(index) dictionary value: \(dictionary.description)")
        }
    }

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
        DiagnosticStore.shared.log("INFO", message)
        DispatchQueue.main.async { [weak self] in
            self?.refreshVisibleLogs()
        }
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        DiagnosticStore.shared.log("ERROR", message)
        DispatchQueue.main.async { [weak self] in
            self?.refreshVisibleLogs()
        }
    }

    @MainActor
    private func refreshVisibleLogs() {
        let lines = DiagnosticStore.shared.load().prefix(20).map { entry in
            let time = entry.timestamp.formatted(date: .omitted, time: .standard)
            return "[\(entry.level)] \(time) \(entry.message)"
        }
        logTextView.text = lines.isEmpty ? "ログはまだありません。" : lines.joined(separator: "\n")
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
