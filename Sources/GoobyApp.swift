import SwiftUI

@main
struct GoobyApp: App {
    @NSApplicationDelegateAdaptor(GoobyApplicationDelegate.self) private var appDelegate

    // No WindowGroup: the app delegate owns the companion panel.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
