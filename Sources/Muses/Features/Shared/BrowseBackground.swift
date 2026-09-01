import SwiftUI

private struct BrowseGradientKey: EnvironmentKey {
    static let defaultValue: [Color] = [Color.black, BrandColors.background]
}

extension EnvironmentValues {
    var browseGradient: [Color] {
        get { self[BrowseGradientKey.self] }
        set { self[BrowseGradientKey.self] = newValue }
    }
}

struct BrowseBackground: View {
    @Environment(\.browseGradient) private var colors

    var body: some View {
        BrandColors.background.ignoresSafeArea()
    }
}
