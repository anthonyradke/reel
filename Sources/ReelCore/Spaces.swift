import Foundation

/// Which strip a window lives on: a display and one of its Spaces.
public struct StripKey: Hashable, Codable, CustomStringConvertible {
    public var display: String
    public var space: UInt64
    public var description: String { "\(display.prefix(8))/\(space)" }

    public init(display: String, space: UInt64) {
        self.display = display
        self.space = space
    }
}

/// Maps Spaces to strips. When "Displays have separate Spaces" is off (or SkyLight isn't
/// there), every display reports the same Space, so a Space id alone doesn't name a display.
public enum SpaceMap {
    /// The strip each display shows now, keyed by display UUID.
    public static func activeKeys(displays: [String], perDisplay: [String: UInt64], shared: UInt64?) -> [String: StripKey] {
        var keys: [String: StripKey] = [:]
        for d in displays {
            keys[d] = StripKey(display: d, space: perDisplay[d] ?? shared ?? 0)
        }
        return keys
    }

    /// The strip for a window on `display` that macOS reports on `space`. Its own display wins
    /// when that display is showing the Space; otherwise a display currently showing it (the
    /// window was dragged there in Mission Control); otherwise the display's strip for that
    /// Space, which comes on screen when the user switches to it.
    public static func key(forWindowOn display: String, space: UInt64, active: [String: StripKey]) -> StripKey {
        if let own = active[display], own.space == space { return own }
        if let other = showing(space, active: active) { return other }
        return StripKey(display: display, space: space)
    }

    /// A display currently showing `space`, the first by UUID so the answer doesn't change
    /// from one call to the next.
    public static func showing(_ space: UInt64, active: [String: StripKey]) -> StripKey? {
        active.values.filter { $0.space == space }.min { $0.display < $1.display }
    }

    /// Where a window on strip `key` belongs now that macOS says it's on `space`, or nil if it
    /// should stay. Only moves it to a strip that is on screen.
    public static func reassignment(of key: StripKey, windowSpace space: UInt64, active: [String: StripKey]) -> StripKey? {
        guard space != key.space else { return nil }
        if let own = active[key.display], own.space == space { return own }
        return showing(space, active: active)
    }
}
