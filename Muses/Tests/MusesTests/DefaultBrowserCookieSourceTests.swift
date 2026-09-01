import Testing
@testable import Muses

@Suite("Default browser Web Home source")
@MainActor
struct DefaultBrowserCookieSourceTests {
    @Test("supported browser bundle identifiers map exactly", arguments: [
        ("com.apple.Safari", WebHomeBrowserSource.safari),
        ("com.google.Chrome", WebHomeBrowserSource.chrome),
        ("org.mozilla.firefox", WebHomeBrowserSource.firefox),
    ])
    func supportedBrowserMapping(
        bundleIdentifier: String,
        expectedSource: WebHomeBrowserSource
    ) {
        let resolution = DefaultBrowserCookieSourceDetector.resolution(
            bundleIdentifier: bundleIdentifier,
            applicationName: expectedSource.displayName)

        guard case .supported(let source, let applicationName, let identifier) = resolution else {
            Issue.record("Expected a supported browser")
            return
        }
        #expect(source == expectedSource)
        #expect(applicationName == expectedSource.displayName)
        #expect(identifier == bundleIdentifier)
    }

    @Test("Chromium derivatives are not silently treated as Chrome")
    func chromiumDerivativeIsUnsupported() {
        let resolution = DefaultBrowserCookieSourceDetector.resolution(
            bundleIdentifier: "company.thebrowser.Browser",
            applicationName: "Arc")

        #expect(resolution == .unsupported(
            applicationName: "Arc",
            bundleIdentifier: "company.thebrowser.Browser"))
    }

    @Test("missing bundle identity cannot become an approved source")
    func missingBundleIdentityIsUnavailable() {
        let resolution = DefaultBrowserCookieSourceDetector.resolution(
            bundleIdentifier: nil,
            applicationName: "Unknown")

        #expect(resolution == .unavailable)
    }
}
