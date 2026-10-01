import Foundation
import Sparkle

/// Custom user driver keeps update progress inside Muses. All callbacks are on
/// the main actor. Sparkle remains responsible for archive and code validation.
@MainActor
final class SparkleUpdateEngine: NSObject, UpdateEngine, SPUUserDriver, SPUUpdaterDelegate {
    var onEvent: ((UpdateEvent) -> Void)?
    var permitsRelaunch: (() -> Bool)?
    private var updater: SPUUpdater!
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var readyChoice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var received: UInt64 = 0
    private var expected: UInt64 = 0
    private var automaticChecks = false
    private var checkObservation: NSKeyValueObservation?
    private let hostBundle: Bundle

    init(bundle: Bundle) {
        hostBundle = bundle
        super.init()
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
    }

    var canCheck: Bool { updater.canCheckForUpdates }
    var canInstall: Bool { readyChoice != nil || retryTermination != nil }

    func start(automaticallyChecks: Bool) throws {
        if let id = hostBundle.bundleIdentifier {
            try UpdateTransactionStore.prepareDownloadDirectory(bundleID: id)
        }
        automaticChecks = automaticallyChecks
        updater.automaticallyChecksForUpdates = automaticallyChecks
        // Use this user driver for background downloads as well, so the same
        // persistence gate and countdown govern both manual and automatic installs.
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        updater.updateCheckInterval = 86_400
        updater.clearFeedURLFromUserDefaults()
        try updater.start()
        // Sparkle publishes canCheckForUpdates through KVO rather than Observation.
        // The public updater APIs and their changes run on the main thread.
        checkObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let available = change.newValue ?? false
            MainActor.assumeIsolated { self?.onEvent?(.canCheckChanged(available)) }
        }
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        automaticChecks = enabled
        updater.automaticallyChecksForUpdates = enabled
    }

    func check(userInitiated: Bool) {
        guard canCheck else { return }
        if userInitiated { updater.checkForUpdates() }
        else { updater.checkForUpdatesInBackground() }
    }

    func download() {
        let reply = choice
        choice = nil
        reply?(.install)
    }

    func install() {
        if let readyChoice {
            self.readyChoice = nil
            readyChoice(.install)
        } else {
            retryTermination?()
        }
    }

    func cancel() {
        let cancel = cancellation
        cancellation = nil
        cancel?()
    }

    func show(_ request: SPUUpdatePermissionRequest,
                                     reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticChecks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        onEvent?(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        let item = AvailableUpdate(version: appcastItem.displayVersionString,
                                   build: appcastItem.versionString,
                                   releaseURL: appcastItem.infoURL,
                                   informationOnly: appcastItem.isInformationOnlyUpdate)
        if state.stage == .installing {
            readyChoice = reply
            onEvent?(.found(item))
            onEvent?(.ready)
        } else {
            choice = reply
            onEvent?(.found(item))
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        onEvent?(.notFound(noUpdateMessage(error)))
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        onEvent?(.failed(error.localizedDescription))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        received = 0
        expected = 0
        onEvent?(.downloading)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received = received.addingReportingOverflow(length).partialValue
        onEvent?(.progress(expected == 0 ? nil : Double(received) / Double(expected)))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        onEvent?(.verifying)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyChoice = reply
        onEvent?(.ready)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        onEvent?(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        choice = nil
        readyChoice = nil
        cancellation = nil
        retryTermination = nil
        onEvent?(.dismissed)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        onEvent?(.checking)
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        permitsRelaunch?() == true
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue {
                onEvent?(.notFound(noUpdateMessage(error)))
            } else {
                onEvent?(.failed(error.localizedDescription))
            }
        }
    }

    private func noUpdateMessage(_ error: Error) -> String {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        if reason?.int32Value == SPUNoUpdateFoundReason.onLatestVersion.rawValue
            || reason?.int32Value == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue { return "" }
        return error.localizedDescription
    }
}
