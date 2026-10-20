import AppKit

/// Checks GitHub Releases for a newer build once a day and from the menu.
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let repo = "anthonyradke/reel"

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    func checkInBackground() {
        if let last = lastCheck, Date().timeIntervalSince(last) < 86_400 { return }
        fetch { [weak self] release in
            self?.lastCheck = Date()
            guard let release, Self.isNewer(release.tag_name, than: AppDelegate.version) else { return }
            Log.engine("update available: \(release.tag_name)")
            DispatchQueue.main.async { self?.offer(release) }
        }
    }

    func checkInteractively() {
        fetch { [weak self] release in
            DispatchQueue.main.async {
                self?.lastCheck = Date()
                guard let release else {
                    self?.alert("Couldn't check for updates", "GitHub didn't answer. Try again in a bit.")
                    return
                }
                if Self.isNewer(release.tag_name, than: AppDelegate.version) {
                    self?.offer(release)
                } else {
                    self?.alert("You're up to date", "Reel \(AppDelegate.version) is the newest version.")
                }
            }
        }
    }

    private func fetch(_ done: @escaping (Release?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return done(nil) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            done(data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) })
        }.resume()
    }

    private func offer(_ r: Release) {
        let a = NSAlert()
        a.messageText = "Reel \(r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))) is available"
        a.informativeText = (r.body?.prefix(600)).map(String.init) ?? "A new version is ready to download."
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            let dmg = r.assets.first { $0.name.hasSuffix(".dmg") || $0.name.hasSuffix(".zip") }
            NSWorkspace.shared.open(URL(string: dmg?.browser_download_url ?? r.html_url)!)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
