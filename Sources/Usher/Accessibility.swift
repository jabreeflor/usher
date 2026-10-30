import AppKit
import ApplicationServices

/// A window owned by another app, compared by the underlying accessibility element.
struct TrackedWindow: Equatable {
    let pid: pid_t
    let element: AXUIElement

    static func == (a: TrackedWindow, b: TrackedWindow) -> Bool {
        a.pid == b.pid && CFEqual(a.element, b.element)
    }

    var key: String { "\(pid)-\(CFHash(element))" }
}

enum AX {
    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        guard let value = copy(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func title(_ window: AXUIElement) -> String {
        copy(window, kAXTitleAttribute) as? String ?? ""
    }

    /// Skips dialogs, sheets, palettes and minimized or full-screen windows.
    static func isTileable(_ window: AXUIElement) -> Bool {
        guard copy(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { return false }
        if copy(window, kAXMinimizedAttribute) as? Bool == true { return false }
        if copy(window, "AXFullScreen") as? Bool == true { return false }
        return true
    }

    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let p = copy(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = copy(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Size, then position, then size again: a window near a screen edge can refuse the first resize.
    static func setFrame(_ window: AXUIElement, pid: pid_t, _ rect: CGRect) {
        var origin = rect.origin, size = rect.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }

        // Apps with enhanced UI (Chrome, Electron) animate every change, which makes resizing slow and jumpy.
        let app = AXUIElementCreateApplication(pid)
        let enhanced = copy(app, "AXEnhancedUserInterface") as? Bool == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }

        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)

        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }
}

/// Accessibility uses top-left-origin coordinates; AppKit screens use bottom-left.
enum Screens {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func containing(_ axRect: CGRect) -> NSScreen? {
        let point = CGPoint(x: axRect.midX, y: primaryHeight - axRect.midY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    static func visibleFrame(_ screen: NSScreen) -> CGRect {
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
    }
}
