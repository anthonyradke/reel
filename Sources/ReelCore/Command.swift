import Foundation

/// Everything the engine can be asked to do, from a shortcut, the URL scheme, the CLI or a menu.
public enum Command: Equatable, Hashable {
    case focus(Direction)
    case focusFirst, focusLast
    case focusIndex(Int) // 1-based, 9 = last
    case move(Direction)
    case moveFirst, moveLast
    case moveToIndex(Int)
    case cycleWidth, cycleWidthBack
    case fullWidth
    case center
    case wider, narrower
    case taller, shorter
    case equalizeHeights
    case stackIntoLeft, stackIntoRight
    case popOut, popOutLeft
    case toggleTabbed
    case toggleFloat
    case sendToNextDisplay
    case pinLeft, pinRight
    case scroll(Double) // points, positive moves the view right
    case showIndicator
    case retile
    case start, stop, toggleRunning
    case openSettings

    public enum Direction: String, CaseIterable {
        case left, right, up, down
    }

    /// Stable name used for bindings, the URL scheme and the CLI.
    public var name: String {
        switch self {
        case .focus(let d): return "focus-\(d.rawValue)"
        case .focusFirst: return "focus-first"
        case .focusLast: return "focus-last"
        case .focusIndex(let n): return "focus-\(n)"
        case .move(let d): return "move-\(d.rawValue)"
        case .moveFirst: return "move-first"
        case .moveLast: return "move-last"
        case .moveToIndex(let n): return "move-to-\(n)"
        case .cycleWidth: return "cycle-width"
        case .cycleWidthBack: return "cycle-width-back"
        case .fullWidth: return "full-width"
        case .center: return "center"
        case .wider: return "wider"
        case .narrower: return "narrower"
        case .taller: return "taller"
        case .shorter: return "shorter"
        case .equalizeHeights: return "equalize-heights"
        case .stackIntoLeft: return "stack-left"
        case .stackIntoRight: return "stack-right"
        case .popOut: return "pop-out"
        case .popOutLeft: return "pop-out-left"
        case .toggleTabbed: return "toggle-tabbed"
        case .toggleFloat: return "toggle-float"
        case .sendToNextDisplay: return "send-to-next-display"
        case .pinLeft: return "pin-left"
        case .pinRight: return "pin-right"
        case .scroll(let dx): return "scroll:\(dx)"
        case .showIndicator: return "show-indicator"
        case .retile: return "retile"
        case .start: return "start"
        case .stop: return "stop"
        case .toggleRunning: return "toggle"
        case .openSettings: return "settings"
        }
    }

    public init?(name raw: String) {
        let name = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("scroll:"), let dx = Double(name.dropFirst(7)) {
            self = .scroll(dx); return
        }
        if let match = Command.all.first(where: { $0.name == name }) {
            self = match; return
        }
        // A few friendly aliases for the CLI and URL scheme.
        switch name {
        case "start": self = .start
        case "left": self = .focus(.left)
        case "right": self = .focus(.right)
        case "up": self = .focus(.up)
        case "down": self = .focus(.down)
        case "centre", "center-column": self = .center
        case "float": self = .toggleFloat
        case "tabbed", "tabs": self = .toggleTabbed
        case "full", "maximize": self = .fullWidth
        case "next-display": self = .sendToNextDisplay
        case "indicator": self = .showIndicator
        case "preferences", "config", "configuration": self = .openSettings
        default: return nil
        }
    }

    /// Every bindable command, in the order the Shortcuts page lists them.
    public static let all: [Command] = {
        var list: [Command] = Direction.allCases.map { .focus($0) }
        list += [.focusFirst, .focusLast]
        list += (1...9).map { .focusIndex($0) }
        list += Direction.allCases.map { .move($0) }
        list += [.moveFirst, .moveLast]
        list += (1...9).map { .moveToIndex($0) }
        list += [.cycleWidth, .cycleWidthBack, .fullWidth, .center, .wider, .narrower,
                 .taller, .shorter, .equalizeHeights,
                 .stackIntoLeft, .stackIntoRight, .popOut, .popOutLeft, .toggleTabbed,
                 .toggleFloat, .sendToNextDisplay, .pinLeft, .pinRight,
                 .showIndicator, .retile, .toggleRunning, .stop, .openSettings]
        return list
    }()

