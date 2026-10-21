import AppKit

/// Reads the macOS settings that decide whether the swipe and the strip work, and spots other
/// window managers that would fight over the same windows.
struct MacSetupCheck: Identifiable {
    enum Status { case ok, warning, problem }
    let id: String
    let title: String
    let detail: String
    let status: Status
    var settingsURL: String?
}

enum MacSetup {
    static func run(swipeFingers: Int, smoothSwipe: Bool) -> [MacSetupCheck] {
        var out: [MacSetupCheck] = []

        out.append(MacSetupCheck(
            id: "ax", title: "Accessibility permission",
            detail: AX.isTrusted ? "Granted. Reel can move and resize windows." :
                "Needed to move windows. Turn Reel on in Privacy & Security › Accessibility.",
            status: AX.isTrusted ? .ok : .problem,
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))

        if swipeFingers > 0 && smoothSwipe && SwipeProxy.isSupported {
            let granted = SwipeProxy.hasPermission
            out.append(MacSetupCheck(
                id: "screen", title: "Screen Recording permission",
                detail: granted ? "Granted. Swipes move pictures of the windows, so they stay in step." :
                    "Optional, for smooth swipes. Turn Reel on in Privacy & Security › Screen & System Audio Recording, then quit and reopen Reel.",
                status: granted ? .ok : .warning,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
        }

        let tp = UserDefaults(suiteName: "com.apple.AppleMultitouchTrackpad")
        let tpBT = UserDefaults(suiteName: "com.apple.driver.AppleBluetoothMultitouch.trackpad")
        func trackpadInt(_ key: String) -> Int? {
            (tp?.object(forKey: key) as? Int) ?? (tpBT?.object(forKey: key) as? Int)
        }
        // 0 off, 1 three fingers, 2 four fingers (the four-finger key holds 2 when on).
        let threeHoriz = trackpadInt("TrackpadThreeFingerHorizSwipeGesture") ?? 0
        let fourHoriz = trackpadInt("TrackpadFourFingerHorizSwipeGesture") ?? 2
        let threeDrag = (trackpadInt("TrackpadThreeFingerDrag") ?? 0) == 1
        if swipeFingers == 0 {
            out.append(MacSetupCheck(id: "swipe", title: "Trackpad swipe", detail: "Swiping the strip is off in Reel.", status: .ok))
        } else if swipeFingers == 4 {
            // Settings has one picker for full-screen swipes, so a three-finger choice (2 in the
            // three-finger key) means four fingers are free even if the old four-finger value lingers.
            let clash = fourHoriz != 0 && threeHoriz != 2
            out.append(MacSetupCheck(
                id: "swipe", title: "Four-finger swipe is free",
                detail: clash ? "macOS also switches desktops with a four-finger swipe. Turn off Trackpad › More Gestures › Swipe between full-screen applications." :
                    "macOS leaves four-finger left/right swipes to Reel.",
                status: clash ? .problem : .ok, settingsURL: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"))
        } else {
            let clash = threeHoriz != 0
            out.append(MacSetupCheck(
                id: "swipe", title: "Three-finger swipe is free",
                detail: clash ? "macOS uses three-finger swipes for pages or desktops. Set Swipe between pages to two fingers and Swipe between full-screen applications to four." :
                    "macOS leaves three-finger left/right swipes to Reel.",
                status: clash ? .problem : .ok, settingsURL: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"))
            if threeDrag {
                out.append(MacSetupCheck(id: "drag", title: "Three Finger Drag is on",
                                         detail: "It takes three-finger movement for dragging. Use four fingers for the strip, or turn it off in Accessibility › Pointer Control.",
                                         status: .problem))
            }
        }

        let dock = UserDefaults(suiteName: "com.apple.dock")
        let mru = dock?.object(forKey: "mru-spaces") as? Bool ?? true
        out.append(MacSetupCheck(
            id: "mru", title: "Spaces stay in order",
            detail: mru ? "Turn off Desktop & Dock › Automatically rearrange Spaces based on most recent use." : "Spaces won't be reshuffled behind your back.",
            status: mru ? .warning : .ok, settingsURL: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"))

        let spans = UserDefaults(suiteName: "com.apple.spaces")?.object(forKey: "spans-displays") as? Bool ?? false
        out.append(MacSetupCheck(
            id: "spaces", title: "Displays have separate Spaces",
            detail: spans ? "Turn on Desktop & Dock › Displays have separate Spaces (then log out) so each display gets its own strip." :
                "Each display gets a strip of its own.",
            status: spans && NSScreen.screens.count > 1 ? .problem : (spans ? .warning : .ok),
            settingsURL: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"))

        let wmDefaults = UserDefaults(suiteName: "com.apple.WindowManager")
        let stage = wmDefaults?.object(forKey: "GloballyEnabled") as? Bool ?? false
        out.append(MacSetupCheck(
            id: "stage", title: "Stage Manager is off",
            detail: stage ? "Stage Manager moves and resizes windows too. Turn it off in Control Centre or Desktop & Dock." : "Nothing else is arranging windows.",
            status: stage ? .problem : .ok, settingsURL: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"))

        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 {
            let edge = wmDefaults?.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true
            let top = wmDefaults?.object(forKey: "EnableTopTilingByEdgeDrag") as? Bool ?? true
            let opt = wmDefaults?.object(forKey: "EnableTilingOptionAccelerator") as? Bool ?? true
            let on = edge || top || opt
            out.append(MacSetupCheck(
                id: "tiling", title: "macOS window tiling is off",
                detail: on ? "In Desktop & Dock › Windows, turn off dragging windows to the screen edges or menu bar, and holding ⌥ while dragging." :
                    "macOS won't snap windows while you drag them.",
                status: on ? .warning : .ok, settingsURL: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"))
        }

        let rivals = otherWindowManagers()
        out.append(MacSetupCheck(
            id: "rivals", title: "No other window manager running",
            detail: rivals.isEmpty ? "Nothing else is moving windows." : "Quit \(rivals.joined(separator: ", ")). They move windows too and will fight Reel.",
            status: rivals.isEmpty ? .ok : .problem))

        let inApplications = Bundle.main.bundlePath.hasPrefix("/Applications/") || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        out.append(MacSetupCheck(
            id: "location", title: "Running from Applications",
            detail: inApplications ? "macOS ties the Accessibility permission to this copy." :
                "Move Reel to Applications. macOS ties the Accessibility permission to where the app is.",
            status: inApplications ? .ok : .warning))
        return out
    }

    static let knownWindowManagers: [String: String] = [
        "com.knollsoft.Rectangle": "Rectangle", "com.knollsoft.Hookshot": "Hookshot",
        "com.crowdcafe.windowmagnet": "Magnet", "com.hegenberg.BetterSnapTool": "BetterSnapTool",
        "com.mrkai77.Loop": "Loop", "com.koekeishiya.yabai": "yabai", "bobko.aerospace": "AeroSpace",
        "com.amethyst.Amethyst": "Amethyst", "com.lwouis.alt-tab-macos": "",
        "com.sergey-gorbunov.OneMenu": "OneMenu", "com.manytricks.Moom": "Moom",
        "com.divvyapp.Divvy": "Divvy", "com.mizage.Divvy": "Divvy", "com.jimbos.Swish": "Swish",
        "com.glazewm": "GlazeWM", "com.omniwm.app": "OmniWM", "org.hammerspoon.Hammerspoon": "Hammerspoon",
    ]

    static func otherWindowManagers() -> [String] {
        let running = NSWorkspace.shared.runningApplications
        var names = Set<String>()
        for app in running {
            guard let bid = app.bundleIdentifier, let name = knownWindowManagers[bid], !name.isEmpty else { continue }
            names.insert(name)
        }
        // yabai runs as a plain process, not an app.
        for app in running where app.executableURL?.lastPathComponent == "yabai" { names.insert("yabai") }
        return names.sorted()
    }
}
