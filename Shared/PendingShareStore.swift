import Foundation

final class PendingShareStore {
    static let shared = PendingShareStore()

    private let key = "pending.shared.article.url"

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
        defaults.set(url.absoluteString, forKey: key)
        ShareHistoryStore.shared.add(url: url)
        return true
    }

    func load() -> URL? {
        guard let rawValue = defaults?.string(forKey: key) else {
            return nil
        }
        return URL(string: rawValue)
    }

    func consume() -> URL? {
        let url = load()
        clear()
        return url
    }

    func clear() {
        defaults?.removeObject(forKey: key)
    }
}
