import Combine
import Foundation
import ReelCore

/// Owns the settings file. Every change is written straight away and applied straight away;
/// edits made to the file by hand (or by `reelctl config`) are picked up too.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var url: URL { directory.appendingPathComponent("config.json") }

    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            if !loadingFromDisk { scheduleSave() }
            onChange?(config, oldValue)
        }
    }

    var onChange: ((Config, Config) -> Void)?
    private var loadingFromDisk = false
    private var watcher: DispatchSourceFileSystemObject?
    private var lastWritten: Data?

    private init() {
        if let data = try? Data(contentsOf: Self.url), let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
        } else {
            config = Config()
        }
        if !FileManager.default.fileExists(atPath: Self.url.path) { save() }
        watch()
    }

    private var saveWork: DispatchWorkItem?

    /// Sliders change the config many times a second; write the file once they settle.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Writes any change still waiting, e.g. when the app quits.
    func flush() {
        guard let work = saveWork, !work.isCancelled else { return }
        work.cancel()
        save()
    }

    private func save() {
        saveWork = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config) else { return }
        lastWritten = data
        try? data.write(to: Self.url, options: .atomic)
        // An atomic write replaces the file, so the watcher has to follow the new one.
        watch()
    }

    private func watch() {
        watcher?.cancel()
        let fd = open(Self.url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.reloadFromDisk() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func reloadFromDisk() {
        defer { watch() }
        guard let data = try? Data(contentsOf: Self.url), data != lastWritten,
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return }
        lastWritten = data
        loadingFromDisk = true
        config = c
        loadingFromDisk = false
        Log.engine("settings reloaded from file")
    }

    func resetShortcuts() {
        config.bindings = Config.defaultBindings
    }
}
