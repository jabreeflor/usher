import AppKit
import ApplicationServices

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// System surfaces that have windows but shouldn't be tiled.
    static let ignoredBundles: Set<String> = [
        "com.apple.systemuiserver", "com.apple.loginwindow", "com.apple.dock",
        "com.apple.notificationcenterui", "com.apple.controlcenter", "com.apple.Spotlight",
    ]

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let watcher = FocusWatcher()
    private let classifier = Classifier()
    private let tiler = Tiler()

    /// The last window Usher sized as the main window, and where it actually ended up.
    private struct Placement {
        let window: TrackedWindow
        let bundleID: String
        let appName: String
        let category: Category
        let share: Share
        let area: CGRect
        var frame: CGRect?
    }

    private var recent: [TrackedWindow] = []
    private var lastCategory: [String: Category] = [:]
    private var lastAction = "Waiting for a window"
    private var lastApp: (bundleID: String, name: String)?
    private var placed: Placement?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Usher")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        log(Settings.shared.apiKey == nil
            ? "No OpenRouter key found. Using built-in guesses until \(Settings.keyFile.path) exists or OPENROUTER_API_KEY is set."
            : "Classifying with \(Classifier.model) on OpenRouter.")

        watcher.onChange = { [weak self] pid, window, titleOnly in self?.focusChanged(pid: pid, window: window, titleOnly: titleOnly) }
        whenTrusted { [weak self] in
            log("Watching focus changes.")
            self?.watcher.start()
        }
    }

    private func whenTrusted(_ start: @escaping () -> Void) {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) { return start() }
        log("Needs Accessibility permission: System Settings > Privacy & Security > Accessibility. Turn on the app that launched this (your terminal, or Usher).")
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            start()
        }
    }

    private func focusChanged(pid: pid_t, window: AXUIElement, titleOnly: Bool) {
        guard Settings.shared.enabled, AX.isTileable(window),
              let app = NSRunningApplication(processIdentifier: pid),
              let bundle = app.bundleIdentifier, !Self.ignoredBundles.contains(bundle) else { return }

        let name = app.localizedName ?? bundle
        lastApp = (bundle, name)
        if !titleOnly { learnFromResize() }

        let rule = Settings.shared.rule(for: bundle)
        if rule == .ignore {
            lastAction = "\(name): never tiled"
            return
        }

        let tracked = TrackedWindow(pid: pid, element: window)
        if !titleOnly {
            recent.removeAll { $0 == tracked }
            recent.insert(tracked, at: 0)
            recent = Array(recent.prefix(12))
        }

        if case .share(let share)? = rule {
            if !titleOnly { place(tracked, bundleID: bundle, name: name, category: nil, share: share, why: "app rule") }
            return
        }

        let title = AX.title(window)
        classifier.classify(appName: name, bundleID: bundle, title: title) { [weak self] result in
            guard let self else { return }
            // Jev can take a second; don't move a window the user already left.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let focusedNow = AX.focusedWindow(pid: pid), CFEqual(focusedNow, window) else { return }
            // A title change only re-tiles when it changes the kind of work.
            if titleOnly, self.lastCategory[tracked.key] == result.category { return }
            self.lastCategory[tracked.key] = result.category

            if result.source != .jev {
                log("\(result.source.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)) \(bundle) \"\(title)\" -> \(result.category.rawValue)")
            }
            if let learned = Settings.shared.learnedShare(bundleID: bundle, category: result.category) {
                self.place(tracked, bundleID: bundle, name: name, category: result.category, share: learned, why: "learned")
            } else {
                self.place(tracked, bundleID: bundle, name: name, category: result.category,
                           share: Settings.shared.share(for: result.category), why: nil)
            }
        }
    }

    private func place(_ window: TrackedWindow, bundleID: String, name: String, category: Category?, share: Share, why: String?) {
        guard let area = tiler.tile(focused: window, share: share, recent: recent) else { return }
        let suffix = why.map { " (\($0))" } ?? ""
        lastAction = "\(name): \(category?.label ?? "Rule") → \(share.label)\(suffix)"
        log("tile \(name) at \(share.label.lowercased())\(suffix)")

        // Only Jev's choices are worth correcting; an app rule is already the user's own.
        guard let category else { placed = nil; return }
        placed = Placement(window: window, bundleID: bundleID, appName: name, category: category, share: share, area: area)
        // Read the frame back once the app has settled, since some apps won't shrink below their minimum size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.placed?.window == window else { return }
            self.placed?.frame = AX.frame(window.element)
        }
    }

    /// If the user resized the last window Usher placed, remember the size they picked for that app and kind of work.
    private func learnFromResize() {
        guard let placement = placed, let before = placement.frame else { return }
        placed = nil
        guard AX.isTileable(placement.window.element), let now = AX.frame(placement.window.element) else { return }
        // Small nudges aren't a verdict on the size.
        guard abs(now.width - before.width) > placement.area.width * 0.08 else { return }
        let share = Share.nearest(to: now.width / placement.area.width)
        guard share != placement.share else { return }
        Settings.shared.setLearnedShare(share, bundleID: placement.bundleID, category: placement.category)
        log("learn \(placement.appName) \(placement.category.rawValue): \(placement.share.label) -> \(share.label)")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: lastAction, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let model = NSMenuItem(title: Settings.shared.apiKey == nil ? "No API key: using built-in guesses" : "Model: \(Classifier.model)", action: nil, keyEquivalent: "")
        model.isEnabled = false
        menu.addItem(model)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Auto-tile", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = Settings.shared.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(item("Tile Focused Window Now", #selector(retile)))

        let rules = NSMenuItem(title: "Sizes", action: nil, keyEquivalent: "")
        let rulesMenu = NSMenu()
        for category in Category.allCases {
            let current = Settings.shared.share(for: category)
            let row = NSMenuItem(title: "\(category.label): \(current.label)", action: nil, keyEquivalent: "")
            let choices = NSMenu()
            for share in Share.allCases {
                let choice = item(share.label, #selector(pickShare(_:)))
                choice.representedObject = "\(category.rawValue)|\(share.rawValue)"
                choice.state = share == current ? .on : .off
                choices.addItem(choice)
            }
            row.submenu = choices
            rulesMenu.addItem(row)
        }
        rules.submenu = rulesMenu
        menu.addItem(rules)

        if let app = lastApp {
            let current = Settings.shared.rule(for: app.bundleID)
            let appItem = NSMenuItem(title: "\(app.name): \(current?.label ?? "Let Usher Decide")", action: nil, keyEquivalent: "")
            let appMenu = NSMenu()
            let choices: [AppRule?] = [nil] + Share.allCases.map(AppRule.share) + [.ignore]
            for rule in choices {
                if rule == .ignore || rule == .share(.full) { appMenu.addItem(.separator()) }
                let choice = item(rule?.label ?? "Let Usher Decide", #selector(pickRule(_:)))
                choice.representedObject = (app.bundleID, rule)
                choice.state = rule == current ? .on : .off
                appMenu.addItem(choice)
            }
            appItem.submenu = appMenu
            menu.addItem(appItem)
        }

        let learned = Settings.shared.allLearned
        let learnedItem = NSMenuItem(title: "Learned Sizes", action: nil, keyEquivalent: "")
        let learnedMenu = NSMenu()
        if learned.isEmpty {
            let empty = NSMenuItem(title: "Resize a window Usher placed and it'll remember", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            learnedMenu.addItem(empty)
        } else {
            let hint = NSMenuItem(title: "Click one to forget it", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            learnedMenu.addItem(hint)
            for entry in learned {
                let row = item("\(Self.appName(entry.bundleID)) · \(entry.category.label): \(entry.share.label)", #selector(forgetOne(_:)))
                row.representedObject = (entry.bundleID, entry.category)
                learnedMenu.addItem(row)
            }
            learnedMenu.addItem(.separator())
            learnedMenu.addItem(item("Forget All", #selector(forgetAllLearned)))
        }
        learnedItem.submenu = learnedMenu
        menu.addItem(learnedItem)

        menu.addItem(item("Forget Saved Classifications", #selector(clearCache)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Usher", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleEnabled() { Settings.shared.enabled.toggle() }

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @objc private func pickRule(_ sender: NSMenuItem) {
        guard let (bundleID, rule) = sender.representedObject as? (String, AppRule?) else { return }
        Settings.shared.setRule(rule, for: bundleID)
        if rule == .ignore {
            recent.removeAll { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier == bundleID }
            return
        }
        retile()
    }

    @objc private func forgetOne(_ sender: NSMenuItem) {
        guard let (bundleID, category) = sender.representedObject as? (String, Category) else { return }
        Settings.shared.setLearnedShare(nil, bundleID: bundleID, category: category)
        retile()
    }

    @objc private func forgetAllLearned() {
        Settings.shared.forgetLearned()
        retile()
    }

    @objc private func retile() {
        // A manual re-tile resets the size on purpose; don't mistake that for a correction.
        placed = nil
        lastCategory.removeAll()
        // Give the menu time to close so focus returns to the window underneath.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.watcher.refire() }
    }

    @objc private func pickShare(_ sender: NSMenuItem) {
        guard let parts = (sender.representedObject as? String)?.split(separator: "|"), parts.count == 2,
              let category = Category(rawValue: String(parts[0])), let share = Share(rawValue: String(parts[1])) else { return }
        Settings.shared.setShare(share, for: category)
        retile()
    }

    @objc private func clearCache() {
        classifier.clearCache()
        log("Forgot saved classifications.")
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// `Usher --classify <bundle id> <title>` tests the Jev call without touching any windows.
let args = CommandLine.arguments
// `Usher --plan <width> <height> <share> <side windows>` prints a layout without touching any windows.
if args.count == 6, args[1] == "--plan", let w = Double(args[2]), let h = Double(args[3]),
   let share = Share(rawValue: args[4]), let n = Int(args[5]) {
    let plan = Layout.plan(area: CGRect(x: 0, y: 0, width: w, height: h), share: share, sideCount: n, gap: 8)
    func describe(_ r: CGRect) -> String { "x \(Int(r.minX)) y \(Int(r.minY))  \(Int(r.width))×\(Int(r.height))" }
    print("main   \(describe(plan.main))")
    for (i, r) in plan.side.enumerated() { print("side \(i + 1) \(describe(r))") }
    if plan.side.count < n { print("\(n - plan.side.count) left as is") }
    exit(0)
}
if args.count >= 3, args[1] == "--classify" {
    let bundle = args[2], title = args.dropFirst(3).joined(separator: " ")
    let classifier = Classifier()
    classifier.classify(appName: bundle, bundleID: bundle, title: title) { result in
        print("\(result.category.rawValue) (\(result.source.rawValue), confidence \(result.confidence)): \(result.reason)")
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
