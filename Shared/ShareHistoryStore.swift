import Foundation
import Combine

struct SharedArticleRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let url: String
    var title: String?
    let createdAt: Date
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        url: String,
        title: String? = nil,
        createdAt: Date = .now,
        isPinned: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
        self.isPinned = isPinned
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

    var domain: String {
        URL(string: url)?.host ?? url
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

    func togglePin(_ record: SharedArticleRecord) {
        ShareHistoryStore.shared.togglePin(for: record.id)
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
                createdAt: .now,
                isPinned: existing.isPinned
            )
            records.append(updated)
        } else {
            records.append(SharedArticleRecord(url: url.absoluteString, title: title))
        }

        save(records, into: defaults)
    }

    func updateTitle(for url: URL, title: String) {
        guard let defaults else { return }
        var records = load()

        if let index = records.firstIndex(where: { $0.url == url.absoluteString }) {
            records[index].title = title
        } else {
            records.append(SharedArticleRecord(url: url.absoluteString, title: title))
        }

        save(records, into: defaults)
    }

    func togglePin(for id: UUID) {
        guard let defaults else { return }
        var records = load()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isPinned.toggle()
        save(records, into: defaults)
    }

    func load() -> [SharedArticleRecord] {
        guard let defaults,
              let data = defaults.data(forKey: key),
              let records = try? decoder.decode([SharedArticleRecord].self, from: data) else {
            return []
        }

        return records.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func clear() {
        defaults?.removeObject(forKey: key)
    }

    private func save(_ records: [SharedArticleRecord], into defaults: UserDefaults) {
        let trimmed = Array(records.suffix(100))
        if let data = try? encoder.encode(trimmed) {
            defaults.set(data, forKey: key)
        }
    }
}
