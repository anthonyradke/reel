import AppKit
import ApplicationServices
import ReelCore

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin, typed wrappers over the Accessibility API.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func windowID(_ el: AXUIElement) -> WindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(el, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func get<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let arr = value as? [AnyObject] else { return [] }
        return arr.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        get(el, attr) as Bool?
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        get(el, attr) as String?
    }

    static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    static func position(_ el: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = position(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func setPosition(_ el: AXUIElement, _ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    static func setSize(_ el: AXUIElement, _ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) == .success
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, attr as CFString, value) == .success
    }

    static func raise(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }

    /// Some apps animate every move when this is on (it's set by tools like VoiceOver),
    /// which makes the strip lag. Turn it off for the duration of a move.
    static func withoutEnhancedUI<T>(_ app: AXUIElement, _ body: () -> T) -> T {
        let attr = "AXEnhancedUserInterface"
        let was = bool(app, attr) ?? false
        if was { set(app, attr, kCFBooleanFalse) }
        defer { if was { set(app, attr, kCFBooleanTrue) } }
        return body()
    }
}
