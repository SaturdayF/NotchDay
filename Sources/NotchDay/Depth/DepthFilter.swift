import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The built-in display, or `nil` when only external displays are
    /// attached.
    static var builtIn: NSScreen? {
        screens.first { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
}

/// Excludes this process to keep the overlay out of its own capture.
@MainActor
enum DepthFilter {

    struct Key: Equatable {
        let displayID: CGDirectDisplayID
    }

    static func make(for key: Key) async -> SCContentFilter? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == key.displayID }) else {
                return nil
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let ownApplications = content.applications.filter { $0.processID == pid }
            guard !ownApplications.isEmpty else { return nil }
            // Keep ordinary NotchDay windows such as Settings in the desktop
            // picture. The island and overlay have their own rendering paths.
            let ownWindows = Set(NSApp.windows.compactMap { window -> CGWindowID? in
                guard window.isVisible, window.windowNumber > 0,
                      window.level == .normal,
                      window.styleMask.contains(.titled) else { return nil }
                return CGWindowID(window.windowNumber)
            })
            let excepting = content.windows.filter { ownWindows.contains($0.windowID) }
            return SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: excepting
            )
        } catch {
            DepthLog.capture.error("shareable content failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
