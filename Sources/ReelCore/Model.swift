import CoreGraphics
import Foundation

/// A window as the engine knows it. On macOS this is the CGWindowID.
public typealias WindowID = UInt32

/// How wide a column is.
public enum ColumnWidth: Codable, Equatable, Hashable {
    /// A share of the working area, 0...1.
    case proportion(Double)
    /// A fixed width in points.
    case fixed(Double)

    public func resolve(in available: Double, gap: Double) -> Double {
        switch self {
        case .proportion(let p):
            // Chosen so that two 0.5 columns fill the area exactly with one gap between them.
            return max(1, (available + gap) * p - gap)
        case .fixed(let w):
            return max(1, min(w, available))
        }
    }
}

/// One column on the strip. Usually it holds a single window; a stack holds several.
public struct Column: Codable, Equatable {
    /// One entry per row of the stack, top to bottom. A macOS native tab group counts as one
    /// entry (the app layer maps every tab to the group's id).
    public var windows: [WindowID]
    /// Relative height weights, one per window. Equal by default.
    public var weights: [Double]
    public var active: Int
    public var width: ColumnWidth
    public var tabbed: Bool
    /// The width to go back to when full width is toggled off.
    public var widthBeforeFull: ColumnWidth?

    public init(windows: [WindowID], width: ColumnWidth, tabbed: Bool = false) {
        self.windows = windows
        self.weights = Array(repeating: 1, count: windows.count)
        self.active = 0
        self.width = width
        self.tabbed = tabbed
        self.widthBeforeFull = nil
    }

    public var activeWindow: WindowID? {
        windows.indices.contains(active) ? windows[active] : windows.first
    }

    public var isFullWidth: Bool { widthBeforeFull != nil }

    mutating func clampActive() {
        if windows.isEmpty { active = 0; return }
        active = min(max(active, 0), windows.count - 1)
    }

    mutating func normalizeWeights() {
        if weights.count != windows.count {
            weights = Array(repeating: 1, count: windows.count)
        }
    }
}

public enum PinSide: String, Codable, CaseIterable {
    case left, right
}

public enum CenterMode: String, Codable, CaseIterable, Identifiable {
    case never
    case onOverflow
    case always

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .never: return "Never"
        case .onOverflow: return "When the strip overflows"
        case .always: return "Always"
        }
    }
}

/// One display's (and one Space's) strip of columns.
public struct Strip: Codable, Equatable {
    public var columns: [Column] = []
    /// Index into `columns` of the focused column, or -1 for none.
    public var focused: Int = -1
    /// Which part of the strip is shown: the strip x that sits at the left edge of the viewport.
    public var viewOffset: Double = 0
    public var pinned: [PinSide: Column] = [:]
    /// When focus is on a pinned column rather than the strip.
    public var focusedPin: PinSide?

    public init() {}

    public var isEmpty: Bool { columns.isEmpty && pinned.isEmpty }

    public var allWindows: [WindowID] {
        columns.flatMap(\.windows) + PinSide.allCases.compactMap { pinned[$0] }.flatMap(\.windows)
    }

    public var focusedWindow: WindowID? {
        if let side = focusedPin, let col = pinned[side] { return col.activeWindow }
        guard columns.indices.contains(focused) else { return nil }
        return columns[focused].activeWindow
    }

    public func locate(_ id: WindowID) -> WindowLocation? {
        for (c, col) in columns.enumerated() {
            if let r = col.windows.firstIndex(of: id) { return .strip(column: c, row: r) }
        }
        for side in PinSide.allCases {
            if let col = pinned[side], let r = col.windows.firstIndex(of: id) { return .pinned(side, row: r) }
        }
        return nil
    }

    public func contains(_ id: WindowID) -> Bool { locate(id) != nil }
}

public enum WindowLocation: Equatable {
    case strip(column: Int, row: Int)
    case pinned(PinSide, row: Int)
}
