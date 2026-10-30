import AppKit

/// Applies a `Layout` plan to real windows on the focused window's screen.
final class Tiler {
    var gap: CGFloat = 8

    func tile(focused: TrackedWindow, share: Share, recent: [TrackedWindow]) {
        guard let current = AX.frame(focused.element), let screen = Screens.containing(current) else { return }
        let area = Screens.visibleFrame(screen).insetBy(dx: gap, dy: gap)

        // Only windows already on this screen, so nothing jumps between monitors.
        let others = recent.filter { window in
            guard window != focused, AX.isTileable(window.element), let frame = AX.frame(window.element) else { return false }
            return Screens.containing(frame) == screen
        }

        let plan = Layout.plan(area: area, share: share, sideCount: others.count, gap: gap)
        AX.setFrame(focused.element, pid: focused.pid, plan.main)
        for (window, rect) in zip(others, plan.side) {
            AX.setFrame(window.element, pid: window.pid, rect)
        }
    }
}
