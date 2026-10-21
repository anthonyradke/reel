import Foundation

/// Every user setting. Stored as JSON in Application Support; the app watches it and applies
/// changes as soon as they land, so there is no Save button.
public struct Config: Codable, Equatable {
    // Layout
    public var gap: Double = 8
    public var outerGap: Double = 8
    public var presetWidths: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    public var defaultWidth: Double = 0.5
    public var widthStep: Double = 0.1
    public var centerMode: CenterMode = .never
    public var respectDock: Bool = true
    public var keepOriginalHeight: Bool = false
    public var pinnedWidth: Double = 1.0 / 3.0

    // Animation
    public var animate: Bool = true
    /// Spring stiffness as an angular frequency. Higher settles faster.
    public var springResponse: Double = 22

    // Appearance
    public var focusBorder: Bool = false
    public var focusBorderWidth: Double = 4
    public var focusBorderColor: RGBA = RGBA(r: 0.33, g: 0.62, b: 1.0, a: 1)
    public var focusBorderRadius: Double = 10
    public var dimInactive: Bool = false
    public var dimAmount: Double = 0.25
    public var showIndicator: Bool = true
    public var tabBarHeight: Double = 26

    // Input
    public var swipeFingers: Int = 4 // 0 = off, 3 or 4
    public var naturalSwipe: Bool = true
    public var swipeSensitivity: Double = 1.0
    /// Swipe with pictures of the windows, which keeps them in step (needs Screen Recording).
    public var smoothSwipe: Bool = true
    public var focusFollowsMouse: Bool = false
    public var mouseFollowsFocus: Bool = false
    public var dragToReorder: Bool = true

    // Behaviour
    public var launchAtLogin: Bool = false
    public var startOnLaunch: Bool = true
    public var newWindowPlacement: NewWindowPlacement = .rightOfFocused
    public var rules: [WindowRule] = []
    /// Display UUIDs the user switched off.
    public var disabledDisplays: [String] = []
    public var restoreSession: Bool = true
    public var floatFixedSizeWindows: Bool = true

    // Shortcuts. Keyed by Command.name.
    public var bindings: [String: [KeyCombo]] = Config.defaultBindings

    public var hasCompletedOnboarding: Bool = false

    public init() {}

    public static let defaultBindings: [String: [KeyCombo]] = DefaultBindings.make()
}

extension Config {
    // Lenient decoding: a missing key keeps its default, so older files keep working.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func take<T: Decodable>(_ key: CodingKeys, _ into: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { into = v }
        }
        take(.gap, &gap)
        take(.outerGap, &outerGap)
        take(.presetWidths, &presetWidths)
        take(.defaultWidth, &defaultWidth)
        take(.widthStep, &widthStep)
        take(.centerMode, &centerMode)
        take(.respectDock, &respectDock)
        take(.keepOriginalHeight, &keepOriginalHeight)
        take(.pinnedWidth, &pinnedWidth)
        take(.animate, &animate)
        take(.springResponse, &springResponse)
        take(.focusBorder, &focusBorder)
        take(.focusBorderWidth, &focusBorderWidth)
        take(.focusBorderColor, &focusBorderColor)
        take(.focusBorderRadius, &focusBorderRadius)
        take(.dimInactive, &dimInactive)
        take(.dimAmount, &dimAmount)
        take(.showIndicator, &showIndicator)
        take(.tabBarHeight, &tabBarHeight)
        take(.swipeFingers, &swipeFingers)
        take(.naturalSwipe, &naturalSwipe)
        take(.swipeSensitivity, &swipeSensitivity)
        take(.smoothSwipe, &smoothSwipe)
        take(.focusFollowsMouse, &focusFollowsMouse)
        take(.mouseFollowsFocus, &mouseFollowsFocus)
        take(.dragToReorder, &dragToReorder)
        take(.launchAtLogin, &launchAtLogin)
        take(.startOnLaunch, &startOnLaunch)
        take(.newWindowPlacement, &newWindowPlacement)
        take(.rules, &rules)
        take(.disabledDisplays, &disabledDisplays)
        take(.restoreSession, &restoreSession)
        take(.floatFixedSizeWindows, &floatFixedSizeWindows)
        take(.bindings, &bindings)
        take(.hasCompletedOnboarding, &hasCompletedOnboarding)
        // Actions added in a later version get their default keys.
        for (name, combos) in Config.defaultBindings where bindings[name] == nil {
            bindings[name] = combos
        }
    }

    public var sortedPresets: [Double] {
        let p = presetWidths.filter { $0 > 0 && $0 <= 1 }.sorted()
        return p.isEmpty ? [0.5] : p
    }
}

public struct RGBA: Codable, Equatable, Hashable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

public enum NewWindowPlacement: String, Codable, CaseIterable, Identifiable {
    case rightOfFocused
    case endOfStrip
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .rightOfFocused: return "Next to the focused window"
        case .endOfStrip: return "At the end of the strip"
        }
    }
}

public struct WindowRule: Codable, Equatable, Identifiable, Hashable {
    public enum Action: String, Codable, CaseIterable, Identifiable {
        case float
        case tile
        case slot
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .float: return "Float"
            case .tile: return "Always tile"
            case .slot: return "Fixed slot"
            }
        }
    }

    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var action: Action
    /// 1-based place on the strip for `.slot`. 0 means last.
    public var slot: Int
    /// Optional width for windows of this app.
    public var width: Double?
    /// Only match windows whose title contains this (case insensitive). Empty matches all.
    public var titleContains: String

    public init(bundleID: String, appName: String, action: Action, slot: Int = 1, width: Double? = nil, titleContains: String = "") {
        self.id = UUID()
        self.bundleID = bundleID
        self.appName = appName
        self.action = action
        self.slot = slot
        self.width = width
        self.titleContains = titleContains
    }

    public func matches(bundleID: String?, title: String) -> Bool {
        guard bundleID == self.bundleID else { return false }
        if titleContains.isEmpty { return true }
        return title.localizedCaseInsensitiveContains(titleContains)
    }
}
