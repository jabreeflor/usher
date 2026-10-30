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

    /// The share closest to a width the user picked by hand.
    static func nearest(to fraction: CGFloat) -> Share {
        allCases.min { abs($0.fraction - fraction) < abs($1.fraction - fraction) }!
    }
}

/// A per-app override set from the menu. It skips Jev entirely.
enum AppRule: Equatable {
    case share(Share)
    case ignore

    var label: String {
        switch self {
        case .share(let share): return "Always \(share.label)"
        case .ignore: return "Never Tile"
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

    // MARK: Per-app rules

    func rule(for bundleID: String) -> AppRule? {
        guard let raw = defaults.string(forKey: "rule.\(bundleID)") else { return nil }
        if raw == "ignore" { return .ignore }
        return Share(rawValue: raw).map(AppRule.share)
    }

    func setRule(_ rule: AppRule?, for bundleID: String) {
        switch rule {
        case .share(let share): defaults.set(share.rawValue, forKey: "rule.\(bundleID)")
        case .ignore: defaults.set("ignore", forKey: "rule.\(bundleID)")
        case nil: defaults.removeObject(forKey: "rule.\(bundleID)")
        }
    }

    // MARK: Learned sizes

    /// Shares learned from the user resizing a window Usher placed, keyed by "bundle|category",
    /// so Chrome on docs and Chrome on YouTube learn separately.
    private var learned: [String: String] {
        get { defaults.dictionary(forKey: "learned") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "learned") }
    }

    func learnedShare(bundleID: String, category: Category) -> Share? {
        learned["\(bundleID)|\(category.rawValue)"].flatMap(Share.init(rawValue:))
    }

    func setLearnedShare(_ share: Share?, bundleID: String, category: Category) {
        learned["\(bundleID)|\(category.rawValue)"] = share?.rawValue
    }

    var allLearned: [(bundleID: String, category: Category, share: Share)] {
        learned.compactMap { key, value in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let category = Category(rawValue: parts[1]), let share = Share(rawValue: value) else { return nil }
            return (parts[0], category, share)
        }.sorted { ($0.bundleID, $0.category.rawValue) < ($1.bundleID, $1.category.rawValue) }
    }

    func forgetLearned() { defaults.removeObject(forKey: "learned") }

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
