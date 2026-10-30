import AppKit
import ApplicationServices

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(notification as String)
}

/// Reports when the focused window changes, or when its title changes (a browser switching tabs).
final class FocusWatcher {
    /// (pid, window, titleOnly)
    var onChange: ((pid_t, AXUIElement, Bool) -> Void)?

    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var titleWindow: AXUIElement?
    private var pending: DispatchWorkItem?
    private var pendingTitleOnly: Bool?

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.watch(app.processIdentifier)
            self?.schedule(titleOnly: false)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            watch(front.processIdentifier)
            schedule(titleOnly: false)
        }
    }

    /// Re-runs the current window as a fresh focus change.
    func refire() { schedule(titleOnly: false) }

    private func watch(_ pid: pid_t) {
        guard pid != observedPid, pid != getpid() else { return }
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        observer = nil
        titleWindow = nil
        observedPid = pid

        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let created else { return }
        AXObserverAddNotification(created, AXUIElementCreateApplication(pid), kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    fileprivate func handle(_ notification: String) {
        schedule(titleOnly: notification == kAXTitleChangedNotification)
    }

    /// Debounced: focus changes settle fast, titles flicker while pages load.
    private func schedule(titleOnly: Bool) {
        let titleOnly = titleOnly && (pendingTitleOnly ?? true)
        pending?.cancel()
        pendingTitleOnly = titleOnly
        let item = DispatchWorkItem { [weak self] in self?.fire(titleOnly: titleOnly) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (titleOnly ? 0.8 : 0.2), execute: item)
    }

    private func fire(titleOnly: Bool) {
        pendingTitleOnly = nil
        guard let window = AX.focusedWindow(pid: observedPid) else { return }

        // Follow title changes on whichever window is focused now.
        if let observer, titleWindow.map({ !CFEqual($0, window) }) ?? true {
            if let old = titleWindow { AXObserverRemoveNotification(observer, old, kAXTitleChangedNotification as CFString) }
            AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, refcon)
            titleWindow = window
        }
        onChange?(observedPid, window, titleOnly)
    }
}
