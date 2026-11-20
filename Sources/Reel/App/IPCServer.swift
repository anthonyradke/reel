import Foundation
import ReelCore

/// A Unix socket for `reelctl`. One line in, one line (usually JSON) out.
final class IPCServer {
    static let shared = IPCServer()
    static var socketPath: String { ConfigStore.directory.appendingPathComponent("reel.sock").path }

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "reel.ipc")

    func start() {
        guard fd < 0 else { return }
        let path = Self.socketPath
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        // bind() creates the socket file with the umask's mode, so narrow it first: with a
        // chmod afterwards, another user could connect in the moment between the two.
        let oldMask = umask(0o177)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard ok == 0, listen(fd, 8) == 0 else {
            Log.engine("ipc: could not listen on \(path)")
            close(fd); fd = -1
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    private func accept() {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        // A client that quits before the reply must not kill Reel with SIGPIPE, and one that
        // never sends its line must not hold up every later request on this queue.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        // Read one line (or until the client closes its side).
        while true {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.contains(10) || data.count > 65_536 { break }
        }
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let box = ReplyBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            box.set(Self.handle(line))
            sem.signal()
        }
        let reply = sem.wait(timeout: .now() + 5) == .success ? box.get() : #"{"error":"timed out"}"#
        let out = Array((reply + "\n").utf8)
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { write(client, $0.baseAddress! + sent, out.count - sent) }
            if n <= 0 { break }
            sent += n
        }
    }

    /// The reply, written on the main thread and read here; after a timeout the main thread may
    /// still finish later, so the two sides share it under a lock.
    private final class ReplyBox {
        private let lock = NSLock()
        private var value = ""
        func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Runs one request on the main thread.
    static func handle(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first?.lowercased() else { return #"{"error":"empty request"}"# }
        let wm = WindowManager.shared
        switch verb {
        case "status", "windows", "list":
            return json(wm.statusJSON())
        case "ping":
            return #"{"ok":true}"#
        case "config":
            if parts.count > 1, parts[1] == "path" { return json(["path": ConfigStore.url.path]) }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? enc.encode(ConfigStore.shared.config)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        case "set":
            guard parts.count > 1 else { return #"{"error":"usage: set <key> <json value>"}"# }
            return setConfig(parts[1])
        case "swipe":
            // `swipe <distance> <ms>`: plays a trackpad swipe through the same path the fingers
            // take, for testing. Distance is a fraction of the trackpad's width.
            let args = (parts.count > 1 ? parts[1] : "").split(separator: " ").compactMap { Double($0) }
            let distance = args.first ?? 0.3, ms = args.count > 1 ? args[1] : 300
            let frames = max(1, Int(ms / 1000 * 120))
            wm.gestureBegan()
            for i in 1...frames {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 120) {
                    wm.gestureChanged(dx: distance / Double(frames))
                    if i == frames { wm.gestureEnded(cancelled: false) }
                }
            }
            return #"{"ok":true}"#
        default:
            guard let cmd = Command(name: line) else {
                return json(["error": "unknown command: \(line)"])
            }
            wm.perform(cmd)
            return #"{"ok":true}"#
        }
    }

    /// `set gap 12`, `set centerMode "always"`: patches one key of the settings file.
    private static func setConfig(_ args: String) -> String {
        let kv = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { return #"{"error":"usage: set <key> <json value>"}"# }
        guard let current = try? JSONEncoder().encode(ConfigStore.shared.config),
              var obj = try? JSONSerialization.jsonObject(with: current) as? [String: Any] else { return #"{"error":"internal"}"# }
        guard obj[kv[0]] != nil else { return json(["error": "no setting called \(kv[0])"]) }
        let raw = kv[1]
        let value = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) ?? raw
        obj[kv[0]] = value
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return #"{"error":"invalid value"}"# }
        ConfigStore.shared.config = c
        return #"{"ok":true}"#
    }

    private static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
