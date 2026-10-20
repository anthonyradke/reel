import Foundation
import ReelCore

/// Which strip a window lives on: a display and one of its Spaces.
struct StripKey: Hashable, Codable, CustomStringConvertible {
    var display: String
    var space: UInt64
    var description: String { "\(display.prefix(8))/\(space)" }
}

/// Enough about a window to find it again after Reel (or the Mac) restarts.
struct WindowSignature: Codable, Hashable {
    var id: WindowID
    var bundleID: String?
    var title: String
}

struct SavedStrip: Codable {
    var key: StripKey
    var strip: Strip
    var signatures: [WindowID: WindowSignature]
}

struct SavedSession: Codable {
    var strips: [SavedStrip]
    var floating: [WindowSignature]
    var savedAt: Date
}

enum SessionStore {
    static var url: URL { ConfigStore.directory.appendingPathComponent("session.json") }

    static func load() -> SavedSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    static func save(_ s: SavedSession) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Matches windows that appear at startup against a saved session, so the strip comes back in
/// the same order with the same widths and stacks.
final class SessionRestorer {
    private var saved: [SavedStrip]
    private var claimed: Set<WindowID> = []

    init(_ session: SavedSession) {
        saved = session.strips
    }

    struct Match {
        var stripIndex: Int
        var savedID: WindowID
    }

    /// Finds the saved slot for a window: same window id first (Reel restarted, the app didn't),
    /// then same app and title, then same app.
    func match(id: WindowID, bundleID: String?, title: String) -> Match? {
        func find(_ pred: (WindowSignature) -> Bool) -> Match? {
            for (i, s) in saved.enumerated() {
                for (sid, sig) in s.signatures where !claimed.contains(sid) && pred(sig) {
                    return Match(stripIndex: i, savedID: sid)
                }
            }
            return nil
        }
        let m = find { $0.id == id && $0.bundleID == bundleID }
            ?? find { $0.bundleID == bundleID && !title.isEmpty && $0.title == title }
            ?? find { $0.bundleID == bundleID }
        if let m { claimed.insert(m.savedID) }
        return m
    }

    /// Builds restored strips from the windows that matched, keeping the saved order, widths,
    /// stacks and pins. Saved windows that never showed up are dropped.
    func build(matches: [(window: WindowID, match: Match)]) -> [Int: Strip] {
        var bySaved: [Int: [WindowID: WindowID]] = [:] // strip index -> saved id -> live id
        for (w, m) in matches { bySaved[m.stripIndex, default: [:]][m.savedID] = w }
        var out: [Int: Strip] = [:]
        for (i, map) in bySaved {
            var strip = saved[i].strip
            func remap(_ col: Column) -> Column? {
                var c = col
                var weights: [Double] = []
                var windows: [WindowID] = []
                for (r, id) in col.windows.enumerated() {
                    if let live = map[id] {
                        windows.append(live)
                        weights.append(col.weights.indices.contains(r) ? col.weights[r] : 1)
                    }
                }
                guard !windows.isEmpty else { return nil }
                c.windows = windows
                c.weights = weights
                return c
            }
            strip.columns = strip.columns.compactMap(remap)
            for side in PinSide.allCases {
                strip.pinned[side] = strip.pinned[side].flatMap(remap)
            }
            strip.sanitize()
            out[i] = strip
        }
        return out
    }

    func savedKey(_ i: Int) -> StripKey { saved[i].key }
}
