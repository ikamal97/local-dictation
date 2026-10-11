import AppKit
import ApplicationServices

/// What was around the cursor when a dictation started.
struct DictationContext {
    var bundleID: String?
    var windowTitle = ""
    var before = ""      // up to 500 characters before the cursor
    var selected = ""
    var after = ""       // up to 200 characters after the cursor
}

enum ContextCapture {
    /// Reads the focused text field via Accessibility. Every call is bounded by a short
    /// messaging timeout so an unresponsive app can't stall a dictation.
    static func capture() -> DictationContext {
        var ctx = DictationContext()
        ctx.bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let element = attribute(system, kAXFocusedUIElementAttribute).flatMap(asElement) else { return ctx }
        AXUIElementSetMessagingTimeout(element, 0.25)

        if let window = attribute(element, kAXWindowAttribute).flatMap(asElement),
           let title = attribute(window, kAXTitleAttribute) as? String {
            ctx.windowTitle = title
        }

        guard let text = attribute(element, kAXValueAttribute) as? String else { return ctx }
        let ns = text as NSString
        var range = CFRange(location: ns.length, length: 0)
        if let value = attribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cfRange, &range)
        }
        let location = min(max(range.location, 0), ns.length)
        let length = min(max(range.length, 0), ns.length - location)
        let beforeStart = max(0, location - 500)
        ctx.before = ns.substring(with: NSRange(location: beforeStart, length: location - beforeStart))
        ctx.selected = ns.substring(with: NSRange(location: location, length: length))
        let afterStart = location + length
        ctx.after = ns.substring(with: NSRange(location: afterStart, length: min(200, ns.length - afterStart)))
        return ctx
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func asElement(_ value: AnyObject) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
    }
}
