//  UpdateChecker.swift
//  CastPilot
//
//  Reads GitHub releases, downloads and swaps the app bundle in place.

import Foundation
import Combine
import AppKit

// MARK: - Update Checker

/// Checks GitHub for the latest release tag and exposes whether an update is available.
/// Since the App Sandbox is disabled, the app can download the release zip and replace
/// itself in place (via a detached relaunch script), so the UI offers a real 1-click update.
/// The "Copy update command" path is kept only as a fallback when the in-app install fails.
class UpdateChecker: ObservableObject {
    @Published var latestVersion: String? = nil
    @Published var isChecking = false
    @Published var lastError: String? = nil
    @Published var isInstalling = false
    @Published var installError: String? = nil

    static let repoSlug = "omegajani/CastPilot"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return Self.compare(latest, currentVersion) > 0
    }

    var releasePageURL: URL {
        // The releases list page — not /latest, which on GitHub resolves to the newest
        // NON-prerelease (v1.6 on main) and would hide the feature/covers prereleases.
        URL(string: "https://github.com/\(Self.repoSlug)/releases")!
    }

    /// Fetches the releases list (incl. prereleases) and returns the highest-semver release.
    /// We must NOT use /releases/latest — GitHub returns only the newest non-prerelease there,
    /// which is v1.6 on main, so the feature/covers prereleases would never be seen.
    private func bestRelease() async throws -> (tag: String, zipURL: URL?)? {
        let url = URL(string: "https://api.github.com/repos/\(Self.repoSlug)/releases?per_page=30")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var best: (tag: String, dict: [String: Any])? = nil
        for r in arr where (r["draft"] as? Bool) != true {
            guard let raw = r["tag_name"] as? String else { continue }
            let v = raw.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            if best == nil || Self.compare(v, best!.tag) > 0 { best = (v, r) }
        }
        guard let b = best else { return nil }
        let assets = b.dict["assets"] as? [[String: Any]] ?? []
        let zip = assets.compactMap { $0["browser_download_url"] as? String }.first { $0.hasSuffix(".zip") }
        return (b.tag, zip.flatMap { URL(string: $0) })
    }

    /// One-line shell command that downloads the latest release and replaces the installed
    /// app — without touching the user's config.json. Same as the README "Update" snippet.
    static var updateCommand: String {
        // Note: inside single quotes the shell takes characters literally, so we want '"' (just a
        // quote), not '\"' (backslash + quote — that's what tripped cut(1) before).
        """
        curl -sL "$(curl -sL https://api.github.com/repos/\(UpdateChecker.repoSlug)/releases | grep browser_download_url | head -1 | cut -d '"' -f 4)" -o /tmp/MCS.zip && unzip -qo /tmp/MCS.zip -d /tmp/MCS && rm -rf "/Applications/Midi Cast Switcher.app" "/Applications/CastPilot.app" && mv "/tmp/MCS/CastPilot.app" /Applications/ && xattr -cr "/Applications/CastPilot.app" && rm -rf /tmp/MCS /tmp/MCS.zip && open "/Applications/CastPilot.app"
        """
    }

    func check() async {
        isChecking = true; lastError = nil
        defer { isChecking = false }
        do {
            if let best = try await bestRelease() {
                latestVersion = best.tag
            } else {
                lastError = "Keine Releases gefunden"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Downloads the latest release zip, unpacks it with ditto (which preserves the bundle's
    /// ad-hoc code signature), then hands off to a detached shell script that waits for this
    /// process to quit, swaps the app bundle in place, clears quarantine and relaunches.
    /// Requires the sandbox to be OFF (a sandboxed app — and any child it spawns — cannot
    /// write to /Applications).
    func downloadAndInstall() async {
        isInstalling = true; installError = nil
        defer { isInstalling = false }
        do {
            // 1. Resolve the .zip asset URL from the highest-semver release (incl. prereleases).
            guard let best = try await bestRelease(), let zipURL = best.zipURL
            else { installError = "Kein Zip im Release gefunden."; return }

            // 2. Download the zip. A programmatic download does NOT set the com.apple.quarantine
            //    xattr, so the relaunched app won't trip Gatekeeper.
            let (tmpZip, _) = try await URLSession.shared.download(from: zipURL)
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCSUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zipDest = work.appendingPathComponent("MCS.zip")
            try FileManager.default.moveItem(at: tmpZip, to: zipDest)

            // 3. Unpack with ditto (better than unzip for .app bundles + signatures).
            let unpack = work.appendingPathComponent("unpacked")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-xk", zipDest.path, unpack.path]
            try ditto.run(); ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                installError = "Entpacken fehlgeschlagen."; return
            }

            // 4. Locate the new .app (named CastPilot.app since the 2.0 rebrand).
            let newApp = unpack.appendingPathComponent("CastPilot.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else {
                installError = "App im Zip nicht gefunden."; return
            }
            // Install next to where we currently run from (usually /Applications), always under
            // the new name. `oldBundle` is whatever we launched as — for users coming from the
            // pre-rebrand build that's "Midi Cast Switcher.app", which we remove.
            let oldBundle = Bundle.main.bundlePath
            let installDir = (oldBundle as NSString).deletingLastPathComponent
            let finalTarget = (installDir as NSString).appendingPathComponent("CastPilot.app")

            // 5. Write a relaunch script and launch it detached. It waits for our PID to exit,
            //    removes the old bundle, moves the new one into place, clears quarantine, reopens.
            let script = """
            #!/bin/sh
            APP_PID="$1"; NEW="$2"; OLD="$3"; FINAL="$4"
            while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.2; done
            sleep 0.3
            rm -rf "$OLD"
            rm -rf "$FINAL"
            mv "$NEW" "$FINAL"
            xattr -cr "$FINAL"
            open "$FINAL"
            """
            let scriptURL = work.appendingPathComponent("relaunch.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [scriptURL.path,
                              String(ProcessInfo.processInfo.processIdentifier),
                              newApp.path, oldBundle, finalTarget]
            try task.run()

            // 6. Quit so the detached script can replace the running bundle.
            NSApp.terminate(nil)
        } catch {
            installError = error.localizedDescription
        }
    }

    /// Semver-ish comparison. Returns -1, 0, +1 like strcmp.
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let ai = i < pa.count ? pa[i] : 0
            let bi = i < pb.count ? pb[i] : 0
            if ai != bi { return ai < bi ? -1 : 1 }
        }
        return 0
    }
}