    public var title: String {
        switch self {
        case .focus(let d): return "Focus \(d.rawValue)"
        case .focusFirst: return "Focus first window"
        case .focusLast: return "Focus last window"
        case .focusIndex(let n): return n == 9 ? "Focus last place" : "Focus place \(n)"
        case .move(let d): return "Move window \(d.rawValue)"
        case .moveFirst: return "Move window to the start"
        case .moveLast: return "Move window to the end"
        case .moveToIndex(let n): return n == 9 ? "Move window to the last place" : "Move window to place \(n)"
        case .cycleWidth: return "Cycle width"
        case .cycleWidthBack: return "Cycle width backwards"
        case .fullWidth: return "Full width"
        case .center: return "Centre column"
        case .wider: return "Wider"
        case .narrower: return "Narrower"
        case .taller: return "Taller (in a stack)"
        case .shorter: return "Shorter (in a stack)"
        case .equalizeHeights: return "Equal heights"
        case .stackIntoLeft: return "Stack into the left column"
        case .stackIntoRight: return "Stack into the right column"
        case .popOut: return "Pop out of the stack"
        case .popOutLeft: return "Pop out to the left"
        case .toggleTabbed: return "Tabbed column"
        case .toggleFloat: return "Float or tile window"
        case .sendToNextDisplay: return "Send to next display"
        case .pinLeft: return "Pin to the left edge"
        case .pinRight: return "Pin to the right edge"
        case .scroll: return "Scroll"
        case .showIndicator: return "Show strip indicator"
        case .retile: return "Re-tile everything"
        case .start: return "Start"
        case .stop: return "Stop the window manager"
        case .toggleRunning: return "Start or stop"
        case .openSettings: return "Open settings"
        }
    }

    public var group: String {
        switch self {
        case .focus, .focusFirst, .focusLast, .focusIndex: return "Focus"
        case .move, .moveFirst, .moveLast, .moveToIndex: return "Move"
        case .cycleWidth, .cycleWidthBack, .fullWidth, .center, .wider, .narrower: return "Size"
        case .taller, .shorter, .equalizeHeights, .stackIntoLeft, .stackIntoRight, .popOut, .popOutLeft, .toggleTabbed: return "Stacks and tabs"
        case .toggleFloat, .sendToNextDisplay, .pinLeft, .pinRight: return "Windows"
        default: return "App"
        }
    }
}

/// A key plus modifiers. The key is a macOS virtual key code, so a binding keeps working when
/// the keyboard layout changes; the app shows it with the current layout's label.
public struct KeyCombo: Codable, Hashable {
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(_ keyCode: UInt32, _ modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public struct Modifiers: OptionSet, Codable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        public var symbols: String {
            var s = ""
            if contains(.control) { s += "⌃" }
            if contains(.option) { s += "⌥" }
            if contains(.shift) { s += "⇧" }
            if contains(.command) { s += "⌘" }
            return s
        }
    }
}

/// macOS virtual key codes for the default bindings (ANSI positions).
public enum KeyCode {
    public static let a: UInt32 = 0, s: UInt32 = 1, d: UInt32 = 2, f: UInt32 = 3, h: UInt32 = 4
    public static let c: UInt32 = 8, q: UInt32 = 12, r: UInt32 = 15, t: UInt32 = 17
    public static let one: UInt32 = 18, two: UInt32 = 19, three: UInt32 = 20, four: UInt32 = 21
    public static let six: UInt32 = 22, five: UInt32 = 23, equal: UInt32 = 24, nine: UInt32 = 25
    public static let seven: UInt32 = 26, minus: UInt32 = 27, eight: UInt32 = 28, zero: UInt32 = 29
    public static let rightBracket: UInt32 = 30, leftBracket: UInt32 = 33, p: UInt32 = 35
    public static let l: UInt32 = 37, j: UInt32 = 38, k: UInt32 = 40, n: UInt32 = 45
    public static let comma: UInt32 = 43, period: UInt32 = 47, space: UInt32 = 49
    public static let left: UInt32 = 123, right: UInt32 = 124, down: UInt32 = 125, up: UInt32 = 126

