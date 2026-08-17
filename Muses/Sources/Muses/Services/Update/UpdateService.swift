import Foundation
import AppKit

/// GitHub Release 更新检查服务。
///
/// 通过 GitHub Releases API(`api.github.com/repos/xiaotwu/noname123/releases/latest`)
/// 查询最新版本,与当前 `CFBundleShortVersionString` 比较。有新版本时暴露
/// `hasUpdate` / `latestVersion` / `releaseURL`,由设置页展示并提供"下载"按钮
/// 跳转到 GitHub Release 页(个人使用,不做自动安装)。
///
/// 用 UserDefaults 持久化"最近一次检查时间"与"最近已知最新版本",避免每次启动
/// 都打网络。未认证的 GitHub API 限额 60 req/hr/IP,个人使用绰绰有余。
@Observable
@MainActor
final class UpdateService {
    /// GitHub 仓库标识(`owner/repo`)。
    let repo: String
    /// 当前应用版本(`CFBundleShortVersionString`,无 build 号)。
    private(set) var currentVersion: String
    /// 最近一次查询到的最新版本号(已去掉前导 "v");nil 表示尚未查询或查询失败。
    private(set) var latestVersion: String?
    /// 最新 Release 的 HTML 页 URL(供"下载"按钮打开)。
    private(set) var releaseURL: URL?
    /// 是否正在检查中(防重入 + UI spinner)。
    private(set) var isChecking = false
    /// 最近一次错误描述(nil 表示成功或尚未检查)。
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
        // 恢复上次缓存的最新版本(避免启动后到首次检查前 UI 显示空)。
        if let cached = defaults.string(forKey: PrefKey.latestKnownVersion) {
            latestVersion = cached
        }
    }

    /// 是否存在比当前版本更新的 Release。
    var hasUpdate: Bool {
        guard let latest = latestVersion else { return false }
        return semverCompare(latest, currentVersion) > 0
    }

    /// 距上次检查的秒数;`nil` 表示从未检查过。
    var secondsSinceLastCheck: Double? {
        guard let t = defaults.object(forKey: PrefKey.lastUpdateCheckAt) as? Date else { return nil }
        return Date().timeIntervalSince(t)
    }

    /// 查询 GitHub Releases 最新版本并刷新状态。网络错误时设置 `lastError`,
    /// 不改变已有 `latestVersion`(保留上次缓存)。
    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            lastError = "无效的仓库地址"
            return
        }
        var req = URLRequest(url: url)
        // GitHub API 要求 User-Agent;Accept 拿 JSON。
        req.setValue("Muses-UpdateChecker", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // 短超时,失败快速返回。
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                lastError = "非 HTTP 响应"; return
            }
            guard (200..<300).contains(http.statusCode) else {
                lastError = "GitHub API 返回 \(http.statusCode)"
                log.error("更新检查失败:\(self.lastError ?? "")")
                return
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastError = "响应解析失败"; return
            }
            let tag = obj["tag_name"] as? String ?? ""
            let clean = tag.hasPrefix("v") || tag.hasPrefix("V")
                ? String(tag.dropFirst())
                : tag
            guard !clean.isEmpty else { lastError = "tag_name 为空"; return }

            latestVersion = clean
            releaseURL = (obj["html_url"] as? String).flatMap(URL.init(string:))
            defaults.set(clean, forKey: PrefKey.latestKnownVersion)
            defaults.set(Date(), forKey: PrefKey.lastUpdateCheckAt)
            log.info("更新检查完成:最新 \(clean),当前 \(self.currentVersion),有更新=\(self.hasUpdate)")
        } catch {
            lastError = error.localizedDescription
            log.error("更新检查网络错误:\(error.localizedDescription)")
        }
    }

    /// 若距上次检查超过 `interval`(秒)且偏好允许,则触发一次检查。
    func checkIfDue(interval: TimeInterval = 86_400) async {
        let enabled = defaults.object(forKey: PrefKey.checkForUpdates) as? Bool ?? true
        guard enabled else { return }
        if let elapsed = secondsSinceLastCheck, elapsed < interval { return }
        await checkForUpdates()
    }

    /// 打开最新 Release 页(若有);否则打开仓库主页。
    func openReleasePage() {
        let target = releaseURL ?? URL(string: "https://github.com/\(repo)/releases")
        if let target { NSWorkspace.shared.open(target) }
    }

    // MARK: - Semver 比较

    /// 比较 `a` 与 `b`(形如 "0.4.0");返回 -1/0/1。非数字段按 0 处理。
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