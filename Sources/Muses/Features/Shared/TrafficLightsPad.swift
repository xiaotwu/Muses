import SwiftUI
import AppKit

/// Sidebar glass meets the window on three sides and rounds only toward content.
enum SidebarPaneShape {
    static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: AppleMusicTokens.sidebarCorner,
            topTrailingRadius: AppleMusicTokens.sidebarCorner,
            style: .continuous
        )
    }
}

/// Transparent layout clearance beneath AppKit's native traffic lights.
///
/// The standard close, minimize, and zoom buttons remain owned and positioned
/// by `NSWindow`; this view never hosts or moves them.
struct TrafficLightsPad: View {
    var body: some View {
        Color.clear
            .frame(
                width: WindowChromeMetrics.trafficLightClearanceWidth,
                height: WindowChromeMetrics.trafficLightClearanceHeight
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The one narrow AppKit boundary used to configure the SwiftUI main window.
struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowConfigurationView {
        MainWindowConfigurationView()
    }

    func updateNSView(_ nsView: MainWindowConfigurationView, context: Context) {
        guard let window = nsView.window else { return }
        MusesSingleInstance.configureMainWindow(window)
    }
}

final class MainWindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        MusesSingleInstance.configureMainWindow(window)
    }
}
