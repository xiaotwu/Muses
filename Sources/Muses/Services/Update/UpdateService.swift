import Foundation
import AppKit

/// GitHub Release update-check service.
///
/// Queries the latest release via the GitHub Releases API
/// (`api.github.com/repos/xiaotwu/noname123/releases/latest`) and compares it with the
/// current `CFBundleShortVersionString`. When a newer version exists it exposes
/// `hasUpdate` / `latestVersion` / `releaseURL`; the settings page shows this and offers
/// a "Download" button that opens the GitHub Release page (personal use; no auto-install).
///
/// Persists "last check time" and "last known latest version" in UserDefaults so the app
/// does not hit the network on every launch. The unauthenticated GitHub API limit is
/// 60 req/hr/IP, far more than enough for personal use.
@Observable
@MainActor
final class UpdateService {
    /// GitHub repository identifier (`owner/repo`).
    let repo: String
    /// Current app version (`CFBundleShortVersionString`, no build number).
    private(set) var currentVersion: String
    /// Latest version from the most recent check (leading "v" stripped); nil means not yet checked or the check failed.
    private(set) var latestVersion: String?
    /// HTML page URL of the latest release (opened by the "Download" button).
    private(set) var releaseURL: URL?
    /// Whether a check is in progress (re-entrancy guard + UI spinner).
    private(set) var isChecking = false
    /// Description of the last error (nil = success or not yet checked).
    private(set) var lastError: String?

    private let session: URLSession
    private let defaults: UserDefaults
    private let log = AppLog.for("UpdateService")

    init(repo: String = "xiaotwu/noname123",
         session: URLSession = .shared,
         defaults: UserDefaults = .standard) {
        self.repo = repo
        self.session = session
        self.defaults = defaults
        let info = Bundle.main.infoDictionary
        self.currentVersion = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        // Restore the previously cached latest version (keeps the UI non-empty between launch and the first check).
        if let cached = defaults.string(forKey: PrefKey.latestKnownVersion) {
            latestVersion = cached
        }
    }

    /// Whether a release newer than the current version exists.
    var hasUpdate: Bool {
        guard let latest = latestVersion else { return false }
        return semverCompare(latest, currentVersion) > 0
    }

    /// Seconds since the last check; `nil` means it has never run.
    var secondsSinceLastCheck: Double? {
        guard let t = defaults.object(forKey: PrefKey.lastUpdateCheckAt) as? Date else { return nil }
        return Date().timeIntervalSince(t)
    }

    /// Queries the latest GitHub release and refreshes state. On a network error sets
    /// `lastError` and leaves the existing `latestVersion` untouched (the last cache is kept).
    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            lastError = "Invalid repository URL"
            return
        }
        var req = URLRequest(url: url)
        // GitHub API requires a User-Agent; Accept asks for JSON.
        req.setValue("Muses-UpdateChecker", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Short timeout so failures return quickly.
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                lastError = "Non-HTTP response"; return
            }
            guard (200..<300).contains(http.statusCode) else {
                lastError = "GitHub API returned \(http.statusCode)"
                log.error("Update check failed: \(self.lastError ?? "")")
                return
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = "Failed to parse response"; return
            }
            let tag = obj["tag_name"] as? String ?? ""
            let clean = tag.hasPrefix("v") || tag.hasPrefix("V")
                ? String(tag.dropFirst())
                : tag
            guard !clean.isEmpty else { lastError = "tag_name is empty"; return }

            latestVersion = clean
            releaseURL = (obj["html_url"] as? String).flatMap(URL.init(string:))
            defaults.set(clean, forKey: PrefKey.latestKnownVersion)
            defaults.set(Date(), forKey: PrefKey.lastUpdateCheckAt)
            log.info("Update check completed: latest \(clean), current \(self.currentVersion), hasUpdate=\(self.hasUpdate)")
        } catch {
            lastError = error.localizedDescription
            log.error("Update check network error: \(error.localizedDescription)")
        }
    }

    /// Triggers a check if more than `interval` seconds have passed since the last one and the preference allows it.
    func checkIfDue(interval: TimeInterval = 86_400) async {
        let enabled = defaults.object(forKey: PrefKey.checkForUpdates) as? Bool ?? true
        guard enabled else { return }
        if let elapsed = secondsSinceLastCheck, elapsed < interval { return }
        await checkForUpdates()
    }

    /// Opens the latest release page (if any); otherwise the repository home page.
    func openReleasePage() {
        let target = releaseURL ?? URL(string: "https://github.com/\(repo)/releases")
        if let target { NSWorkspace.shared.open(target) }
    }

    // MARK: - Semver comparison

    /// Compares `a` and `b` (e.g. "0.4.0"); returns -1/0/1. Non-numeric segments count as 0.
    private func semverCompare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return -1 }
            if x > y { return 1 }
        }
        return 0
    }
}