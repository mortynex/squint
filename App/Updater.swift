import AppKit
import CryptoKit

/// Updates from GitHub Releases. The latest release carries `Squint-<version>.zip` and its Ed25519 signature
/// `Squint-<version>.zip.sig` (made by release.sh), checked against `SquintUpdatePublicKey` in Info.plist. The verified
/// app is unzipped next to this one and swapped in after Squint quits, by a shell script that also re-registers the
/// Quick Look extension and relaunches. Downloads made here aren't quarantined, so Gatekeeper doesn't ask again.
final class Updater: NSObject {
    static let shared = Updater()

    /// SQUINT_UPDATE_FEED points tests at another release JSON (file: URLs work).
    private static let feed = URL(string: ProcessInfo.processInfo.environment["SQUINT_UPDATE_FEED"]
                                  ?? "https://api.github.com/repos/mortynex/squint/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey: "AutomaticallyCheckForUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "AutomaticallyCheckForUpdates") }
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    }

    private var checking = false
    /// The verified new app, waiting for Squint to quit.
    private var staged: (app: URL, version: String)?
    /// Relaunch after installing; off when the quit that "Install and Relaunch" started was cancelled.
    var relaunch = false
    private var progressPanel: NSPanel?
    private var progressObservation: NSKeyValueObservation?
    private var task: URLSessionTask?

    // MARK: - Checking

    /// At launch: at most once a day, quietly unless there's an update.
    func checkAutomatically() {
        guard automaticChecks else { return }
        if let last = UserDefaults.standard.object(forKey: "LastUpdateCheck") as? Date, Date().timeIntervalSince(last) < Self.checkInterval { return }
        check(interactive: false)
    }

    @objc func checkForUpdates(_ sender: Any?) { check(interactive: true) }

    private func check(interactive: Bool) {
        guard !checking, progressPanel == nil else { return }
        if let staged {
            if interactive { offerRestart(version: staged.version) }
            return
        }
        checking = true
        var request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async { [self] in
                checking = false
                guard let release else {
                    if interactive { fail("Couldn't check for updates.", error?.localizedDescription ?? "GitHub didn't return a release.") }
                    return
                }
                UserDefaults.standard.set(Date(), forKey: "LastUpdateCheck")
                if Self.isNewer(release.version, than: Self.currentVersion),
                   interactive || UserDefaults.standard.string(forKey: "SkippedUpdateVersion") != release.version {
                    offer(release)
                } else if interactive {
                    let alert = NSAlert()
                    alert.messageText = "Squint is up to date"
                    alert.informativeText = "Version \(Self.currentVersion) is the latest."
                    alert.runModal()
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Squint \(release.version) is available"
        var info = "You have \(Self.currentVersion)."
        if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            info += "\n\n" + (notes.count > 1200 ? String(notes.prefix(1200)) + "…" : notes)
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: "SkippedUpdateVersion")
        default: break
        }
    }

    // MARK: - Installing

    private func install(_ release: Release) {
        let dest = Bundle.main.bundleURL
        let fm = FileManager.default
        guard !dest.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: dest.deletingLastPathComponent().path), fm.isWritableFile(atPath: dest.path) else {
            let alert = NSAlert()
            alert.messageText = "Squint can't update itself here"
            alert.informativeText = "Move Squint to your Applications folder (or download the update yourself)."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.html_url) }
            return
        }
        guard let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let sig = release.assets.first(where: { $0.name == zip.name + ".sig" }) else {
            fail("The update can't be installed.", "Release \(release.tag_name) has no signed zip.")
            return
        }
        showProgress(version: release.version)
        URLSession.shared.dataTask(with: sig.browser_download_url) { [self] sigData, _, error in
            guard let sigData, let signature = Data(base64Encoded: String(decoding: sigData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                finish(error: error?.localizedDescription ?? "The signature couldn't be read.")
                return
            }
            let download = URLSession.shared.downloadTask(with: zip.browser_download_url) { [self] file, _, error in
                guard let file else { finish(error: error?.localizedDescription ?? "The download failed."); return }
                do {
                    let app = try unpack(file, signature: signature, version: release.version, next: dest)
                    DispatchQueue.main.async { [self] in
                        guard progressPanel != nil else { return }  // cancelled
                        staged = (app, release.version)
                        finish(error: nil)
                        relaunch = true
                        NSApp.terminate(nil)
                    }
                } catch {
                    finish(error: error.localizedDescription)
                }
            }
            DispatchQueue.main.async { [self] in
                task = download
                progressObservation = download.progress.observe(\.fractionCompleted) { progress, _ in
                    DispatchQueue.main.async { [self] in
                        (progressPanel?.contentView?.subviews.first { $0 is NSProgressIndicator } as? NSProgressIndicator)?.doubleValue = progress.fractionCompleted
                    }
                }
                download.resume()
            }
        }.resume()
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Verifies the zip and unpacks it on the same volume as `next` (so the swap is a rename); returns the new app.
    private func unpack(_ zip: URL, signature: Data, version: String, next dest: URL) throws -> URL {
        guard let encoded = Bundle.main.infoDictionary?["SquintUpdatePublicKey"] as? String, let raw = Data(base64Encoded: encoded),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { throw UpdateError("This build has no update key.") }
        guard key.isValidSignature(signature, for: try Data(contentsOf: zip, options: .mappedIfSafe)) else {
            throw UpdateError("The download's signature doesn't match.")
        }
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let app = dir.appendingPathComponent("Squint.app")
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("The download isn't Squint \(version).")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\((tool as NSString).lastPathComponent) failed.") }
    }

    /// Called when Squint quits: swaps in the staged app once this process is gone.
    func installStagedUpdate() {
        guard let staged else { return }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        old="$3.updating"
        rm -rf "$old"
        mv "$3" "$old" || exit 1
        if mv "$2" "$3"; then rm -rf "$old"; else mv "$old" "$3"; exit 1; fi
        rm -rf "$(dirname "$2")"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "$3"
        pluginkit -a "$3/Contents/PlugIns/SquintExtension.appex"
        pluginkit -e use -i com.martin.Squint.Extension
        pkill -f SquintExtension
        qlmanage -r >/dev/null 2>&1; qlmanage -r cache >/dev/null 2>&1
        [ "$4" = 1 ] && open "$3"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "squint-update", String(getpid()), staged.app.path, Bundle.main.bundlePath, relaunch ? "1" : "0"]
        try? p.run()
    }

    // MARK: - UI

    private func showProgress(version: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Updating Squint"
        let label = NSTextField(labelWithString: "Downloading Squint \(version)…")
        label.frame = NSRect(x: 20, y: 60, width: 320, height: 18)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 40, width: 320, height: 16))
        bar.isIndeterminate = false
        bar.maxValue = 1
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelDownload(_:)))
        cancel.frame = NSRect(x: 260, y: 6, width: 84, height: 28)
        [label, bar, cancel].forEach { panel.contentView?.addSubview($0) }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        progressPanel = panel
    }

    @objc private func cancelDownload(_ sender: Any?) {
        task?.cancel()
        closeProgress()
    }

    private func closeProgress() {
        progressObservation = nil
        task = nil
        progressPanel?.close()
        progressPanel = nil
    }

    /// Ends a download; any thread.
    private func finish(error: String?) {
        DispatchQueue.main.async { [self] in
            let cancelled = progressPanel == nil
            closeProgress()
            if let error, !cancelled { fail("The update couldn't be installed.", error) }
        }
    }

    private func offerRestart(version: String) {
        let alert = NSAlert()
        alert.messageText = "Squint \(version) is ready"
        alert.informativeText = "It's installed when Squint quits."
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { relaunch = true; NSApp.terminate(nil) }
    }

    private func fail(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.runModal()
    }
}
