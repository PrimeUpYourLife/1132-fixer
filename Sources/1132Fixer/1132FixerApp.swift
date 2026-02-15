import SwiftUI
import AppKit

@main
struct Fixer1132App: App {
    init() {
        // SwiftPM executables are not app bundles and have no main bundle ID.
        // Disable automatic tabbing so AppKit does not try to index tabs by bundle identifier.
        NSWindow.allowsAutomaticWindowTabbing = false

        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowStyle(.hiddenTitleBar)
    }
}
