import Foundation

final class PendingShareStore {
    static let shared = PendingShareStore()

    private let key = "pending.shared.article.urls"

    var isAvailable: Bool {
        defaults != nil
    }

    private var defaults: UserDefaults? {
        guard let identifier = AppGroupConfig.identifier else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    @discardableResult
    func save(_ url: URL) -> Bool {
        guard let defaults else {
            return false
        }
        var urls = loadAll().map(\.absoluteString)
        urls.append(url.absoluteString)
        defaults.set(urls, forKey: key)
        ShareHistoryStore.shared.add(url: url)
        return true
    }

    func load() -> URL? {
        loadAll().first
    }

    func loadAll() -> [URL] {
        guard let values = defaults?.stringArray(forKey: key) else {
            return []
        }
        return values.compactMap(URL.init(string:))
    }

    func consume() -> URL? {
        guard let defaults else { return nil }
        var urls = loadAll().map(\.absoluteString)
        guard let first = urls.first, let url = URL(string: first) else {
            return nil
        }
        urls.removeFirst()
        defaults.set(urls, forKey: key)
        return url
    }

    var pendingCount: Int {
        loadAll().count
    }

    func clear() {
        defaults?.removeObject(forKey: key)
    }
}
