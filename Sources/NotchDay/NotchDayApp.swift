import AppKit
import SwiftUI

@main
@MainActor
struct NotchDayApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = NotchAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class NotchAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NotchController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshCalendar()
    }
}
