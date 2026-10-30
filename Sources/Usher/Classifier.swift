import Foundation

struct Classification {
    enum Source: String { case jev, cache, fallback }

    let category: Category
    let confidence: Double
    let reason: String
    var source: Source
}

/// Asks Jev (via OpenRouter) what kind of work a window is, and remembers the answer.
final class Classifier {
    static let model = "typesafe/jev-router"
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    // Kept short and schema-free on purpose: a strict json_schema makes the router pick a large model
    // (about 1.8 s per call), while a short prompt like this one gets a flash model in under a second.
    private static let prompt = """
    Classify this Mac window for a tiling window manager. Categories: \
    \(Category.allCases.map { "\($0.rawValue) (\($0.examples))" }.joined(separator: ", ")). \
    For apps that show anything, like browsers, the title decides: a video is media, docs are reference. \
    Terminals and editors are code even when the title mentions another topic.
    Reply with only JSON: {"category": "...", "confidence": 0-1, "reason": "under 12 words"}
    """

    private var cache: [String: Classification] = [:]
    private var waiting: [String: [(Classification) -> Void]] = [:]

    func clearCache() { cache.removeAll() }

    /// Counters ("Inbox (12)") and status glyphs (a terminal's spinner: ◐ ◑ ✳) change constantly,
    /// so they don't count as a new title.
    static func cacheKey(bundleID: String, title: String) -> String {
        let normalized = title.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s#|.:/_~-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\d+", with: "#", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return bundleID + "|" + String(normalized.prefix(80))
    }

    /// Calls `completion` on the main queue.
    func classify(appName: String, bundleID: String, title: String, completion: @escaping (Classification) -> Void) {
        let key = Self.cacheKey(bundleID: bundleID, title: title)
        if var hit = cache[key] {
            hit.source = .cache
            completion(hit)
            return
        }
        guard let apiKey = Settings.shared.apiKey else {
            completion(Self.fallback(bundleID: bundleID, title: title))
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]

        let started = Date()
        request(apiKey: apiKey, appName: appName, bundleID: bundleID, title: title) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let answer: Classification
                switch result {
                case .success(let c):
                    answer = c
                    self.cache[key] = c
                    log("jev  \(bundleID) \"\(title)\" -> \(c.category.rawValue) (\(String(format: "%.2f", c.confidence))) \(ms) ms: \(c.reason)")
                case .failure(let error):
                    answer = Self.fallback(bundleID: bundleID, title: title)
                    log("jev  request failed after \(ms) ms (\(error.localizedDescription)); using built-in guess \(answer.category.rawValue)")
                }
                self.waiting.removeValue(forKey: key)?.forEach { $0(answer) }
            }
        }
    }

    private func request(apiKey: String, appName: String, bundleID: String, title: String,
                         done: @escaping (Result<Classification, Error>) -> Void) {
        var body: [String: Any] = [
            "model": Self.model,
            "messages": [
                ["role": "user", "content": "\(Self.prompt)\napp: \(appName) (\(bundleID))\ntitle: \(title.isEmpty ? "(none)" : title)"],
            ],
            "temperature": 0,
            "max_tokens": 1000,
        ]
        // Low effort keeps the wait after a focus change short. USHER_EFFORT=default leaves it to the router.
        let effort = ProcessInfo.processInfo.environment["USHER_EFFORT"] ?? "low"
        if effort != "default" { body["reasoning"] = ["effort": effort] }
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Usher", forHTTPHeaderField: "X-Title")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { return done(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else { return done(.failure(ClassifierError.message("empty response"))) }
            guard status == 200 else {
                let text = String(data: data, encoding: .utf8) ?? ""
                return done(.failure(ClassifierError.message("HTTP \(status): \(text.prefix(300))")))
            }
            done(Result { try Self.parse(data) })
        }.resume()
    }

    static func parse(_ data: Data) throws -> Classification {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var content = message["content"] as? String
        else { throw ClassifierError.message("unexpected response shape") }

        // Some routed models wrap JSON in a code fence even when asked not to.
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```") {
            content = content.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = content.range(of: "```", options: .backwards) { content.removeSubrange(fence.lowerBound...) }
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let raw = json["category"] as? String, let category = Category(rawValue: raw)
        else { throw ClassifierError.message("could not read category from: \(content.prefix(200))") }

        return Classification(category: category,
                              confidence: json["confidence"] as? Double ?? 0,
                              reason: json["reason"] as? String ?? "",
                              source: .jev)
    }

    /// Used when there's no API key or the request fails.
    static func fallback(bundleID: String, title: String) -> Classification {
        let b = bundleID.lowercased(), t = title.lowercased()
        func any(_ words: [String], in s: String) -> Bool { words.contains { s.contains($0) } }
        let category: Category
        if any(["youtube", "netflix", "twitch", "vimeo", "video", "keynote"], in: t) || any(["keynote", "quicktime", "iina", "vlc"], in: b) {
            category = .media
        } else if any(["vscode", "xcode", "terminal", "iterm", "ghostty", "jetbrains", "cursor", "zed", "sublime", "warp"], in: b) {
            category = .code
        } else if any(["slack", "discord", "mobilesms", "mail", "telegram", "whatsapp", "teams", "zoom"], in: b) {
            category = .chat
        } else if any(["notes", "obsidian", "pages", "word", "notion", "bear", "textedit"], in: b) {
            category = .writing
        } else if any(["music", "spotify", "activitymonitor", "systempreferences", "settings"], in: b) {
            category = .ambient
        } else {
            category = .reference
        }
        return Classification(category: category, confidence: 0.5, reason: "built-in guess", source: .fallback)
    }
}

enum ClassifierError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
