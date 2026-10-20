import AppKit
import ReelCore

/// The few private window-server calls a Spaces-aware window manager needs. Each one is looked
/// up at runtime, so if a future macOS drops a symbol the app degrades instead of crashing.
enum SkyLight {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SpaceGetTypeFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let hiServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)

    private static func sym<T>(_ name: String, _ lib: UnsafeMutableRawPointer? = handle) -> T? {
        guard let lib, let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let mainConnection: MainConnectionFn? = sym("SLSMainConnectionID")
    private static let copyDisplaySpaces: CopyDisplaySpacesFn? = sym("SLSCopyManagedDisplaySpaces")
    private static let copySpacesForWindows: CopySpacesForWindowsFn? = sym("SLSCopySpacesForWindows")
    private static let spaceGetType: SpaceGetTypeFn? = sym("SLSSpaceGetType")
    private static let setFrontProcess: SetFrontProcessFn? = sym("_SLPSSetFrontProcessWithOptions")
    private static let postEventRecord: PostEventRecordFn? = sym("SLPSPostEventRecordTo")
    private static let getProcessForPID: GetProcessForPIDFn? = sym("GetProcessForPID", hiServices)

    static var connection: Int32 { mainConnection?() ?? 0 }

    /// The current Space of every display, keyed by display UUID. When "Displays have separate
    /// Spaces" is off, macOS reports a single entry and every display shares it.
    static func currentSpaces() -> (perDisplay: [String: UInt64], shared: UInt64?) {
        guard let fn = copyDisplaySpaces, let arr = fn(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return ([:], nil)
        }
        var out: [String: UInt64] = [:]
        var shared: UInt64?
        for entry in arr {
            guard let id = entry["Display Identifier"] as? String,
                  let current = entry["Current Space"] as? [String: Any] else { continue }
            let space = (current["id64"] as? UInt64) ?? (current["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
            if id == "Main" { shared = space } else { out[id] = space }
        }
        if arr.count == 1 && shared == nil { shared = out.values.first }
        return (out, shared)
    }

    /// The Spaces a window is on. Empty if unknown.
    static func spaces(for window: WindowID) -> [UInt64] {
        guard let fn = copySpacesForWindows else { return [] }
        let ids = [NSNumber(value: window)] as CFArray
        guard let arr = fn(connection, 0x7, ids)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return arr.map(\.uint64Value)
    }

    /// True for a native-fullscreen Space (type 4).
    static func isFullscreenSpace(_ space: UInt64) -> Bool {
        spaceGetType?(connection, space) == 4
    }

    /// Brings an app forward and makes one of its windows key, without the activation delay
    /// NSRunningApplication.activate has on recent macOS.
    @discardableResult
    static func focus(pid: pid_t, window: WindowID) -> Bool {
        guard let getPSN = getProcessForPID, let setFront = setFrontProcess else { return false }
        var psn = [UInt8](repeating: 0, count: 8)
        let ok: Bool = psn.withUnsafeMutableBytes { buf in
            guard getPSN(pid, buf.baseAddress!) == noErr else { return false }
            return setFront(buf.baseAddress!, window, 0x200) == 0
        }
        guard ok else { return false }
        makeKey(psn: &psn, window: window)
        return true
    }

    private static func makeKey(psn: inout [UInt8], window: WindowID) {
        guard let post = postEventRecord else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var wid = window
        withUnsafeBytes(of: &wid) { raw in
            for i in 0..<4 { bytes[0x3c + i] = raw[i] }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        psn.withUnsafeMutableBytes { p in
            bytes[0x08] = 0x01
            _ = post(p.baseAddress!, &bytes)
            bytes[0x08] = 0x02
            _ = post(p.baseAddress!, &bytes)
        }
    }
}
