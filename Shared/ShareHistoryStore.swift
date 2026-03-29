import Foundation
import Combine

struct SharedArticleRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let url: String
    var title: String?
    let createdAt: Date

    init(id: UUID = UUID(), url: String, title: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }

        if let parsedURL = URL(string: url), let host = parsedURL.host, !host.isEmpty {
            return host
        }

        return url
    }
}

@MainActor
final class ShareHistoryViewModel: ObservableObject {
    @Published private(set) var records: [SharedArticleRecord] = []

    init() {
        reload()
    }

    func reload() {
        records = ShareHistoryStore.shared.load()
    }

    func clear() {
        ShareHistoryStore.shared.clear()
        reload()
    }
}

final class ShareHistoryStore {
    static let shared = ShareHistoryStore()

    private let key = "shared.article.history"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var defaults: UserDefaults? {
        guard let identifier = AppGroupConfig.identifier else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    func add(url: URL, title: String? = nil) {
        guard let defaults else { return }
        var records = load()

        if let index = records.firstIndex(where: { $0.url == url.absoluteString }) {
            let existing = records.remove(at: index)
            let updated = SharedArticleRecord(
                id: existing.id,
                url: existing.url,
                title: title ?? existing.title,
                createdAt: .now
            )
            records.insert(updated, at: 0)
        } else {
            records.insert(
                SharedArticleRecord(url: url.absoluteString, title: title),
                at: 0
            )
        }

        if records.count > 100 {
            records = Array(records.prefix(100))
        }

        if let data = try? encoder.encode(records) {
            defaults.set(data, forKey: key)
        }
    }

    func updateTitle(for url: URL, title: String) {
        guard let defaults else { return }
        var records = load()

        if let index = records.firstIndex(where: { $0.url == url.absoluteString }) {
            records[index].title = title
        } else {
            records.insert(SharedArticleRecord(url: url.absoluteString, title: title), at: 0)
        }

        if let data = try? encoder.encode(records) {
            defaults.set(data, forKey: key)
        }
    }

    func load() -> [SharedArticleRecord] {
        guard let defaults,
              let data = defaults.data(forKey: key),
              let records = try? decoder.decode([SharedArticleRecord].self, from: data) else {
            return []
        }
        return records
    }

    func clear() {
        defaults?.removeObject(forKey: key)
    }
}
