import Foundation

// reelctl: talks to a running Reel over its socket.
//   reelctl focus-left
//   reelctl status
//   reelctl set gap 12

let usage = """
usage: reelctl <command>

  status              windows on each strip, as JSON
  config [path]       current settings, or where the file lives
  set <key> <json>    change one setting, e.g. set gap 12
  ping                check Reel is running
  <action>            any action name: focus-left, move-right, focus-3,
                      cycle-width, full-width, center, stack-left, pop-out,
                      toggle-tabbed, toggle-float, pin-left, scroll:200,
                      next-display, retile, start, stop, toggle, settings

"""

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || ["-h", "--help", "help"].contains(args[0]) {
    print(usage, terminator: "")
    exit(args.isEmpty ? 1 : 0)
}

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Reel/reel.sock").path

func send(_ line: String) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        socketPath.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { return nil }
    let out = Array((line + "\n").utf8)
    _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    return String(decoding: data, as: UTF8.self)
}

let line = args.joined(separator: " ")
if let reply = send(line) {
    print(reply.trimmingCharacters(in: .whitespacesAndNewlines))
    exit(reply.contains("\"error\"") ? 2 : 0)
}

// Not running (or no socket yet): plain actions can still go through the URL scheme,
// which launches Reel if needed.
if !["status", "windows", "list", "config", "set", "ping"].contains(args[0].lowercased()) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "reel://\(args[0])"]
    try? p.run()
    p.waitUntilExit()
    exit(p.terminationStatus)
}
FileHandle.standardError.write("reelctl: Reel isn't running\n".data(using: .utf8)!)
exit(1)
