import AppKit
import Sparkle

/// Updates in place with Sparkle: once a day it looks at the appcast on GitHub, and when there's a
/// newer build it asks, downloads, checks the EdDSA signature against the key in Info.plist, swaps
/// the app and relaunches. The signing certificate stays the same, so the Keychain keeps trusting it.
@MainActor @Observable
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    /// A newer version the last check found; the sidebar offers it.
    private(set) var available: String?
    private(set) var lastChecked: Date?
    /// Sparkle said this is the newest version, during this run.
    private(set) var confirmedLatest = false

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    #if DEBUG
    private var testUpdater: SPUUpdater?
    private let testDriver = TestDriver()
    #endif

    func start() {
        #if DEBUG
        // `-ClavraTestUpdate YES -SUFeedURL <appcast>` installs whatever the feed offers without
        // asking and relaunches, to try a whole update without publishing a release.
        if UserDefaults.standard.bool(forKey: "ClavraTestUpdate") {
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: testDriver, delegate: nil)
            testUpdater = updater
            try? updater.start()
            updater.checkForUpdates()
            return
        }
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        lastChecked = controller?.updater.lastUpdateCheckDate
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            available = version
            lastChecked = .now
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            available = nil
            confirmedLatest = true
            lastChecked = .now
        }
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}

#if DEBUG
/// Says yes to everything and reports each step on stdout, for scripts.
private final class TestDriver: NSObject, SPUUserDriver {
    private func log(_ text: String) { print("CLAVRA_UPDATE \(text)"); fflush(stdout) }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { log("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log("found \(appcastItem.displayVersionString)")
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { log("none"); acknowledgement() }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { log("error \(error.localizedDescription)"); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { log("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { log("verifying") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { log("installing"); reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { log("relaunched"); acknowledgement() }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}
#endif
