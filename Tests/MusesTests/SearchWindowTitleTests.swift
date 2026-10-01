import Testing
@testable import Muses

@Suite("Integrated search navigation")
struct IntegratedSearchNavigationTests {
    @Test("Search participates in collection and settings navigation without losing its return route")
    func searchReturnRoute() {
        var history = BrowseNavigationHistory()
        history.visit(.section(.search))
        history.visit(.section(.songs))
        #expect(history.back() == .section(.search))
        #expect(history.back() == .section(.home))
        #expect(history.forward() == .section(.search))
        history.visit(.settings(SettingsCategory.general.rawValue, []))
        #expect(history.back() == .section(.search))
    }
}
