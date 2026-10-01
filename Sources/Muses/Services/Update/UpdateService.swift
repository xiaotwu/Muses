import Foundation
import AppKit
import Observation

enum UpdatePhase: Equatable {
    case idle, checking, available, downloading, verifying, ready, installing, upToDate, failed
}

struct AvailableUpdate: Equatable {
    let version: String
    let build: String
    let releaseURL: URL?
    let informationOnly: Bool
}

enum UpdateEvent {
    case checking, found(AvailableUpdate), downloading, progress(Double?), verifying, ready
    case installing, notFound(String), failed(String), dismissed, canCheckChanged(Bool)
}

@MainActor
protocol UpdateEngine: AnyObject {
    var onEvent: ((UpdateEvent) -> Void)? { get set }
    var permitsRelaunch: (() -> Bool)? { get set }
    var canCheck: Bool { get }
    var canInstall: Bool { get }
    func start(automaticallyChecks: Bool) throws
    func setAutomaticallyChecks(_ enabled: Bool)
    func check(userInitiated: Bool)
    func download()
    func install()
    func cancel()
}

/// App-lifetime facade. Sparkle owns downloads and the external installer.
/// Muses owns user intent, the persistence gate, and successful-launch acknowledgment.
@Observable
@MainActor
final class UpdateService {
    let currentVersion: String
    private(set) var phase: UpdatePhase = .idle
    private(set) var update: AvailableUpdate?
    private(set) var downloadProgress: Double?
    private(set) var lastError: String?
    private(set) var countdown: Int?
    private(set) var automaticallyChecks: Bool
    private(set) var automaticallyInstalls: Bool
    private(set) var isConfigured: Bool

    @ObservationIgnored private let engine: any UpdateEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transactions: UpdateTransactionStore
    @ObservationIgnored private let configurationError: String?
    private(set) var started = false
    private(set) var engineCanCheck = false
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var deferred = false
    @ObservationIgnored private var deferredBuild: String?
    @ObservationIgnored private let log = AppLog.for("UpdateService")
    @ObservationIgnored private var installationRequested = false
    @ObservationIgnored private var alert: NSAlert?
    @ObservationIgnored private var alertWindow: NSWindow?
    @ObservationIgnored var automaticRestartBlocked: () -> Bool = { true }
    @ObservationIgnored var criticalOperationInProgress: () -> Bool = { true }
    @ObservationIgnored var prepareToInstall: () throws -> Void = { throw UpdateFailure.stateNotReady }
    @ObservationIgnored var presentCountdown: (Int) -> Bool = { _ in false }
    @ObservationIgnored var updateCountdown: (Int) -> Void = { _ in }
    @ObservationIgnored var dismissCountdown: () -> Void = {}

    init(engine: (any UpdateEngine)? = nil, defaults: UserDefaults = .standard,
         transactions: UpdateTransactionStore? = nil, bundle: Bundle = .main) {
        self.defaults = defaults
        self.transactions = transactions ?? UpdateTransactionStore(defaults: defaults)
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        automaticallyChecks = defaults.object(forKey: PrefKey.checkForUpdates) as? Bool ?? true
        automaticallyInstalls = defaults.bool(forKey: PrefKey.installUpdatesAutomatically)
        let error = UpdateConfiguration.validationError(bundle: bundle)
        isConfigured = engine != nil || error == nil
        configurationError = engine == nil ? error : nil
        self.engine = engine ?? SparkleUpdateEngine(bundle: bundle)
        self.engine.onEvent = { [weak self] event in self?.receive(event) }
        self.engine.permitsRelaunch = { [weak self] in self?.installationRequested == true }
    }

    var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    var latestVersion: String? { update?.version }
    var hasUpdate: Bool { update != nil }
    var isChecking: Bool { phase == .checking }
    var canCheck: Bool { isConfigured && started && engineCanCheck }
    var canDownload: Bool { phase == .available && update?.informationOnly == false }
    var canInstall: Bool { (phase == .ready || phase == .failed) && engine.canInstall }
    var canCancelDownload: Bool { phase == .downloading || phase == .checking }

