import Foundation
import Testing
@testable import Muses

@MainActor
private final class FakeUpdateEngine: UpdateEngine {
    var onEvent: ((UpdateEvent) -> Void)?
    var permitsRelaunch: (() -> Bool)?
    var canCheck = true
    var canInstall = true
    var started = 0
    var checks = 0
    var downloads = 0
    var installs = 0
    var cancellations = 0
    var automaticChecks = false
    func start(automaticallyChecks: Bool) throws {
        started += 1
        automaticChecks = automaticallyChecks
    }
    func setAutomaticallyChecks(_ enabled: Bool) { automaticChecks = enabled }
    func check(userInitiated: Bool) { checks += 1; onEvent?(.checking) }
    func download() { downloads += 1; onEvent?(.downloading) }
    func install() { installs += 1; onEvent?(.installing) }
    func cancel() { cancellations += 1; onEvent?(.dismissed) }
}

@Suite("Automatic updates", .serialized)
@MainActor
struct AutomaticUpdateTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "com.muses.tests.updates.\(UUID())")!
    }
    private var item: AvailableUpdate {
        AvailableUpdate(version: "0.6.0", build: "20261001.1", releaseURL: nil, informationOnly: false)
    }
    private func service(_ defaults: UserDefaults, engine: FakeUpdateEngine) -> UpdateService {
        let store = UpdateTransactionStore(defaults: defaults, cleanup: {})
        let service = UpdateService(engine: engine, defaults: defaults, transactions: store)
        service.criticalOperationInProgress = { false }
        service.automaticRestartBlocked = { false }
        service.prepareToInstall = {}
        service.presentCountdown = { _ in true }
        return service
    }

    @Test("Successful launch starts exactly one updater and fallback stores never acknowledge")
    func launchGate() throws {
        let defaults = defaults()
        let engine = FakeUpdateEngine()
        var cleanups = 0
        let store = UpdateTransactionStore(defaults: defaults, cleanup: { cleanups += 1 })
        try store.begin(targetBuild: "2")
        let service = UpdateService(engine: engine, defaults: defaults, transactions: store)
        service.startAfterSuccessfulLaunch(build: "2", persistentStoreReady: false)
        #expect(engine.started == 0)
        #expect(cleanups == 0)
        #expect(defaults.data(forKey: UpdateTransactionStore.key) != nil)
        service.startAfterSuccessfulLaunch(build: "2", persistentStoreReady: true)
        service.startAfterSuccessfulLaunch(build: "2", persistentStoreReady: true)
        #expect(engine.started == 1)
        #expect(cleanups == 1)
    }

    @Test("Automatic install is opt-in and uses the existing check preference")
    func preferences() {
        let defaults = defaults()
        let engine = FakeUpdateEngine()
        let service = service(defaults, engine: engine)
        #expect(!service.automaticallyInstalls)
        service.receive(.found(item))
        #expect(engine.downloads == 0)
        service.setAutomaticallyInstalls(true)
        #expect(engine.downloads == 1)
        #expect(service.automaticallyChecks)
        service.setAutomaticallyChecks(false)
        #expect(!service.automaticallyInstalls)
        #expect(!defaults.bool(forKey: PrefKey.installUpdatesAutomatically))
    }

    @Test("Informational updates never start a download")
    func informationOnly() {
        let engine = FakeUpdateEngine()
        let service = service(defaults(), engine: engine)
        service.setAutomaticallyInstalls(true)
        service.receive(.found(.init(version: "1", build: "2", releaseURL: nil, informationOnly: true)))
        #expect(engine.downloads == 0)
        #expect(!service.canDownload)
    }

    @Test("Playback blocks restart and a resumed operation resets the full countdown")
    func playbackDeferral() {
        let engine = FakeUpdateEngine()
        let service = service(defaults(), engine: engine)
        service.setAutomaticallyInstalls(true)
        service.receive(.found(item))
        service.receive(.ready)
        service.automaticRestartBlocked = { true }
        service.advanceAutomaticRestart()
        #expect(service.countdown == nil)
        #expect(engine.installs == 0)
        service.automaticRestartBlocked = { false }
        service.advanceAutomaticRestart()
        #expect(service.countdown == 15)
        service.advanceAutomaticRestart()
        #expect(service.countdown == 14)
        service.criticalOperationInProgress = { true }
        service.advanceAutomaticRestart()
        #expect(service.countdown == nil)
        service.criticalOperationInProgress = { false }
        service.advanceAutomaticRestart()
        #expect(service.countdown == 15)
        service.deferRestart()
    }

    @Test("Countdown requires a visible notice and saves before invoking the installer")
    func countdownInstalls() {
        let defaults = defaults()
        let engine = FakeUpdateEngine()
        let service = service(defaults, engine: engine)
        service.setAutomaticallyInstalls(true)
        service.receive(.found(item))
        service.receive(.ready)
        service.presentCountdown = { _ in false }
        service.advanceAutomaticRestart()
        #expect(service.countdown == nil)
        var saved = false
        service.prepareToInstall = { saved = true }
        service.presentCountdown = { _ in true }
        for _ in 0..<16 { service.advanceAutomaticRestart() }
        #expect(saved)
        #expect(engine.installs == 1)
        #expect(defaults.data(forKey: UpdateTransactionStore.key) != nil)
    }

    @Test("Later and disabling automatic installation prevent further automatic restarts")
    func cancelCountdown() {
        let engine = FakeUpdateEngine()
        let service = service(defaults(), engine: engine)
        service.setAutomaticallyInstalls(true)
        service.receive(.found(item))
        service.receive(.ready)
        service.advanceAutomaticRestart()
        service.deferRestart()
        for _ in 0..<20 { service.advanceAutomaticRestart() }
        #expect(engine.installs == 0)
        service.setAutomaticallyInstalls(true)
        service.advanceAutomaticRestart()
        service.setAutomaticallyInstalls(false)
        #expect(service.countdown == nil)
        service.installNow()
        #expect(engine.installs == 1)
    }

    @Test("Persistence failure and active writes prevent installation and termination")
    func failedPersistence() {
        let defaults = defaults()
        let engine = FakeUpdateEngine()
        let service = service(defaults, engine: engine)
        service.receive(.found(item))
        service.receive(.ready)
        service.prepareToInstall = { throw UpdateFailure.persistenceFailed }
        service.installNow()
        #expect(engine.installs == 0)
        #expect(defaults.data(forKey: UpdateTransactionStore.key) == nil)
        #expect(!service.allowsTermination())
        service.prepareToInstall = {}
        service.criticalOperationInProgress = { true }
        service.installNow()
        #expect(engine.installs == 0)
        #expect(!service.allowsTermination())
        service.criticalOperationInProgress = { false }
        service.installNow()
        #expect(engine.installs == 1)
    }

    @Test("Canceling a download returns to idle without creating an install transaction")
    func cancelDownload() {
        let defaults = defaults()
        let engine = FakeUpdateEngine()
        let service = service(defaults, engine: engine)
        service.receive(.found(item))
        service.downloadUpdate()
        #expect(service.phase == .downloading)
        service.cancelDownload()
        #expect(service.phase == .idle)
        #expect(engine.cancellations == 1)
        #expect(defaults.data(forKey: UpdateTransactionStore.key) == nil)
    }

    @Test("Cleanup waits for target build and retries without losing its transaction")
    func cleanupRetry() throws {
        let defaults = defaults()
        var attempts = 0
        let store = UpdateTransactionStore(defaults: defaults, cleanup: {
            attempts += 1
            if attempts == 1 { throw UpdateFailure.unsafeCleanupPath }
        })
        try store.begin(targetBuild: "10")
        try store.acknowledgeSuccessfulLaunch(build: "9")
        #expect(attempts == 0)
        #expect(throws: UpdateFailure.self) { try store.acknowledgeSuccessfulLaunch(build: "10") }
        #expect(defaults.data(forKey: UpdateTransactionStore.key) != nil)
        try store.acknowledgeSuccessfulLaunch(build: "11")
        try store.acknowledgeSuccessfulLaunch(build: "11")
        #expect(attempts == 2)
        #expect(defaults.data(forKey: UpdateTransactionStore.key) == nil)
    }

    @Test("Cleanup removes only persistent update downloads and never follows symlinks")
    func cleanupBoundaries() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let cache = root.appending(path: "com.muses.app.sparkle/org.sparkle-project.Sparkle")
        let downloads = cache.appending(path: "PersistentDownloads")
        let installation = cache.appending(path: "Installation")
        let media = root.appending(path: "streams/track")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: installation, withIntermediateDirectories: true)
        try fm.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("music".utf8).write(to: media)
        try Data("update".utf8).write(to: downloads.appending(path: "update.zip"))
        try Data("installer".utf8).write(to: installation.appending(path: "active"))
        try UpdateTransactionStore.cleanPersistentDownloads(bundleID: "com.muses.app", caches: root)
        #expect(try fm.contentsOfDirectory(atPath: downloads.path).isEmpty)
        #expect(fm.fileExists(atPath: media.path))
        #expect(fm.fileExists(atPath: installation.appending(path: "active").path))
        try fm.removeItem(at: downloads)
        try fm.createSymbolicLink(at: downloads, withDestinationURL: media.deletingLastPathComponent())
        #expect(throws: UpdateFailure.self) {
            try UpdateTransactionStore.cleanPersistentDownloads(bundleID: "com.muses.app", caches: root)
        }
        #expect(fm.fileExists(atPath: media.path))
    }

    @Test("Updater storage relocation preserves archives and rejects foreign links or active installers")
    func updaterStorageRelocation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let system = root.appending(path: "system")
        // Production MusesDataPaths marks the cache URL as a directory. A
        // trailing slash must not make an existing valid redirect look foreign.
        let managed = root.appending(path: "managed", directoryHint: .isDirectory)
        let source = system.appending(path: "com.muses.app.sparkle")
        let archive = source.appending(path: "org.sparkle-project.Sparkle/PersistentDownloads/update.zip")
        try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("archive".utf8).write(to: archive)
        try UpdateTransactionStore.prepareDownloadDirectory(bundleID: "com.muses.app", systemCaches: system, managedCaches: managed)
        let target = managed.appending(path: "updates/com.muses.app.sparkle")
        #expect(source.resolvingSymlinksInPath() == target.resolvingSymlinksInPath())
        #expect(try Data(contentsOf: archive) == Data("archive".utf8))
        try UpdateTransactionStore.prepareDownloadDirectory(bundleID: "com.muses.app", systemCaches: system, managedCaches: managed)
        // Existing redirects may store the same destination without a slash.
        // Match the link left on disk after the production upgrade.
        try fm.removeItem(at: source)
        try fm.createSymbolicLink(atPath: source.path, withDestinationPath: target.path)
        try UpdateTransactionStore.prepareDownloadDirectory(bundleID: "com.muses.app", systemCaches: system, managedCaches: managed)
        #expect(try Data(contentsOf: archive) == Data("archive".utf8))
        try fm.removeItem(at: source)
        try fm.createSymbolicLink(at: source, withDestinationURL: root)
        #expect(throws: UpdateFailure.self) {
            try UpdateTransactionStore.prepareDownloadDirectory(bundleID: "com.muses.app", systemCaches: system, managedCaches: managed)
        }
        try fm.removeItem(at: source)
        let active = source.appending(path: "org.sparkle-project.Sparkle/Installation/active")
        try fm.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("installer".utf8).write(to: active)
        #expect(throws: UpdateFailure.self) {
            try UpdateTransactionStore.prepareDownloadDirectory(bundleID: "com.muses.app", systemCaches: system, managedCaches: managed)
        }
        #expect(fm.fileExists(atPath: active.path))
    }

    @Test("Unconfigured builds cannot start the production updater")
    func missingConfiguration() {
        let service = UpdateService(defaults: defaults())
        #expect(!service.isConfigured)
        #expect(!service.canCheck)
    }
    @Test("Production config requires HTTPS and signed feeds; only explicit acceptance permits loopback")
    func configurationValidation() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        var info: [String: Any] = [
            "SUFeedURL": UpdateConfiguration.productionFeed, "SUPublicEDKey": key,
            "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true
        ]
        #expect(UpdateConfiguration.validationError(info: info, isApplication: true, bundleID: "com.muses.app") == nil)
        #expect(UpdateConfiguration.validationError(info: info, isApplication: true, bundleID: "com.muses.acceptance.updates") != nil)
        info["SUFeedURL"] = "http://127.0.0.1:18765/appcast.xml"
        info["MusesUpdateAcceptanceLoopback"] = true
        #expect(UpdateConfiguration.validationError(info: info, isApplication: true, bundleID: "com.muses.app") != nil)
        #expect(UpdateConfiguration.validationError(info: info, isApplication: true, bundleID: "com.muses.acceptance.updates") == nil)
        info["SURequireSignedFeed"] = false
        #expect(UpdateConfiguration.validationError(info: info, isApplication: true, bundleID: "com.muses.acceptance.updates") != nil)
    }

    @Test("Check availability refreshes after Sparkle finishes even when the visible phase is unchanged")
    func checkAvailabilityObservation() {
        let engine = FakeUpdateEngine()
        let service = service(defaults(), engine: engine)
        service.startAfterSuccessfulLaunch(build: "1", persistentStoreReady: true)
        #expect(service.canCheck)
        engine.onEvent?(.canCheckChanged(false))
        #expect(!service.canCheck)
        service.receive(.notFound(""))
        #expect(!service.canCheck)
        engine.onEvent?(.canCheckChanged(true))
        #expect(service.canCheck)
    }

    @Test("A repeated presentation of the same update preserves Later and relaunch needs installation intent")
    func repeatedPresentationPreservesDeferral() {
        let engine = FakeUpdateEngine()
        let service = service(defaults(), engine: engine)
        service.setAutomaticallyInstalls(true)
        service.receive(.found(item))
        service.receive(.ready)
        #expect(engine.permitsRelaunch?() == false)
        service.deferRestart()
        service.receive(.checking)
        service.receive(.found(item))
        service.receive(.ready)
        for _ in 0..<20 { service.advanceAutomaticRestart() }
        service.installNow(automatically: true)
        #expect(engine.installs == 0)
        #expect(engine.permitsRelaunch?() == false)
        service.installNow()
        #expect(engine.installs == 1)
        #expect(engine.permitsRelaunch?() == true)
    }

}
