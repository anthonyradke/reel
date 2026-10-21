import AppKit
import ReelCore

/// The engine. It owns every strip, decides where each window goes, and drives the animation.
/// Everything here runs on the main thread; only the actual AX frame writes happen elsewhere.
final class WindowManager: WindowTrackerDelegate {
    static let shared = WindowManager()

    let tracker = WindowTracker()
    let animator = Animator()
    let overlays = OverlayController()

    private(set) var running = false
    var config: Config { ConfigStore.shared.config }

    private(set) var strips: [StripKey: Strip] = [:]
    private(set) var displays: [Display] = []
    /// The strip each display is showing right now (its current Space).
    private(set) var activeKeys: [String: StripKey] = [:]
    /// The strip keyboard commands act on.
    private(set) var focusedKey: StripKey?

    /// Windows floating by choice (shortcut or rule) or because they look like dialogs.
    private var floating: Set<WindowID> = []
    private var userFloated: Set<WindowID> = []
    private var userTiled: Set<WindowID> = []
    /// Native macOS tab groups: group id -> member windows, and the member currently shown.
    private var tabGroups: [WindowID: [WindowID]] = [:]
    private var activeTab: [WindowID: WindowID] = [:]
    /// Windows that left the strip because their app was hidden or they were minimised, with
    /// where they were, so they come back to the same place.
    private var parkedForHide: [WindowID: (key: StripKey, index: Int, width: ColumnWidth)] = [:]

    private var restorer: SessionRestorer?
    private var restoreMatches: [(window: WindowID, match: SessionRestorer.Match)] = []
    private var bulkAdding = false
    private var pendingBulk: [TrackedWindow] = []

    private var drag: DragState?
    private var mouseMonitors: [Any] = []
    private var systemObservers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var saveWork: DispatchWorkItem?
    private var lastFocusedWindow: WindowID?
    private var gesture: GestureState?
    /// Times the heal pass put a window back at a given target, so it gives up on windows that won't stay.
    private var healAttempts: [WindowID: (target: CGRect, tries: Int)] = [:]
    private var wakeWork: DispatchWorkItem?

    var onStateChange: (() -> Void)?

    struct DragState {
        var window: WindowID
        var startFrame: CGRect
        var resized = false
    }

    struct GestureState {
        var key: StripKey
        var startOffset: Double
        var lastTime: CFTimeInterval
        var velocity: Double = 0
    }

