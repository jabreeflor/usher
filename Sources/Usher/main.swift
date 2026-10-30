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

    private var recent: [TrackedWindow] = []
    private var lastCategory: [String: Category] = [:]
    private var lastAction = "Waiting for a window"

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

        let tracked = TrackedWindow(pid: pid, element: window)
        if !titleOnly {
            recent.removeAll { $0 == tracked }
            recent.insert(tracked, at: 0)
            recent = Array(recent.prefix(12))
        }
        let name = app.localizedName ?? bundle
        let title = AX.title(window)

        classifier.classify(appName: name, bundleID: bundle, title: title) { [weak self] result in
            guard let self else { return }
            // Jev can take a second; don't move a window the user already left.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let focusedNow = AX.focusedWindow(pid: pid), CFEqual(focusedNow, window) else { return }
            // A title change only re-tiles when it changes the kind of work.
            if titleOnly, self.lastCategory[tracked.key] == result.category { return }
            self.lastCategory[tracked.key] = result.category

            let share = Settings.shared.share(for: result.category)
            self.tiler.tile(focused: tracked, share: share, recent: self.recent)
            self.lastAction = "\(name): \(result.category.label) → \(share.label)"
            if result.source != .jev {
                log("\(result.source.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)) \(bundle) \"\(title)\" -> \(result.category.rawValue)")
            }
            log("tile \(name) at \(share.label.lowercased())")
        }
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

    @objc private func retile() {
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
