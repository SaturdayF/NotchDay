import AppKit
import SwiftUI

@main
struct NotchDayApp {
    static func main() {
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

/// `NSApplicationMain` instantiates the application from `NSPrincipalClass`,
/// which is why the delegate is installed here instead of in `main`.
@objc(NotchApplication)
final class NotchApplication: NSApplication {
    /// `NSApplication.delegate` does not keep its delegate alive.
    private lazy var appDelegate = NotchAppDelegate()

    override init() {
        super.init()
        delegate = appDelegate
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = appDelegate
    }
}

@MainActor
private final class NotchAppDelegate: NSObject, NSApplicationDelegate {
    private lazy var controller = NotchController()
    private let depthPreferences = DepthPreferences.shared
    private lazy var depth = DepthController(preferences: depthPreferences)
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsWindowController(
            calendar: controller.calendar,
            model: controller.model,
            toggleLockPreview: { [weak self] in self?.controller.toggleLockPreview() },
            depthPreferences: depthPreferences,
            depthController: depth
        )
        self.settings = settings
        controller.settingsPresenter = { [weak settings] section in settings?.show(section) }

        depth.captureIsland = { [weak self] screen in self?.controller.captureDepthIsland(on: screen) }
        depth.onIslandComposited = { [weak self] in self?.controller.setDepthIslandComposited($0) }
        controller.depthSessionLockChanged = { [weak self] in self?.depth.setSessionLocked($0) }

        controller.start()
        depth.start()

        // Lets a script play the effect without closing the lid, which is the
        // only way to check it on a machine no test can reach the hinge of.
        if CommandLine.arguments.contains("--settings") {
            settings.show(.depth)
        }
        let openingPreview = CommandLine.arguments.contains("--depth-opening-preview")
        if openingPreview || CommandLine.arguments.contains("--depth-preview") {
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                depth.runPreview(opening: openingPreview)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        depth.stop()
        controller.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshCalendar()
        depth.refreshScreenPermission()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        settings?.show(.notch)
        return false
    }
}