    private init() {
        tracker.delegate = self
        animator.manager = self
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        guard AX.isTrusted else {
            Log.engine("start refused: no Accessibility permission")
            AX.promptForTrust()
            onStateChange?()
            return
        }
        running = true
        Log.engine("engine starting")
        AX.setGlobalTimeout(0.5)
        refreshDisplays()
        let session = config.restoreSession ? SessionStore.load() : nil
        if let session { restorer = SessionRestorer(session) }
        bulkAdding = true
        tracker.start()
        bulkAdding = false
        for (id, width) in session?.minWidths ?? [:] { tracker.windows[id]?.minWidth = CGFloat(width) }
        for (id, width) in session?.maxWidths ?? [:] { tracker.windows[id]?.maxWidth = CGFloat(width) }
        finishBulkAdd()
        // Saved scroll positions were for the old widths; aim each strip at its focus again.
        for k in Array(strips.keys) {
            strips[k]?.sanitize()
            ensureFocusedVisible(k, previous: nil)
        }
        installMonitors()
        HotkeyManager.shared.enable(bindings: config.bindings)
        GestureMonitor.shared.start()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.heal() }
        if let w = tracker.focusedWindow() { tracker(tracker, focusChangedTo: w) }
        layoutAll(animated: false)
        onStateChange?()
    }

    func stop() {
        guard running else { return }
        Log.engine("engine stopping")
        saveSessionNow()
        running = false
        watchdog?.invalidate()
        watchdog = nil
        HotkeyManager.shared.disable(keepStartBinding: true)
        GestureMonitor.shared.stop()
        removeMonitors()
        animator.stopAll()
        bringBackParkedWindows()
        overlays.hideAll()
        tracker.stop()
        strips.removeAll()
        floating.removeAll()
        tabGroups.removeAll()
        activeTab.removeAll()
        parkedForHide.removeAll()
        onStateChange?()
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.start() }
    }

    /// Every window we pushed off screen goes back on screen, so stopping never loses a window.
    private func bringBackParkedWindows() {
        for d in displays {
            guard let key = activeKeys[d.uuid], let strip = strips[key] else { continue }
            let area = d.usableArea(respectDock: config.respectDock)
            var cascade: CGFloat = 0
            for id in strip.allWindows {
                for member in members(of: id) {
                    guard let w = tracker.windows[member], let f = w.frame else { continue }
                    if !area.intersects(f.insetBy(dx: 40, dy: 40)) {
                        let origin = CGPoint(x: area.minX + 40 + cascade, y: area.minY + 40 + cascade)
                        w.app.mover.set(w.element, app: w.app.element, id: w.id, origin: origin, size: nil)
                        cascade = (cascade + 30).truncatingRemainder(dividingBy: 300)
                    }
                }
            }
        }
    }

    func configChanged(_ new: Config, old: Config) {
        guard running else { return }
        if new.bindings != old.bindings { HotkeyManager.shared.enable(bindings: new.bindings) }
        if new.swipeFingers != old.swipeFingers { GestureMonitor.shared.restart() }
        if new.disabledDisplays != old.disabledDisplays {
            // Displays switched back on pick up their windows again.
            tracker.rescan()
            for d in new.disabledDisplays where !old.disabledDisplays.contains(d) {
                for (k, s) in strips where k.display == d {
                    for id in s.allWindows { floating.remove(id) }
                    strips[k] = nil
                }
            }
        }
        if new.focusFollowsMouse != old.focusFollowsMouse { removeMonitors(); installMonitors() }
        for key in Array(strips.keys) { strips[key]?.sanitize() }
        for key in activeKeys.values { ensureFocusedVisible(key, previous: nil) }
        layoutAll(animated: true)
    }

    // MARK: - Displays and Spaces

    func refreshDisplays() {
        displays = Displays.current()
        refreshSpaces()
    }

    func refreshSpaces() {
        let spaces = SkyLight.currentSpaces()
        var keys: [String: StripKey] = [:]
        for d in displays {
            let space = spaces.perDisplay[d.uuid] ?? spaces.shared ?? 0
            keys[d.uuid] = StripKey(display: d.uuid, space: space)
        }
        activeKeys = keys
        if let fk = focusedKey, !activeKeys.values.contains(fk) {
            focusedKey = activeKeys[fk.display] ?? activeKeys.values.first
        }
        if focusedKey == nil { focusedKey = mainKey }
    }

    private var mainKey: StripKey? {
        guard let main = displays.first else { return nil }
        return activeKeys[main.uuid]
    }

    func display(for key: StripKey) -> Display? {
        displays.first { $0.uuid == key.display }
    }

    func isManaged(display uuid: String) -> Bool {
        !config.disabledDisplays.contains(uuid)
    }

    private func spaceChanged() {
        guard running else { return }
        let before = activeKeys
        refreshSpaces()
        tracker.rescan()
        reassignWindowsToCurrentSpaces()
        if before != activeKeys { Log.engine("space changed") }
        layoutAll(animated: false)
        if let w = tracker.focusedWindow() { tracker(tracker, focusChangedTo: w) }
    }

    private func screensChanged() {
        guard running else { return }
        let oldDisplays = Set(displays.map(\.uuid))
        refreshDisplays()
        let gone = oldDisplays.subtracting(displays.map(\.uuid))
        // Windows on a display that was unplugged join the main display's strip.
        if !gone.isEmpty, let main = mainKey {
            for (k, s) in strips where gone.contains(k.display) {
                var target = strips[main] ?? Strip()
                for col in s.columns + PinSide.allCases.compactMap({ s.pinned[$0] }) {
                    for id in col.windows {
                        target.insert(id, width: col.width, at: .end, focus: false)
                    }
                }
                strips[main] = target
                strips[k] = nil
            }
            Log.engine("display removed, windows moved to main display")
        }
        Log.engine("displays: \(displays.map { "\($0.name) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ", "))")
        layoutAll(animated: false)
    }

    /// Picks up windows the user moved to another Space with Mission Control.
    private func reassignWindowsToCurrentSpaces() {
        let activeSpaces = Dictionary(uniqueKeysWithValues: activeKeys.values.map { ($0.space, $0) })
        for (key, strip) in strips {
            for id in strip.allWindows {
                let spaces = SkyLight.spaces(for: id)
                guard let s = spaces.first, s != key.space, let newKey = activeSpaces[s] else { continue }
                strips[key]?.remove(id)
                var t = strips[newKey] ?? Strip()
                t.insert(id, width: .proportion(config.defaultWidth), at: .rightOfFocused, focus: false)
                strips[newKey] = t
            }
        }
    }

    // MARK: - Deciding what tiles

    private func rule(for w: TrackedWindow) -> WindowRule? {
        config.rules.first { $0.matches(bundleID: w.app.bundleID, title: w.title) }
    }

    private func shouldTile(_ w: TrackedWindow) -> Bool {
        if userFloated.contains(w.id) { return false }
        if w.isMinimized || w.isFullscreen { return false }
        if w.app.runningApp?.isHidden == true { return false }
        if let r = rule(for: w) {
            if r.action == .float { return false }
            if r.action == .tile || userTiled.contains(w.id) { return true }
        }
        if userTiled.contains(w.id) { return true }
        // Dialogs, panels, Quick Look and the like float on their own.
        guard w.subrole == kAXStandardWindowSubrole else { return false }
        if let bid = w.app.bundleID, Self.alwaysFloat.contains(where: { bid.hasPrefix($0) }) { return false }
        if let f = w.frame, f.width < 120 || f.height < 80 { return false }
        if config.floatFixedSizeWindows && !isResizable(w) { return false }
        return true
    }

    private static let alwaysFloat = [
        "com.apple.quicklook", "com.apple.QuickLookUIService", "com.apple.systempreferences.AccessibilitySettingsExtension",
        "com.apple.ScreenSaver", "com.apple.PIPAgent", "com.apple.screencaptureui",
    ]

    /// A window with no zoom button, or one that's disabled, has a fixed size (Calculator,
    /// most settings windows). Tiling those only squashes or stretches them.
    private func isResizable(_ w: TrackedWindow) -> Bool {
        if !AX.isSettable(w.element, kAXSizeAttribute) { return false }
        guard let zoom = AX.element(w.element, kAXZoomButtonAttribute) else { return false }
        return AX.bool(zoom, kAXEnabledAttribute) ?? true
    }

    private func key(for w: TrackedWindow) -> StripKey? {
        let frame = w.frame ?? .zero
        guard let d = Displays.display(for: frame, in: displays) else { return mainKey }
        guard isManaged(display: d.uuid) else { return nil }
        let active = activeKeys[d.uuid]
        if let space = SkyLight.spaces(for: w.id).first {
            if SkyLight.isFullscreenSpace(space) { return nil }
            // Windows on another display's current Space belong there.
            if let k = activeKeys.values.first(where: { $0.space == space }) { return k }
            return StripKey(display: d.uuid, space: space)
        }
        return active
    }

    func key(containing id: WindowID) -> StripKey? {
        strips.first { $0.value.contains(id) }?.key
    }

    // MARK: - Native tabs

    private func members(of group: WindowID) -> [WindowID] {
        tabGroups[group] ?? [group]
    }

    private func groupID(of id: WindowID) -> WindowID {
        tracker.windows[id]?.group ?? id
    }

    /// The window of a group that's on screen right now.
    private func visibleMember(of group: WindowID) -> WindowID {
        activeTab[group] ?? group
    }

    /// A new window that's really a new native tab shares the frame of a sibling that just went
    /// off screen. Returns the group it joins.
    private func tabGroupToJoin(_ w: TrackedWindow) -> WindowID? {
        guard let f = w.frame else { return nil }
        let onScreen = Set(WindowTracker.onScreenWindowIDs())
        for other in tracker.windows.values where other.id != w.id && other.app.pid == w.app.pid {
            guard key(containing: other.group) != nil, let of = other.frame else { continue }
            let same = abs(of.minX - f.minX) < 2 && abs(of.minY - f.minY) < 2 && abs(of.width - f.width) < 2 && abs(of.height - f.height) < 2
            guard same else { continue }
            // Tabs: exactly one of the pair is drawn.
            if onScreen.contains(w.id) != onScreen.contains(other.id) { return other.group }
        }
        return nil
    }

    private func join(_ w: TrackedWindow, group: WindowID) {
        w.group = group
        var m = tabGroups[group] ?? [group]
        if !m.contains(w.id) { m.append(w.id) }
        tabGroups[group] = m
        activeTab[group] = w.id
        Log.engine("\(w.app.name): window \(w.id) is a tab of \(group)")
    }

    private func leaveGroup(_ id: WindowID) {
        let group = groupID(of: id)
        guard var m = tabGroups[group] else { return }
        m.removeAll { $0 == id }
        if group == id, let heir = m.first {
            // The group's id was this window; hand the strip slot to another tab.
            tabGroups[group] = nil
            activeTab[group] = nil
            for k in Array(strips.keys) { strips[k]?.replace(id, with: heir) }
            for other in m { tracker.windows[other]?.group = heir }
            if m.count > 1 { tabGroups[heir] = m; activeTab[heir] = m.first } else { tabGroups[heir] = nil }
        } else {
            tabGroups[group] = m.count > 1 ? m : nil
            if activeTab[group] == id { activeTab[group] = m.first }
            if m.count <= 1 { activeTab[group] = nil }
        }
        tracker.windows[id]?.group = id
    }

    // MARK: - Tracker events

    func tracker(_ t: WindowTracker, didAdd w: TrackedWindow) {
        guard running || bulkAdding else { return }
        if bulkAdding { pendingBulk.append(w); return }
        place(w, initial: false)
    }

    private func finishBulkAdd() {
        // Windows that were already open line up on the strip left to right as they were.
        let sorted = pendingBulk.sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
        pendingBulk.removeAll()
        var unmatched: [TrackedWindow] = []
        for w in sorted {
            if restorer?.wasFloating(id: w.id, bundleID: w.app.bundleID, title: w.title) == true { userFloated.insert(w.id) }
            guard shouldTile(w) else { floating.insert(w.id); continue }
            if let r = restorer, let m = r.match(id: w.id, bundleID: w.app.bundleID, title: w.title) {
                restoreMatches.append((w.id, m))
            } else {
                unmatched.append(w)
            }
        }
        if let r = restorer {
            for (i, strip) in r.build(matches: restoreMatches) {
                var key = r.savedKey(i)
                if !activeKeys.values.contains(key), let k = activeKeys[key.display] ?? (key.space == 0 ? mainKey : nil) {
                    // Space ids change across logins; the display's current Space takes it.
                    if strips[k] == nil { key = k }
                }
                if strips[key] == nil { strips[key] = strip } else {
                    for id in strip.allWindows { strips[key]!.insert(id, width: .proportion(config.defaultWidth), at: .end, focus: false) }
                }
            }
            if !restoreMatches.isEmpty { Log.engine("restored \(restoreMatches.count) windows from the last session") }
        }
        restorer = nil
        restoreMatches.removeAll()
        for w in unmatched { place(w, initial: true) }
    }

    private func place(_ w: TrackedWindow, initial: Bool) {
        guard key(containing: w.group) == nil else { return }
        if !initial, let g = tabGroupToJoin(w) {
            join(w, group: g)
            if let k = key(containing: g) { layout(k, animated: true) }
            return
        }
        guard shouldTile(w) else {
            floating.insert(w.id)
            return
        }
        guard let k = key(for: w) else { return }
        floating.remove(w.id)
        var strip = strips[k] ?? Strip()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == w.app.pid
        // A window from an app in the background slots in without taking focus.
        let focus = !initial && frontmost
        let r = rule(for: w)
        var width = r?.width.map { ColumnWidth.proportion($0) } ?? .proportion(config.defaultWidth)
        var position: Strip.InsertPosition = config.newWindowPlacement == .endOfStrip || initial ? .end : .rightOfFocused
        if let back = parkedForHide.removeValue(forKey: w.id), back.key == k {
            position = .index(back.index)
            width = back.width
        } else if let r, r.action == .slot {
            position = r.slot <= 0 ? .end : .index(r.slot - 1)
        }
        let previous = strip.focused
        strip.insert(w.id, width: width, at: position, focus: focus)
        strips[k] = strip
        Log.engine("tile \(w.app.name) \"\(w.title)\" (\(w.id)) on \(k)")
        if focus {
            focusedKey = k
            ensureFocusedVisible(k, previous: previous)
        }
        layout(k, animated: !initial)
        scheduleSave()
    }

    func tracker(_ t: WindowTracker, didRemove w: TrackedWindow) {
        animator.forget(w.id)
        healAttempts[w.id] = nil
        floating.remove(w.id)
        userFloated.remove(w.id)
        userTiled.remove(w.id)
        if tabGroups[w.group] != nil || w.group != w.id {
            leaveGroup(w.id)
            if let k = key(containing: groupID(of: w.id)) { layout(k, animated: true) }
            return
        }
        guard running, let k = key(containing: w.id) else { return }
        let previous = strips[k]?.focused
        strips[k]?.remove(w.id)
        if strips[k]?.isEmpty == true { strips[k] = Strip() }
        ensureFocusedVisible(k, previous: previous)
        layout(k, animated: true)
        // Focus moves to the neighbour that took the closed window's place.
        if k == focusedKey, NSWorkspace.shared.frontmostApplication?.processIdentifier == w.app.pid
            || tracker.focusedWindow() == nil {
            if let next = strips[k]?.focusedWindow { focusWindow(next, raise: true) }
        }
        scheduleSave()
    }

    func tracker(_ t: WindowTracker, focusChangedTo w: TrackedWindow?) {
        guard running, let w else { return }
        let group = w.group
        if tabGroups[group] != nil {
            activeTab[group] = w.id
        }
        lastFocusedWindow = w.id
        guard let k = key(containing: group) else {
            // A window we haven't placed yet (for example one that just lost its float status).
            if !floating.contains(w.id), tracker.windows[w.id] != nil { place(w, initial: false) }
            overlays.updateFocus(nil)
            return
        }
        var strip = strips[k]!
        let previous = strip.focused
        let changed = strip.focusedWindow != group || focusedKey != k
        strip.focusWindow(group)
        strips[k] = strip
        focusedKey = k
        if changed {
            ensureFocusedVisible(k, previous: previous)
            layout(k, animated: true)
        } else {
            overlays.updateFocus(placementFrame(of: group, in: k))
        }
    }

    func tracker(_ t: WindowTracker, windowMoved w: TrackedWindow) {
        guard running else { return }
        // Our own animation frames: nothing to look into (and asking the app costs a round trip).
        if CACurrentMediaTime() - w.lastCommandedAt < 0.3 && drag?.window != w.group { return }
        if isUserAction(w) {
            if drag == nil, key(containing: w.group) != nil {
                drag = DragState(window: w.group, startFrame: w.lastCommanded ?? (w.frame ?? .zero))
                animator.freeze(w.group)
                // The border would stay behind while the window is dragged away.
                overlays.updateFocus(nil)
            }
        }
        if w.isFullscreen, let k = key(containing: w.group) {
            // Native full screen: let go of the window entirely until it comes back.
            strips[k]?.remove(w.group)
            layout(k, animated: true)
        }
        overlays.windowMoved(w.id)
    }

    func tracker(_ t: WindowTracker, windowResized w: TrackedWindow) {
        guard running else { return }
        if CACurrentMediaTime() - w.lastCommandedAt < 0.3 && drag?.window != w.group { return }
        if isUserAction(w) {
            if drag == nil, key(containing: w.group) != nil {
                drag = DragState(window: w.group, startFrame: w.lastCommanded ?? (w.frame ?? .zero))
                animator.freeze(w.group)
            }
            drag?.resized = true
            return
        }
        if w.isFullscreen {
            if let k = key(containing: w.group) {
                strips[k]?.remove(w.group)
                layout(k, animated: true)
            }
            return
        }
        // Came back from full screen.
        if key(containing: w.group) == nil && !floating.contains(w.id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.tracker.windows[w.id] != nil, !w.isFullscreen else { return }
                self.place(w, initial: false)
            }
            return
        }
    }

    func tracker(_ t: WindowTracker, sizeRefused w: TrackedWindow, asked: CGSize, actual: CGSize) {
        // Only trust the report if that's still the size we want; a later command may have
        // changed it while this one was in flight.
        guard running, let want = w.lastCommanded, abs(want.width - asked.width) < 1 else { return }
        if actual.width > asked.width {
            guard (w.minWidth ?? 0) + 2 < actual.width else { return }
            w.minWidth = actual.width
            Log.engine("\(w.app.name) \(w.id) keeps a minimum width of \(Int(actual.width)) (asked for \(Int(asked.width)))")
        } else {
            guard w.maxWidth.map({ abs($0 - actual.width) > 2 }) ?? true else { return }
            w.maxWidth = actual.width
            Log.engine("\(w.app.name) \(w.id) keeps a maximum width of \(Int(actual.width)) (asked for \(Int(asked.width)))")
        }
        scheduleSave()
        if let k = key(containing: w.group) {
            ensureFocusedVisible(k, previous: nil)
            layout(k, animated: true)
        }
    }

    func tracker(_ t: WindowTracker, minimizedChanged w: TrackedWindow, minimized: Bool) {
        guard running else { return }
        if minimized {
            if let k = key(containing: w.group), case .strip(let c, _)? = strips[k]?.locate(w.group) {
                parkedForHide[w.group] = (k, c, strips[k]!.columns[c].width)
                strips[k]?.remove(w.group)
                ensureFocusedVisible(k, previous: nil)
                layout(k, animated: true)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.place(w, initial: false) }
        }
    }

    func tracker(_ t: WindowTracker, appHidden app: TrackedApp, hidden: Bool) {
        guard running else { return }
        let wins = tracker.windows.values.filter { $0.app.pid == app.pid }
        if hidden {
            // Note every window's place before taking any out, or the later ones shift.
            var spots: [(id: WindowID, key: StripKey, column: Int, width: ColumnWidth)] = []
            for w in wins {
                guard let k = key(containing: w.group), case .strip(let c, _)? = strips[k]?.locate(w.group),
                      !spots.contains(where: { $0.id == w.group }) else { continue }
                spots.append((w.group, k, c, strips[k]!.columns[c].width))
            }
            var touched: Set<StripKey> = []
            for spot in spots {
                parkedForHide[spot.id] = (spot.key, spot.column, spot.width)
                strips[spot.key]?.remove(spot.id)
                touched.insert(spot.key)
            }
            for k in touched {
                ensureFocusedVisible(k, previous: nil)
                layout(k, animated: true)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let back = wins.sorted { (self.parkedForHide[$0.group]?.index ?? .max) < (self.parkedForHide[$1.group]?.index ?? .max) }
                for w in back where w.group == w.id { self.place(w, initial: false) }
            }
        }
    }

    func tracker(_ t: WindowTracker, titleChanged w: TrackedWindow) {
        overlays.titleChanged(w.id)
        scheduleSave()
    }

    private func isUserAction(_ w: TrackedWindow) -> Bool {
        // The user is dragging or resizing when the mouse is down and we didn't just move it.
        guard NSEvent.pressedMouseButtons & 1 == 1 else { return false }
        return CACurrentMediaTime() - w.lastCommandedAt > 0.25 || drag?.window == w.group
    }

    // MARK: - Mouse

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.mouseUp()
        }) { mouseMonitors.append(m) }
        if config.focusFollowsMouse, let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.mouseMoved()
        }) { mouseMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.overlays.modifiersChanged(e.modifierFlags)
        }) { mouseMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.overlays.modifiersChanged(e.modifierFlags)
            return e
        }) { mouseMonitors.append(m) }

        let nc = NSWorkspace.shared.notificationCenter
        let main = OperationQueue.main
        systemObservers.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: main) { [weak self] _ in
            // Mission Control animates the switch; read the new Space once it's done.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.spaceChanged() }
        })
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            systemObservers.append(nc.addObserver(forName: n, object: nil, queue: main) { [weak self] _ in
                self?.scheduleWakeRecovery(after: 1.0)
            })
        }
        systemObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.screensChanged() }
        })
        systemObservers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: main) { [weak self] _ in
            self?.scheduleWakeRecovery(after: 0.8)
        })
    }

    private func removeMonitors() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        systemObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
            DistributedNotificationCenter.default().removeObserver($0)
        }
        systemObservers.removeAll()
    }

    /// Wake, screen wake, session switch and unlock tend to arrive together; recover once.
    private func scheduleWakeRecovery(after delay: TimeInterval) {
        wakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recoverAfterWake() }
        wakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func recoverAfterWake() {
        guard running else { return }
        Log.engine("recovering after wake or unlock")
        refreshDisplays()
        tracker.rescan()
        reassignWindowsToCurrentSpaces()
        HotkeyManager.shared.enable(bindings: config.bindings)
        GestureMonitor.shared.restart()
        layoutAll(animated: false)
    }

    private func mouseUp() {
        guard running, let d = drag else { return }
        drag = nil
        animator.unfreeze(d.window)
        guard let k = key(containing: d.window), let w = tracker.windows[visibleMember(of: d.window)], let f = w.frame else { return }
        if d.resized {
            // The user resized a window by hand: that's its column's width now.
            if strips[k]?.focusWindow(d.window) == true, let disp = display(for: k) {
                let geo = StripGeometry(strip: strips[k]!, context: context(for: k, display: disp))
                let p = (Double(f.width) + config.gap) / (geo.viewportWidth + config.gap)
                _ = strips[k]?.setWidth(.proportion(min(1, max(0.1, p))))
                w.minWidth = nil
                w.maxWidth = nil
            }
            ensureFocusedVisible(k, previous: nil)
            layout(k, animated: true)
            scheduleSave()
            return
        }
        let moved = abs(f.minX - d.startFrame.minX) > 20 || abs(f.minY - d.startFrame.minY) > 20
        guard moved else { layout(k, animated: true); return }
        let cursor = NSEvent.mouseLocation
        let p = CGPoint(x: cursor.x, y: Displays.primaryHeight - cursor.y)
        if let targetDisplay = Displays.display(containing: p, in: displays), let tk = activeKeys[targetDisplay.uuid],
           tk != k, isManaged(display: targetDisplay.uuid) {
            // Dropped on another display: it joins that display's strip.
            moveWindow(d.window, from: k, to: tk)
            return
        }
        if config.dragToReorder, let strip = strips[k], let disp = display(for: k) {
            let result = Layout.compute(strip, context: context(for: k, display: disp))
            if let target = result.columnFrames.firstIndex(where: { $0.minX <= p.x && p.x <= $0.maxX }),
               case .strip(let from, _)? = strip.locate(d.window), target != from {
                var s = strip
                if s.columns[from].windows.count > 1 {
                    _ = s.focusWindow(d.window)
                    _ = s.popOut(target > from ? .right : .left)
                    if case .strip(let now, _)? = s.locate(d.window) { _ = s.reorderColumn(from: now, to: target) }
                } else {
                    _ = s.reorderColumn(from: from, to: target)
                }
                _ = s.focusWindow(d.window)
                strips[k] = s
                Log.engine("dragged column \(from) to \(target)")
                scheduleSave()
            }
        }
        layout(k, animated: true)
    }

    private var lastHover: CFTimeInterval = 0
    private func mouseMoved() {
        guard running, config.focusFollowsMouse, drag == nil, NSEvent.pressedMouseButtons == 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastHover > 0.08 else { return }
        lastHover = now
        let loc = NSEvent.mouseLocation
        let p = CGPoint(x: loc.x, y: Displays.primaryHeight - loc.y)
        guard let d = Displays.display(containing: p, in: displays), let k = activeKeys[d.uuid], let strip = strips[k] else { return }
        let result = Layout.compute(strip, context: context(for: k, display: d))
        guard let hit = result.placements.first(where: { $0.visible && $0.frame.contains(p) }) else { return }
        guard hit.id != strip.focusedWindow || k != focusedKey else { return }
        var s = strip
        s.focusWindow(hit.id)
        strips[k] = s
        focusedKey = k
        // Focus follows the mouse without scrolling: the window is already under the pointer.
        focusWindow(hit.id, raise: true, warp: false)
        layout(k, animated: true)
    }

    // MARK: - Self healing

    private func heal() {
        guard running else { return }
        if !AX.isTrusted {
            Log.engine("Accessibility permission was revoked; stopping")
            stop()
            return
        }
        tracker.pruneDeadWindows()
        // Re-apply frames to windows an app moved behind our back (outside of any animation).
        guard drag == nil, gesture == nil, !animator.isRunning, NSEvent.pressedMouseButtons == 0 else { return }
        let now = CACurrentMediaTime()
        for k in activeKeys.values {
            guard let strip = strips[k], let d = display(for: k) else { continue }
            let result = Layout.compute(strip, context: context(for: k, display: d))
            var drifted = false
            for p in result.placements where p.visible {
                let id = visibleMember(of: p.id)
                guard let w = tracker.windows[id], let f = w.frame, now - w.lastCommandedAt > 1.5 else { continue }
                let target = p.frame.pixelAligned
                if w.minWidth == nil, f.width > target.width + 4, abs(f.minX - target.minX) <= 6 {
                    // The app widened itself after the fact: that's its minimum width.
                    w.minWidth = f.width
                    drifted = true
                    Log.engine("\(w.app.name) \(id) widened itself to \(Int(f.width)) (wanted \(Int(target.width)))")
                    scheduleSave()
                    continue
                }
                if w.maxWidth == nil, f.width < target.width - 4, abs(f.minX - target.minX) <= 6 {
                    // It stopped short of the column: that's its maximum width.
                    w.maxWidth = f.width
                    drifted = true
                    Log.engine("\(w.app.name) \(id) stopped at \(Int(f.width)) wide (wanted \(Int(target.width)))")
                    scheduleSave()
                    continue
                }
                let moved = abs(f.minX - target.minX) > 6 || abs(f.minY - target.minY) > 6
                let resized = !p.keepsHeight && (abs(f.height - target.height) > 6 ||
                    (w.minWidth == nil && w.maxWidth == nil && abs(f.width - target.width) > 6))
                guard moved || resized else { healAttempts[id] = nil; continue }
                // Some windows can't go where we ask (an app pins its own size or position).
                // Try a few times, then leave them be until something changes.
                let tries = healAttempts[id].flatMap { $0.target == target ? $0.tries : nil } ?? 0
                guard tries < 3 else { continue }
                healAttempts[id] = (target, tries + 1)
                animator.invalidate(id)
                drifted = true
                Log.engine("\(w.app.name) \(id) drifted to \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)); putting it back")
            }
            if drifted {
                ensureFocusedVisible(k, previous: nil)
                layout(k, animated: true)
            }
        }
    }

    // MARK: - Layout

    func context(for key: StripKey, display d: Display) -> LayoutContext {
        var ctx = LayoutContext(area: d.usableArea(respectDock: config.respectDock), displayFrame: d.frame, config: config)
        let n = Displays.neighbors(of: d, in: displays)
        ctx.neighborLeft = n.left
        ctx.neighborRight = n.right
        if let strip = strips[key] {
            for id in strip.allWindows {
                if let w = tracker.windows[visibleMember(of: id)] {
                    if let m = w.minWidth { ctx.minWidths[id] = Double(m) }
                    if let m = w.maxWidth { ctx.maxWidths[id] = Double(m) }
                    ctx.originalHeights[id] = Double(w.originalHeight)
                }
            }
        }
        return ctx
    }

    /// Scrolls the strip so the focused column is in view, the way the centre mode says.
    func ensureFocusedVisible(_ key: StripKey, previous: Int?) {
        // While fingers are on the trackpad they own the scroll position. Anything else that
        // scrolls (a focus change, a window learning its minimum width) would yank the strip
        // out from under them.
        guard gesture?.key != key else { return }
        guard var strip = strips[key], let d = display(for: key) else { return }
        guard strip.focusedPin == nil, strip.columns.indices.contains(strip.focused) else {
            if let d = display(for: key) {
                let geo = StripGeometry(strip: strip, context: context(for: key, display: d))
                strip.viewOffset = config.centerMode == .always ? strip.viewOffset : geo.clampOffset(strip.viewOffset)
                strips[key] = strip
            }
            return
        }
        let geo = StripGeometry(strip: strip, context: context(for: key, display: d))
        strip.viewOffset = geo.offset(toShow: strip.focused, from: strip.viewOffset, previous: previous, mode: config.centerMode)
        strips[key] = strip
    }

    func layoutAll(animated: Bool) {
        let shown = Set(activeKeys.filter { isManaged(display: $0.key) }.values)
        overlays.retain(only: shown)
        for k in shown { layout(k, animated: animated) }
    }

    func layout(_ key: StripKey, animated: Bool) {
        // A Space with nothing tiled still gets laid out, so overlays from elsewhere go away.
        guard running, let d = display(for: key), activeKeys[d.uuid] == key, isManaged(display: d.uuid) else { return }
        let strip = strips[key] ?? Strip()
        let ctx = context(for: key, display: d)
        let result = Layout.compute(strip, context: ctx)
        let animate = animated && config.animate && gesture?.key != key
        for p in result.placements {
            let shown = visibleMember(of: p.id)
            for member in members(of: p.id) {
                guard let w = tracker.windows[member], drag?.window != p.id || member != shown else { continue }
                if member != shown {
                    // Hidden native tabs ride along with the visible one; macOS keeps them in sync.
                    continue
                }
                var frame = p.frame
                if p.keepsHeight, let f = w.frame { frame.size.height = min(frame.height, f.height) }
                animator.setTarget(w, frame: frame.pixelAligned, visible: p.visible, hiddenSide: p.hiddenSide ?? .right,
                                   display: d, animated: animate)
            }
        }
        let live = gesture?.key == key
        overlays.update(key: key, result: result, strip: strip, display: d, isFocusedStrip: key == focusedKey, live: live)
        if key == focusedKey {
            overlays.updateFocus(strip.focusedWindow.flatMap { id in result.placements.first { $0.id == id && $0.visible }?.frame }, live: live)
        }
        onStateChange?()
    }

    private func placementFrame(of id: WindowID, in key: StripKey) -> CGRect? {
        guard let strip = strips[key], let d = display(for: key) else { return nil }
        return Layout.compute(strip, context: context(for: key, display: d)).placements.first { $0.id == id && $0.visible }?.frame
    }

    /// Called by the animator every frame so the focus border can follow a moving window.
    func animationFrame() {
        overlays.followAnimation(animator)
    }

    // MARK: - Focus

    func focusWindow(_ group: WindowID, raise: Bool, warp: Bool? = nil) {
        let id = visibleMember(of: group)
        guard let w = tracker.windows[id] else { return }
        lastFocusedWindow = id
        if !SkyLight.focus(pid: w.app.pid, window: id) {
            w.app.runningApp?.activate(options: [])
        }
        if raise { AX.raise(w.element) }
        AX.set(w.element, kAXMainAttribute, kCFBooleanTrue)
        if warp ?? config.mouseFollowsFocus, let f = animator.targetFrame(of: id) ?? w.frame {
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
        }
    }

    // MARK: - Commands

    /// The strip commands act on: the one with the focused window, else the display under the mouse.
    /// The strip the indicator shows when it's called up by hand.
    func indicatorKey() -> StripKey? { commandKey() }

    private func commandKey() -> StripKey? {
        if let k = focusedKey, activeKeys.values.contains(k) { return k }
        let loc = NSEvent.mouseLocation
        let p = CGPoint(x: loc.x, y: Displays.primaryHeight - loc.y)
        if let d = Displays.display(containing: p, in: displays) { return activeKeys[d.uuid] }
        return mainKey
    }

    func perform(_ cmd: Command) {
        switch cmd {
        case .start: start(); return
        case .stop: stop(); return
        case .toggleRunning: running ? stop() : start(); return
        case .openSettings: AppDelegate.shared?.openSettings(nil); return
        case .retile:
            if running { tracker.rescan(); layoutAll(animated: true) }
            return
        default: break
        }
        guard running, let k = commandKey(), var strip = strips[k], let d = display(for: k) else { return }
        let ctx = context(for: k, display: d)
        let geo = StripGeometry(strip: strip, context: ctx)
        let before = strip.focusedWindow
        let previous = strip.focused
        var changed = false
        var scroll = true
        var showIndicator = true

        switch cmd {
        case .focus(.left): changed = strip.focusLeft()
        case .focus(.right): changed = strip.focusRight()
        case .focus(.up): changed = strip.focusVertical(-1)
        case .focus(.down): changed = strip.focusVertical(1)
        case .focusFirst: changed = strip.focusColumn(0)
        case .focusLast: changed = strip.focusColumn(strip.columns.count - 1)
        case .focusIndex(let n): changed = strip.focusColumn(n >= 9 ? strip.columns.count - 1 : n - 1)
        case .move(.left): changed = strip.moveColumn(by: -1)
        case .move(.right): changed = strip.moveColumn(by: 1)
        case .move(.up): changed = strip.moveInStack(by: -1)
        case .move(.down): changed = strip.moveInStack(by: 1)
        case .moveFirst: changed = strip.moveColumn(to: 0)
        case .moveLast: changed = strip.moveColumn(to: strip.columns.count - 1)
        case .moveToIndex(let n): changed = strip.moveColumn(to: n >= 9 ? strip.columns.count - 1 : n - 1)
        case .cycleWidth: changed = strip.cycleWidth(presets: config.sortedPresets, forward: true, viewportWidth: geo.viewportWidth, gap: config.gap)
        case .cycleWidthBack: changed = strip.cycleWidth(presets: config.sortedPresets, forward: false, viewportWidth: geo.viewportWidth, gap: config.gap)
        case .fullWidth: changed = strip.toggleFullWidth()
        case .wider: changed = strip.resizeWidth(by: config.widthStep, viewportWidth: geo.viewportWidth, gap: config.gap)
        case .narrower: changed = strip.resizeWidth(by: -config.widthStep, viewportWidth: geo.viewportWidth, gap: config.gap)
        case .taller: changed = strip.resizeHeight(by: 0.1)
        case .shorter: changed = strip.resizeHeight(by: -0.1)
        case .equalizeHeights: changed = strip.equalizeHeights()
        case .stackIntoLeft: changed = strip.stackInto(.left)
        case .stackIntoRight: changed = strip.stackInto(.right)
        case .popOut: changed = strip.popOut(.right)
        case .popOutLeft: changed = strip.popOut(.left)
        case .toggleTabbed: changed = strip.toggleTabbed()
        case .pinLeft: changed = strip.togglePin(.left)
        case .pinRight: changed = strip.togglePin(.right)
        case .center:
            if strip.columns.indices.contains(strip.focused), strip.focusedPin == nil {
                strip.viewOffset = geo.offset(toShow: strip.focused, from: strip.viewOffset, previous: nil, mode: .always)
                changed = true
                scroll = false
            }
        case .scroll(let dx):
            let next = strip.viewOffset + dx
            if config.centerMode == .always, let first = geo.widths.first, let last = geo.widths.last {
                // Centred strips can scroll until the first or last column sits in the middle.
                let v = geo.viewportWidth
                strip.viewOffset = min(max(next, first / 2 - v / 2), geo.totalWidth - last / 2 - v / 2)
            } else {
                strip.viewOffset = geo.clampOffset(next)
            }
            changed = true
            scroll = false
        case .showIndicator:
            overlays.showIndicator(for: k, sticky: false)
            return
        case .toggleFloat:
            toggleFloat()
            return
        case .sendToNextDisplay:
            sendToNextDisplay()
            return
        default:
            showIndicator = false
        }

        guard changed else {
            if showIndicator { overlays.showIndicator(for: k, sticky: false) }
            return
        }
        strips[k] = strip
        if scroll { ensureFocusedVisible(k, previous: previous) }
        layout(k, animated: true)
        if let now = strips[k]?.focusedWindow, now != before || cmd.movesWindow {
            focusWindow(now, raise: true)
        }
        if showIndicator { overlays.showIndicator(for: k, sticky: false) }
        scheduleSave()
    }

    private func toggleFloat() {
        guard let w = tracker.focusedWindow() else { return }
        let group = w.group
        if let k = key(containing: group) {
            strips[k]?.remove(group)
            userFloated.insert(w.id)
            userTiled.remove(w.id)
            floating.insert(w.id)
            animator.forget(w.id)
            // Float it in the middle of its display at a comfortable size.
            if let d = display(for: k) {
                let area = d.usableArea(respectDock: config.respectDock)
                let size = CGSize(width: min(area.width * 0.6, w.frame?.width ?? 800), height: min(area.height * 0.7, w.frame?.height ?? 600))
                let origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
                w.app.mover.set(w.element, app: w.app.element, id: w.id, origin: origin, size: size)
            }
            AX.raise(w.element)
            ensureFocusedVisible(k, previous: nil)
            layout(k, animated: true)
            Log.engine("float \(w.app.name) \(w.id)")
        } else {
            userFloated.remove(w.id)
            userTiled.insert(w.id)
            floating.remove(w.id)
            place(w, initial: false)
            Log.engine("tile \(w.app.name) \(w.id)")
        }
        scheduleSave()
    }

    private func sendToNextDisplay() {
        guard displays.count > 1, let k = commandKey(), let id = strips[k]?.focusedWindow,
              let idx = displays.firstIndex(where: { $0.uuid == k.display }) else { return }
        var next = (idx + 1) % displays.count
        // Skip displays Reel doesn't manage.
        for _ in 0..<displays.count where !isManaged(display: displays[next].uuid) { next = (next + 1) % displays.count }
        guard let tk = activeKeys[displays[next].uuid], tk != k else { return }
        moveWindow(id, from: k, to: tk)
    }

    private func moveWindow(_ id: WindowID, from k: StripKey, to tk: StripKey) {
        let width: ColumnWidth
        if case .strip(let c, _)? = strips[k]?.locate(id) { width = strips[k]!.columns[c].width } else { width = .proportion(config.defaultWidth) }
        strips[k]?.remove(id)
        var t = strips[tk] ?? Strip()
        let prev = t.focused
        t.insert(id, width: width, at: .rightOfFocused, focus: true)
        strips[tk] = t
        focusedKey = tk
        ensureFocusedVisible(k, previous: nil)
        ensureFocusedVisible(tk, previous: prev)
        // Jump it straight to the other display, then let it settle into place.
        animator.forget(visibleMember(of: id))
        layout(k, animated: true)
        layout(tk, animated: true)
        focusWindow(id, raise: true)
        overlays.showIndicator(for: tk, sticky: false)
        scheduleSave()
    }

    // MARK: - Indicator and tab bar clicks

    func focusFromIndicator(key: StripKey, window: WindowID) {
        guard var strip = strips[key] else { return }
        let prev = strip.focused
        strip.focusWindow(window)
        strips[key] = strip
        focusedKey = key
        ensureFocusedVisible(key, previous: prev)
        layout(key, animated: true)
        focusWindow(window, raise: true)
    }

    func reorderFromIndicator(key: StripKey, from: Int, to: Int) {
        guard var strip = strips[key], strip.reorderColumn(from: from, to: to) else { return }
        strips[key] = strip
        ensureFocusedVisible(key, previous: nil)
        layout(key, animated: true)
        scheduleSave()
    }

    func selectTab(key: StripKey, window: WindowID) {
        guard var strip = strips[key], strip.focusWindow(window) else { return }
        strips[key] = strip
        focusedKey = key
        layout(key, animated: true)
        focusWindow(window, raise: true)
    }

    // MARK: - Trackpad

    func gestureBegan() {
        guard running, let k = gestureKey(), var strip = strips[k] else { return }
        // The strip may still be settling from the last swipe or key press. Pick it up where it
        // is on screen, not where it was heading, or the first frame jumps to the old target.
        let ids = strip.columns.flatMap(\.windows).map { visibleMember(of: $0) }
        if let id = ids.first(where: { animator.currentFrame(of: $0) != nil }),
           let current = animator.currentFrame(of: id), let target = animator.targetFrame(of: id) {
            strip.viewOffset += Double(target.minX - current.minX)
            strips[k] = strip
        }
        gesture = GestureState(key: k, startOffset: strip.viewOffset, lastTime: CACurrentMediaTime())
        overlays.showIndicator(for: k, sticky: true)
    }

    /// `dx` is the finger movement as a fraction of the trackpad's width.
    func gestureChanged(dx: Double) {
        guard running, var g = gesture, var strip = strips[g.key], let d = display(for: g.key) else { return }
        let geo = StripGeometry(strip: strip, context: context(for: g.key, display: d))
        let sign: Double = config.naturalSwipe ? -1 : 1
        let points = dx * geo.viewportWidth * 1.6 * config.swipeSensitivity * sign
        // Past the ends the strip resists, like a scroll view.
        var next = strip.viewOffset + points
        let maxO = max(0, geo.totalWidth - geo.viewportWidth)
        if next < 0 || next > maxO {
            next = strip.viewOffset + points * 0.35
        }
        let now = CACurrentMediaTime()
        let dt = max(now - g.lastTime, 1.0 / 240)
        g.velocity = g.velocity * 0.6 + (next - strip.viewOffset) / dt * 0.4
        g.lastTime = now
        strip.viewOffset = next
        strips[g.key] = strip
        gesture = g
        layout(g.key, animated: false)
    }

    func gestureEnded(cancelled: Bool) {
        guard running, let g = gesture else { return }
        gesture = nil
        overlays.showIndicator(for: g.key, sticky: false)
        guard var strip = strips[g.key], let d = display(for: g.key), !strip.columns.isEmpty else { return }
        let geo = StripGeometry(strip: strip, context: context(for: g.key, display: d))
        // Fingers that stopped before lifting don't throw the strip.
        let velocity = CACurrentMediaTime() - g.lastTime > 0.06 ? 0 : g.velocity
        let projected = cancelled ? g.startOffset : Spring.projectedRest(value: strip.viewOffset, velocity: velocity, decelerationRate: 0.994)
        guard let snap = geo.snapColumn(forOffset: projected, mode: config.centerMode) else { return }
        let target: Double
        if config.centerMode == .always {
            target = geo.starts[snap] + geo.widths[snap] / 2 - geo.viewportWidth / 2
        } else {
            target = geo.clampOffset(geo.starts[snap])
        }
        // Keep focus if the focused column is still fully in view; otherwise the snapped one takes it.
        let keep = strip.columns.indices.contains(strip.focused) &&
            geo.starts[strip.focused] >= target - 1 && geo.starts[strip.focused] + geo.widths[strip.focused] <= target + geo.viewportWidth + 1
        strip.viewOffset = target
        if !keep { strip.focused = snap; strip.focusedPin = nil }
        strips[g.key] = strip
        animator.carryVelocity(-velocity, windows: strip.columns.flatMap(\.windows).map { visibleMember(of: $0) })
        layout(g.key, animated: true)
        if !keep, let id = strip.focusedWindow { focusWindow(id, raise: true, warp: false) }
        scheduleSave()
    }

    private func gestureKey() -> StripKey? {
        let loc = NSEvent.mouseLocation
        let p = CGPoint(x: loc.x, y: Displays.primaryHeight - loc.y)
        if let d = Displays.display(containing: p, in: displays), isManaged(display: d.uuid) { return activeKeys[d.uuid] }
        return commandKey()
    }

    // MARK: - State for the UI, CLI and session

    struct ColumnInfo {
        var windows: [WindowID]
        var active: Int
        var tabbed: Bool
    }

    func activeStrip(for display: String) -> Strip? {
        guard let k = activeKeys[display] else { return nil }
        return strips[k]
    }

    func window(_ id: WindowID) -> TrackedWindow? {
        tracker.windows[visibleMember(of: id)] ?? tracker.windows[id]
    }

    func statusJSON() -> [String: Any] {
        var out: [String: Any] = ["running": running, "accessibility": AX.isTrusted]
        var list: [[String: Any]] = []
        for d in displays {
            guard let k = activeKeys[d.uuid] else { continue }
            let s = strips[k] ?? Strip()
            let cols: [[String: Any]] = s.columns.enumerated().map { (i, c) in
                [
                    "index": i + 1,
                    "focused": i == s.focused && s.focusedPin == nil,
                    "tabbed": c.tabbed,
                    "windows": c.windows.map { describe($0) },
                ]
            }
            list.append([
                "display": d.name, "uuid": d.uuid, "space": k.space, "managed": isManaged(display: d.uuid),
                "columns": cols,
                "pinnedLeft": (s.pinned[.left]?.windows ?? []).map { describe($0) },
                "pinnedRight": (s.pinned[.right]?.windows ?? []).map { describe($0) },
                "viewOffset": s.viewOffset,
                "frame": [Int(d.frame.minX), Int(d.frame.minY), Int(d.frame.width), Int(d.frame.height)],
                "area": { let a = d.usableArea(respectDock: config.respectDock); return [Int(a.minX), Int(a.minY), Int(a.width), Int(a.height)] }(),
                "focusedStrip": k == focusedKey,
            ])
        }
        out["displays"] = list
        out["floating"] = floating.sorted().map { describe($0) }
        return out
    }

    private func describe(_ id: WindowID) -> [String: Any] {
        let w = window(id)
        var d: [String: Any] = ["id": id, "app": w?.app.name ?? "", "title": w?.title ?? ""]
        func rect(_ r: CGRect) -> [Int] { [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)] }
        if let f = w?.frame { d["frame"] = rect(f) }
        if let w, let t = animator.targetFrame(of: w.id) {
            d["target"] = rect(t)
            d["onScreen"] = animator.isVisible(w.id)
        }
        if let m = w?.minWidth { d["minWidth"] = Int(m) }
        if let m = w?.maxWidth { d["maxWidth"] = Int(m) }
        return d
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSessionNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveSessionNow() {
        guard running || !strips.isEmpty else { return }
        var saved: [SavedStrip] = []
        for (k, s) in strips where !s.isEmpty {
            var sigs: [WindowID: WindowSignature] = [:]
            for id in s.allWindows {
                let w = window(id)
                sigs[id] = WindowSignature(id: id, bundleID: w?.app.bundleID, title: w?.title ?? "")
            }
            saved.append(SavedStrip(key: k, strip: s, signatures: sigs))
        }
        let floats = userFloated.compactMap { id -> WindowSignature? in
            guard let w = tracker.windows[id] else { return nil }
            return WindowSignature(id: id, bundleID: w.app.bundleID, title: w.title)
        }
        var minWidths: [WindowID: Double] = [:]
        var maxWidths: [WindowID: Double] = [:]
        for w in tracker.windows.values {
            if let m = w.minWidth { minWidths[w.id] = Double(m) }
            if let m = w.maxWidth { maxWidths[w.id] = Double(m) }
        }
        SessionStore.save(SavedSession(strips: saved, floating: floats, savedAt: Date(), minWidths: minWidths, maxWidths: maxWidths))
    }
}

private extension Command {
    var movesWindow: Bool {
        switch self {
        case .move, .moveFirst, .moveLast, .moveToIndex, .stackIntoLeft, .stackIntoRight, .popOut, .popOutLeft, .pinLeft, .pinRight:
            return true
        default:
            return false
        }
    }
}

extension Strip {
    /// Swaps one window id for another in place (used when a tab group's id window closes).
    mutating func replace(_ old: WindowID, with new: WindowID) {
        for c in columns.indices {
            if let r = columns[c].windows.firstIndex(of: old) { columns[c].windows[r] = new }
        }
        for side in PinSide.allCases {
            if let r = pinned[side]?.windows.firstIndex(of: old) { pinned[side]!.windows[r] = new }
        }
    }
}

extension CGRect {
    /// Rounds the origin and the size separately. `integral` grows the size whenever the origin
    /// has a fraction, so a window scrolled by a fractional offset would flip between two widths
    /// from frame to frame, and every flip is a resize.
    var pixelAligned: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}