    public static let digits: [UInt32] = [one, two, three, four, five, six, seven, eight, nine]
}

enum DefaultBindings {
    static func make() -> [String: [KeyCombo]] {
        let co: KeyCombo.Modifiers = [.control, .option]
        let cos: KeyCombo.Modifiers = [.control, .option, .shift]
        let coc: KeyCombo.Modifiers = [.control, .option, .command]
        let cosc: KeyCombo.Modifiers = [.control, .option, .shift, .command]
        var b: [String: [KeyCombo]] = [:]
        func bind(_ c: Command, _ combos: KeyCombo...) { b[c.name] = combos }

        bind(.focus(.left), KeyCombo(KeyCode.h, co), KeyCombo(KeyCode.left, co))
        bind(.focus(.down), KeyCombo(KeyCode.j, co), KeyCombo(KeyCode.down, co))
        bind(.focus(.up), KeyCombo(KeyCode.k, co), KeyCombo(KeyCode.up, co))
        bind(.focus(.right), KeyCombo(KeyCode.l, co), KeyCombo(KeyCode.right, co))
        bind(.focusFirst, KeyCombo(KeyCode.left, coc))
        bind(.focusLast, KeyCombo(KeyCode.right, coc))
        bind(.move(.left), KeyCombo(KeyCode.h, cos), KeyCombo(KeyCode.left, cos))
        bind(.move(.down), KeyCombo(KeyCode.j, cos), KeyCombo(KeyCode.down, cos))
        bind(.move(.up), KeyCombo(KeyCode.k, cos), KeyCombo(KeyCode.up, cos))
        bind(.move(.right), KeyCombo(KeyCode.l, cos), KeyCombo(KeyCode.right, cos))
        bind(.moveFirst, KeyCombo(KeyCode.left, cosc))
        bind(.moveLast, KeyCombo(KeyCode.right, cosc))
        for (i, key) in KeyCode.digits.enumerated() {
            bind(.focusIndex(i + 1), KeyCombo(key, co))
            bind(.moveToIndex(i + 1), KeyCombo(key, cos))
        }
        bind(.cycleWidth, KeyCombo(KeyCode.r, co))
        bind(.cycleWidthBack, KeyCombo(KeyCode.r, cos))
        bind(.fullWidth, KeyCombo(KeyCode.f, co))
        bind(.center, KeyCombo(KeyCode.c, co))
        bind(.wider, KeyCombo(KeyCode.equal, co))
        bind(.narrower, KeyCombo(KeyCode.minus, co))
        bind(.taller, KeyCombo(KeyCode.equal, cos))
        bind(.shorter, KeyCombo(KeyCode.minus, cos))
        bind(.equalizeHeights, KeyCombo(KeyCode.zero, co))
        bind(.stackIntoLeft, KeyCombo(KeyCode.leftBracket, co))
        bind(.stackIntoRight, KeyCombo(KeyCode.rightBracket, co))
        bind(.popOut, KeyCombo(KeyCode.rightBracket, cos))
        bind(.popOutLeft, KeyCombo(KeyCode.leftBracket, cos))
        bind(.toggleTabbed, KeyCombo(KeyCode.t, cos))
        bind(.toggleFloat, KeyCombo(KeyCode.t, co))
        bind(.sendToNextDisplay, KeyCombo(KeyCode.n, co))
        bind(.pinLeft, KeyCombo(KeyCode.p, co))
        bind(.pinRight, KeyCombo(KeyCode.p, cos))
        bind(.stop, KeyCombo(KeyCode.q, co))
        bind(.showIndicator)
        bind(.retile)
        bind(.toggleRunning)
        bind(.openSettings, KeyCombo(KeyCode.comma, co))
        return b
    }
}
