import AppKit

/// The kinds of work Jev sorts a window into.
enum Category: String, CaseIterable, Codable {
    case code, reference, media, chat, writing, ambient

    var label: String { rawValue.capitalized }
    var examples: String {
        switch self {
        case .code: return "editors, IDEs, terminals"
        case .reference: return "docs, articles, reading in a browser"
        case .media: return "video, presentations, games"
        case .chat: return "messaging, email"
        case .writing: return "notes, documents being written"
        case .ambient: return "music, monitors, timers, settings"
        }
    }
}

/// How much of the screen's width the focused window gets.
enum Share: String, CaseIterable {
    case full, twoThirds = "two-thirds", half, third

    var fraction: CGFloat {
        switch self {
        case .full: return 1
        case .twoThirds: return 2.0 / 3.0
        case .half: return 0.5
        case .third: return 1.0 / 3.0
        }
    }

    var label: String {
        switch self {
        case .full: return "Full"
        case .twoThirds: return "Two-thirds"
        case .half: return "Half"
        case .third: return "One-third"
        }
    }
}

final class Settings {
    static let shared = Settings()

    static let defaultShares: [Category: Share] = [
        .code: .twoThirds, .reference: .half, .media: .full,
        .chat: .third, .writing: .half, .ambient: .third,
    ]

    /// Where the OpenRouter key lives if OPENROUTER_API_KEY isn't set.
    static let keyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/usher/openrouter_key")

    private let defaults = UserDefaults.standard

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    func share(for category: Category) -> Share {
        if let raw = defaults.string(forKey: "share.\(category.rawValue)"), let share = Share(rawValue: raw) {
            return share
        }
        return Self.defaultShares[category] ?? .half
    }

    func setShare(_ share: Share, for category: Category) {
        defaults.set(share.rawValue, forKey: "share.\(category.rawValue)")
    }

    var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !env.isEmpty { return env }
        guard let file = try? String(contentsOf: Self.keyFile, encoding: .utf8) else { return nil }
        let key = file.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

func log(_ message: String) {
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(stamp)] \(message)")
    fflush(stdout)
}
