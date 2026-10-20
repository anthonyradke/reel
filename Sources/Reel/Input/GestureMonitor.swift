import AppKit
import ReelCore

/// Follows three- or four-finger horizontal swipes on the trackpad, one to one.
///
/// It listens to the raw touch frames macOS sends as gesture events, so the strip moves with
/// the fingers instead of waiting for a finished swipe. The tap only listens; macOS still
/// receives every swipe, which is why the setup guide asks to free the swipe there.
final class GestureMonitor {
    static let shared = GestureMonitor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private enum Phase { case idle, deciding, tracking, rejected }
    private var phase: Phase = .idle
    private var startX: Double = 0
    private var startY: Double = 0
    private var lastX: Double = 0

    private init() {}

    func start() {
        guard tap == nil, ConfigStore.shared.config.swipeFingers > 0 else { return }
        // NSEventType.gesture is 29; it carries the touches.
        let mask: CGEventMask = 1 << 29
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: { _, type, event, ctx in
            let me = Unmanaged<GestureMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            me.handle(event)
            return Unmanaged.passUnretained(event)
        }, userInfo: ref) else {
            Log.engine("trackpad swipe unavailable: could not create the event tap")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        if phase == .tracking { WindowManager.shared.gestureEnded(cancelled: false) }
        phase = .idle
    }

    func restart() {
        stop()
        start()
    }

    private func handle(_ cg: CGEvent) {
        guard let event = NSEvent(cgEvent: cg), event.type == .gesture else { return }
        let fingers = ConfigStore.shared.config.swipeFingers
        let touches = event.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled && !$0.isResting }
        let count = touches.count

        guard count == fingers else {
            // Lifting fingers (or adding one) ends the swipe.
            if phase == .tracking { WindowManager.shared.gestureEnded(cancelled: false) }
            if count == 0 || count < fingers { phase = .idle } else { phase = .rejected }
            return
        }

        let x = touches.map { Double($0.normalizedPosition.x) }.reduce(0, +) / Double(count)
        let y = touches.map { Double($0.normalizedPosition.y) }.reduce(0, +) / Double(count)

        switch phase {
        case .idle:
            phase = .deciding
            startX = x; startY = y; lastX = x
        case .deciding:
            let dx = x - startX, dy = y - startY
            // Up and down belong to Mission Control and App Exposé.
            if abs(dy) > 0.04 && abs(dy) > abs(dx) {
                phase = .rejected
            } else if abs(dx) > 0.015 {
                phase = .tracking
                lastX = x
                WindowManager.shared.gestureBegan()
            }
        case .tracking:
            let dx = x - lastX
            lastX = x
            if dx != 0 { WindowManager.shared.gestureChanged(dx: dx) }
        case .rejected:
            break
        }
    }
}
