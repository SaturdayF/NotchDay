import AppKit
import Observation
import SwiftUI

/// The two halves of the settings window.
enum SettingsSection: Int, CaseIterable, Identifiable {
    case notch
    case depth

    var id: Self { self }

    var title: String {
        switch self {
        case .notch: "NotchDay"
        case .depth: "Mac Duo"
        }
    }
}

@MainActor
@Observable
final class SettingsState {
    var section: SettingsSection = .notch
}

/// One settings window with tabs for NotchDay and Mac Duo.
@MainActor
final class SettingsWindowController {

    private let state = SettingsState()
    private let calendar: CalendarFeed
    private let model: NotchModel
    private let toggleLockPreview: () -> Void
    private let depthPreferences: DepthPreferences
    private let depthController: DepthController
    private var window: NSWindow?

    init(
        calendar: CalendarFeed,
        model: NotchModel,
        toggleLockPreview: @escaping () -> Void,
        depthPreferences: DepthPreferences,
        depthController: DepthController
    ) {
        self.calendar = calendar
        self.model = model
        self.toggleLockPreview = toggleLockPreview
        self.depthPreferences = depthPreferences
        self.depthController = depthController
    }

    func show(_ section: SettingsSection) {
        state.section = section
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // An accessory app is not always granted activation, and the window
        // would then open behind whatever is in front.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsRootView(
            state: state,
            calendar: calendar,
            model: model,
            toggleLockPreview: toggleLockPreview,
            depthPreferences: depthPreferences,
            depthController: depthController
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "NotchDay 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

struct SettingsRootView: View {
    @Bindable var state: SettingsState
    let calendar: CalendarFeed
    let model: NotchModel
    let toggleLockPreview: () -> Void
    let depthPreferences: DepthPreferences
    let depthController: DepthController

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置分区", selection: $state.section) {
                ForEach(SettingsSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 2)

            switch state.section {
            case .notch:
                NotchSettingsView(
                    calendar: calendar,
                    model: model,
                    toggleLockPreview: toggleLockPreview
                )
            case .depth:
                MacDuoSettingsView(
                    preferences: depthPreferences,
                    controller: depthController
                )
            }
        }
        .frame(width: 396)
        // Without this the stack reports an unbounded ideal height, and the
        // window created from it grows to the whole screen.
        .fixedSize(horizontal: false, vertical: true)
    }
}
