import AppKit
import Carbon.HIToolbox
import ReelCore

/// System-wide shortcuts through Carbon hot keys. They need no extra permission, fire before
/// the focused app sees the key, and don't care which app is in front.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: Command] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    /// While the recorder is open, shortcuts are paused so the keys can be captured.
    var paused = false

    private init() {}

    func enable(bindings: [String: [KeyCombo]]) {
        unregisterAll()
        installHandler()
        for (name, combos) in bindings {
            guard let cmd = Command(name: name) else { continue }
            for combo in combos { register(combo, cmd) }
        }
    }

    /// Stopped: only the keys that start the window manager again stay live.
    func disable(keepStartBinding: Bool) {
        let bindings = ConfigStore.shared.config.bindings
        unregisterAll()
        guard keepStartBinding else { return }
        installHandler()
        for name in [Command.stop.name, Command.toggleRunning.name] {
            for combo in bindings[name] ?? [] { register(combo, .start) }
        }
    }

    private func register(_ combo: KeyCombo, _ cmd: Command) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5245454C), id: nextID) // "REEL"
        let status = RegisterEventHotKey(combo.keyCode, Self.carbonModifiers(combo.modifiers), id, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.engine("shortcut \(combo.modifiers.symbols)\(KeyNames.name(for: combo.keyCode)) for \(cmd.name) is taken (\(status))")
            return
        }
        refs.append(ref)
        actions[nextID] = cmd
        nextID += 1
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotkeyManager.shared.fire(hk.id)
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ id: UInt32) {
        guard !paused, let cmd = actions[id] else { return }
        WindowManager.shared.perform(cmd)
    }

    static func carbonModifiers(_ m: KeyCombo.Modifiers) -> UInt32 {
        var c: UInt32 = 0
        if m.contains(.command) { c |= UInt32(cmdKey) }
        if m.contains(.shift) { c |= UInt32(shiftKey) }
        if m.contains(.option) { c |= UInt32(optionKey) }
        if m.contains(.control) { c |= UInt32(controlKey) }
        return c
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyCombo.Modifiers {
        var m: KeyCombo.Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }
}

/// Key labels in the user's current keyboard layout, so an AZERTY or Dvorak user sees the
/// letter printed on their key.
enum KeyNames {
    private static let special: [UInt32: String] = [
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋", UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    static func name(for keyCode: UInt32) -> String {
        if let s = special[keyCode] { return s }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
        }
        guard status == noErr, len > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }

    static func describe(_ c: KeyCombo) -> String {
        c.modifiers.symbols + name(for: c.keyCode)
    }
}
