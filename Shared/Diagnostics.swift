import Foundation
import Combine

enum AppGroupConfig {
    static let identifier: String? = "group.com.example.SmartNewsToGoodNotes"
}

struct DiagnosticEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: String
    let message: String

    init(level: String, message: String, timestamp: Date = .now) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published private(set) var entries: [DiagnosticEntry] = []

    init() {
        reload()
    }

    func reload() {
        entries = DiagnosticStore.shared.load()
    }

    func clear() {
        DiagnosticStore.shared.clear()
        reload()
    }
}

final class DiagnosticStore {
    static let shared = DiagnosticStore()

    private let key = "diagnostic.entries"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var defaults: UserDefaults {
        if let identifier = AppGroupConfig.identifier,
           let sharedDefaults = UserDefaults(suiteName: identifier) {
            return sharedDefaults
        }
        return .standard
    }

    func log(_ level: String, _ message: String) {
        let entry = DiagnosticEntry(level: level, message: message)
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > 200 {
            entries = Array(entries.prefix(200))
        }

        if let data = try? encoder.encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    func load() -> [DiagnosticEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? decoder.decode([DiagnosticEntry].self, from: data) else {
            return []
        }
        return entries
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
