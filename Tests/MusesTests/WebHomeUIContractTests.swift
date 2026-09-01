import Foundation
import Testing
@testable import Muses

@Suite("Web Home UI and release guardrails")
struct WebHomeUIContractTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MusesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
    }

    @Test("user Web Home preference is registered off with no consent")
    @MainActor
    func defaultOffPreference() {
        #expect(WebHomePreferenceDefaults.values[PrefKey.webHomeEnabled] as? Bool == false)
        #expect(WebHomePreferenceDefaults.values[PrefKey.webHomeConsentVersion] as? Int == 0)
        #expect(WebHomePreferenceDefaults.values[
            PrefKey.webHomeDefaultBrowserConsent] as? Bool == false)
        #expect(WebHomePreferenceDefaults.values[
            PrefKey.webHomeBrowserSource] as? String == "")
    }

    @Test("settings exposes dedicated consent, recovery, and scoped deletion actions")
    func settingsContract() throws {
        let source = try read("Sources/Muses/Features/Settings/YouTubeSettingsView.swift")

        // Normal mode: the one-tap state machine and independent confirmation
        #expect(source.contains("Connect YouTube"))
        #expect(source.contains("Turn On Personalized Home"))
        #expect(source.contains("Check Session"))
        #expect(source.contains("connectAndPersonalize"))
        #expect(source.contains("showWebHomeConsent"))
        #expect(source.contains("prepareDefaultBrowserConsent"))
        #expect(source.contains("enableUsingDefaultBrowser"))
        #expect(source.contains("Ready to check"))

        // Technical detail is folded into "Advanced" instead of being sprawled across the main UI
        #expect(source.contains("PrefKey.ytShowAdvanced"))
        #expect(source.contains("DisclosureGroup"))

        // The removal management actions and recovery entry points must still exist
        #expect(source.contains("Could not read browser session"))
        #expect(!source.contains("Cookie source offered"))
        #expect(source.contains("Disable & Clear Temporary Session"))
        #expect(source.contains("clearSavedWebHomeForCurrentAccount"))
        #expect(source.contains("Open YouTube Music"))
        #expect(source.contains("YouTube's terms"))

        // Playback cookie independence copy
        #expect(source.contains("never changes this selection"))
    }

    @Test("settings sheet gates the yt-dlp wizard behind the advanced toggle")
    func settingsSheetWizardContract() throws {
        let sheet = try read("Sources/Muses/Features/Settings/SettingsSheet.swift")
        #expect(sheet.contains("PrefKey.ytShowAdvanced"))
        #expect(sheet.contains("showYtAdvanced"))
        #expect(sheet.contains("if showYtAdvanced"))
    }

    @Test("Home identifies live and saved sources and labels continuation for VoiceOver")
    func homeContract() throws {
        let source = try read("Sources/Muses/Features/HomeView+Sections.swift")

        #expect(source.contains("YouTube Music personalized"))
        #expect(source.contains("Saved YouTube Music personalized"))
        #expect(source.contains("Personalized Web Home is unavailable"))
        #expect(source.contains("fetchContinuation"))
        #expect(source.contains(".accessibilityLabel"))
        #expect(source.contains("Load more"))
    }

    @Test("build kill switch omits the enhancement provider")
    func buildKillSwitchContract() throws {
        let source = try read("Sources/Muses/App/MusesApp.swift")
        #expect(source.contains("webHome.isBuildEnabled ? webHome : nil"))
    }

    @Test("Web code has no direct credential or payload logging sink")
    func redactedLoggingContract() throws {
        let relativePaths = [
            "Sources/Muses/Services/Discovery/WebHomeHelperClient.swift",
            "Sources/Muses/Services/Discovery/WebHomeSessionController.swift",
            "Sources/Muses/Services/Discovery/DefaultBrowserCookieSource.swift",
            "Sources/MusesWebHomeCore/WebHomeCookieJar.swift",
            "Sources/MusesWebHomeCore/WebHomeSessionClient.swift",
            "Sources/MusesWebHomeCore/WebHomePayloadParser.swift",
            "Sources/MusesWebHomeHelper/MusesWebHomeHelper.swift"
        ]
        for relativePath in relativePaths {
            let source = try read(relativePath)
            #expect(!source.contains("print("), "Unexpected print sink in \(relativePath)")
            #expect(!source.contains("debugPrint("), "Unexpected debug sink in \(relativePath)")
            #expect(!source.contains("AppLog.for"), "Unexpected app log sink in \(relativePath)")
            #expect(!source.contains("standardError.write"),
                    "Unexpected stderr write in \(relativePath)")
        }
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appending(path: relativePath),
            encoding: .utf8)
    }
}
