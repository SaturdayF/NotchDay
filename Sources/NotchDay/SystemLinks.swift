import AppKit

@MainActor
enum SystemLinks {
    static func openMusic() { openApp("com.apple.Music") }
    static func openCalendar() { openApp("com.apple.iCal") }
    static func openReminders() { openApp("com.apple.reminders") }

    static func openRemindersPrivacy() {
        openSettings("com.apple.settings.PrivacySecurity.extension?Privacy_Reminders")
    }

    static func openAutomationPrivacy() {
        openSettings("com.apple.settings.PrivacySecurity.extension?Privacy_Automation")
    }

    static func openFullDiskAccess() {
        openSettings("com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
    }

    static func openScreenRecordingPrivacy() {
        openSettings("com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
    }

    static func openSoundOutput() {
        openSettings("com.apple.Sound-Settings.extension")
    }

    static func openStorageSettings() {
        openSettings("com.apple.settings.Storage")
    }

    static func openStorageLogFolder() {
        StorageLog.prepare()
        if !NSWorkspace.shared.open(StorageLog.directory) {
            NSWorkspace.shared.activateFileViewerSelecting([StorageLog.directory])
        }
    }

    private static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane), NSWorkspace.shared.open(url) { return }
        openApp("com.apple.systempreferences")
    }

    static func openCalendarEvent(_ event: AgendaEvent) {
        guard let url = event.calendarURL, NSWorkspace.shared.open(url) else {
            openCalendar()
            return
        }
    }

    static func openScreenTime() {
        let root = "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension"
        if let url = URL(string: root + "?path=app-usage"), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: root), NSWorkspace.shared.open(url) { return }
        openApp("com.apple.systempreferences")
    }

    static func openCalendarPrivacy() {
        let address = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars"
        if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        openApp("com.apple.systempreferences")
    }

    static func openApp(_ bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