    /// Runs before new downloads, only after the real store and main window are ready.
    func startAfterSuccessfulLaunch(build: String, persistentStoreReady: Bool) {
        guard !started else { return }
        guard persistentStoreReady else {
            receive(.failed(UpdateFailure.stateNotReady.localizedDescription))
            return
        }
        do {
            try transactions.acknowledgeSuccessfulLaunch(build: build)
        } catch {
            lastError = tr("Update cleanup will be retried: ", "更新清理将在下次启动重试：") + error.localizedDescription
            phase = .failed
            return
        }
        guard isConfigured else { return }
        do {
            try engine.start(automaticallyChecks: automaticallyChecks)
            started = true
            engineCanCheck = engine.canCheck
        } catch {
            receive(.failed(error.localizedDescription))
        }
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        automaticallyChecks = enabled
        defaults.set(enabled, forKey: PrefKey.checkForUpdates)
        if started { engine.setAutomaticallyChecks(enabled) }
        if !enabled { setAutomaticallyInstalls(false) }
    }

    func setAutomaticallyInstalls(_ enabled: Bool) {
        automaticallyInstalls = enabled
        defaults.set(enabled, forKey: PrefKey.installUpdatesAutomatically)
        if enabled {
            setAutomaticallyChecks(true)
            deferred = false
            deferredBuild = nil
            if canDownload { downloadUpdate() }
            if phase == .ready { beginScheduling() }
        } else {
            stopScheduling()
        }
    }

    func checkForUpdates() async {
        guard canCheck else {
            if !isConfigured { lastError = configurationError }
            return
        }
        lastError = nil
        engine.check(userInitiated: true)
    }

    func downloadUpdate() {
        guard canDownload else { return }
        lastError = nil
        engine.download()
    }

    func cancelDownload() {
        guard canCancelDownload else { return }
        engine.cancel()
    }

    func deferRestart() {
        deferred = true
        deferredBuild = update?.build
        log.info("Automatic update restart deferred")
        stopScheduling()
    }

    func installNow(automatically: Bool = false) {
        if automatically && (!automaticallyInstalls || deferred) { return }
        guard canInstall else { return }
        guard !criticalOperationInProgress() else {
            lastError = tr("Wait for the current import or synchronization to finish.", "请等待当前导入或同步完成。")
            return
        }
        do {
            try prepareToInstall()
            guard let update else { throw UpdateFailure.stateNotReady }
            try transactions.begin(targetBuild: update.build)
        } catch {
            lastError = error.localizedDescription
            deferRestart()
            return
        }
        stopScheduling()
        installationRequested = true
        log.info("Update installation requested; automatic=\(automatically)")
        phase = .installing
        engine.install()
    }

    /// Final gate for Sparkle's quit request and ordinary quits with a staged update.
    func allowsTermination() -> Bool {
        guard phase == .verifying || phase == .ready || phase == .installing || installationRequested else { return true }
        guard !criticalOperationInProgress() else { return false }
        do {
            try prepareToInstall()
            if let update { try transactions.begin(targetBuild: update.build) }
            return true
        } catch {
            lastError = error.localizedDescription
            phase = .ready
            deferRestart()
            return false
        }
    }

    func openReleasePage() {
        let url = update?.releaseURL ?? URL(string: "https://github.com/xiaotwu/Muses-Polyhymnia/releases")!
        NSWorkspace.shared.open(url)
    }

    func receive(_ event: UpdateEvent) {
        switch event {
        case .canCheckChanged(let value):
            engineCanCheck = value
        case .checking:
            phase = .checking
            update = nil
            lastError = nil
        case .found(let item):
            update = item
            phase = .available
            deferred = deferredBuild == item.build
            log.info("Update found: build \(item.build), restart deferred=\(self.deferred)")
            if automaticallyInstalls && !item.informationOnly { downloadUpdate() }
        case .downloading:
            phase = .downloading
            downloadProgress = nil
        case .progress(let value):
            downloadProgress = value.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        case .verifying: phase = .verifying
        case .ready:
            log.info("Update verified and ready")
            phase = .ready
            beginScheduling()
        case .installing: phase = .installing
        case .notFound(let message):
            phase = .upToDate
            lastError = message.isEmpty ? nil : message
        case .failed(let message):
            stopScheduling()
            phase = .failed
            lastError = message
            installationRequested = engine.canInstall
        case .dismissed:
            stopScheduling()
            installationRequested = false
            if phase != .failed && phase != .upToDate && phase != .installing { phase = .idle }
        }
    }

    private func beginScheduling() {
        guard automaticallyInstalls, !deferred, phase == .ready, scheduleTask == nil else { return }
        scheduleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .ready, self.automaticallyInstalls, !self.deferred else { return }
                self.advanceAutomaticRestart()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    /// One low-frequency clock only while ready; tests advance it without sleeping.
    func advanceAutomaticRestart() {
        guard phase == .ready, automaticallyInstalls, !deferred else { return }
        if automaticRestartBlocked() || criticalOperationInProgress() {
            countdown = nil
            dismissCountdown()
            return
        }
        guard let remaining = countdown else {
            guard presentCountdown(15) else { return }
            countdown = 15
            return
        }
        if remaining > 1 {
            countdown = remaining - 1
            updateCountdown(remaining - 1)
        } else {
            installNow(automatically: true)
        }
    }

    private func stopScheduling() {
        scheduleTask?.cancel()
        scheduleTask = nil
        countdown = nil
        dismissCountdown()
    }

    /// Native global notice: automatic relaunch is visible outside Settings.
    func configureNativeCountdown() {
        presentCountdown = { [weak self] seconds in
            guard let self, let window = NSApp.keyWindow ?? NSApp.mainWindow,
                  window.attachedSheet == nil else { return false }
            let alert = NSAlert()
            alert.messageText = tr("Muses is ready to update", "Muses 已准备好更新")
            alert.informativeText = self.countdownMessage(seconds)
            alert.addButton(withTitle: tr("Later", "稍后"))
            alert.addButton(withTitle: tr("Update Now", "立即更新"))
            self.alert = alert
            self.alertWindow = window
            alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                guard let self, self.alert === alert else { return }
                self.alert = nil
                self.alertWindow = nil
                self.log.info("Update countdown response: \(response.rawValue)")
                if response == .alertSecondButtonReturn { self.installNow() }
                else { self.deferRestart() }
            }
            return true
        }
        updateCountdown = { [weak self] seconds in
            guard let self else { return }
            self.alert?.informativeText = self.countdownMessage(seconds)
        }
        dismissCountdown = { [weak self] in
            guard let self, let alert = self.alert else { return }
            self.alert = nil
            self.alertWindow?.endSheet(alert.window)
            self.alertWindow = nil
        }
    }

    private func countdownMessage(_ seconds: Int) -> String {
        tr("Muses will save your playback position and restart in \(seconds) seconds.",
           "Muses 将保存播放位置，并在 \(seconds) 秒后重新启动。")
    }
}

enum UpdateFailure: LocalizedError {
    case stateNotReady, persistenceFailed, unsafeCleanupPath
    var errorDescription: String? {
        switch self {
        case .stateNotReady: tr("The library is not ready for an update.", "资料库尚未准备好更新。")
        case .persistenceFailed: tr("Could not save playback state. The update was postponed.", "无法保存播放状态，更新已推迟。")
        case .unsafeCleanupPath: tr("The update cleanup location is invalid.", "更新清理位置无效。")
        }
    }
}

enum UpdateConfiguration {
    static let productionFeed = "https://github.com/xiaotwu/Muses-Polyhymnia/releases/download/updates/appcast.xml"

    static func validationError(bundle: Bundle) -> String? {
        validationError(info: bundle.infoDictionary ?? [:], isApplication: bundle.bundleURL.pathExtension == "app",
                        bundleID: bundle.bundleIdentifier)
    }

    static func validationError(info: [String: Any], isApplication: Bool, bundleID: String?) -> String? {
        let acceptance = MusesDataPaths.acceptanceNamespace(bundleID: bundleID) != nil
        let url = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        // Explicitly marked disposable acceptance builds may use a signed feed on
        // loopback HTTP. Production and all other builds always require HTTPS.
        let localAcceptance = acceptance && info["MusesUpdateAcceptanceLoopback"] as? Bool == true
            && url?.scheme == "http" && url?.host == "127.0.0.1" && url?.port != nil
        guard isApplication, bundleID == "com.muses.app" || acceptance,
              let url, url.scheme == "https" || localAcceptance, url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              !(acceptance && url.absoluteString == productionFeed),
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true else {
            return tr("Automatic updates are not configured in this build.", "此构建尚未配置自动更新。")
        }
        return nil
    }
}
