import SwiftUI

struct MusicPage: View {
    @State private var seekPreview: Double?

    let model: NotchModel
    let seekingChanged: (Bool) -> Void
    let playbackChanged: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: headerAction) {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 52, height: 52)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.track.title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.60))
                            .lineLimit(1)
                    }
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.16), value: model.track.id)

                    Spacer(minLength: 4)
                    PlaybackPips(color: model.musicTint, active: updatesWhileVisible)
                        .opacity(model.isPlaying ? 1 : 0.45)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.track.title)，\(connected ? "打开音乐" : subtitle)")
            .help(connected ? "打开系统音乐" : subtitle)

            TimelineView(.periodic(from: .now, by: 1).paused(if: !updatesWhileVisible)) { timeline in
                let seconds = seekPreview ?? model.playbackPosition(at: timeline.date)
                HStack(spacing: 9) {
                    timeLabel(seconds).frame(width: 30, alignment: .leading)
                    progressBar(position: seconds)
                        .allowsHitTesting(connected && model.track.duration > 0)
                    timeLabel(model.track.duration).frame(width: 30, alignment: .trailing)
                }
            }

            HStack(spacing: 0) {
                control("shuffle", label: "随机播放", active: model.music.isShuffled) {
                    model.music.send(.shuffle(!model.music.isShuffled))
                }
                control("backward.fill", label: "上一首") { model.changeTrack(by: -1) }
                control(model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "暂停" : "播放", size: 19, needsConnection: false) {
                    guard connected else { model.music.connectionAction(); return }
                    model.togglePlayback()
                    playbackChanged()
                }
                control("forward.fill", label: "下一首") { model.changeTrack(by: 1) }
                control("airplay.audio", label: "打开声音输出设置", needsConnection: false, action: SystemLinks.openSoundOutput)
            }
        }
        .onChange(of: visible, initial: true) { _, isVisible in model.music.setVisible(isVisible) }
        .onDisappear {
            model.music.setVisible(false)
            if seekPreview != nil { seekingChanged(false) }
        }
    }

    private var connected: Bool { model.music.connection == .connected }
    private var visible: Bool { model.mode == .expanded && model.page == .music }

    private var updatesWhileVisible: Bool {
        visible && model.isPlaying
    }

    private var subtitle: String {
        switch model.music.connection {
        case .closed: "打开「音乐」开始播放"
        case .needsPermission: "连接 Apple Music"
        case .denied: "在系统设置中允许自动化"
        case .unavailable: "音乐连接暂不可用，点击重试"
        case .connected: model.track.artist.isEmpty ? "打开系统音乐" : model.track.artist
        }
    }

    private func headerAction() {
        if connected { SystemLinks.openMusic() }
        else { model.music.connectionAction() }
    }

    private func timeLabel(_ seconds: Double) -> some View {
        Text(Self.formatted(seconds))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.64))
            .accessibilityHidden(true)
    }

    private func progressBar(position: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = model.track.duration > 0 ? min(1, max(0, position / model.track.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 3)
                Capsule().fill(.white.opacity(0.94)).frame(width: width * progress, height: 3)
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { event in
                        if seekPreview == nil { seekingChanged(true) }
                        seekPreview = positionForDrag(x: event.location.x, width: width)
                    }
                    .onEnded { event in
                        model.seek(to: positionForDrag(x: event.location.x, width: width))
                        seekPreview = nil
                        seekingChanged(false)
                    }
            )
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue(Self.formatted(position))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.seek(to: position + 5)
            case .decrement: model.seek(to: position - 5)
            @unknown default: break
            }
        }
    }

    private func positionForDrag(x: CGFloat, width: CGFloat) -> Double {
        min(1, max(0, x / max(1, width))) * model.track.duration
    }

    private func control(
        _ symbol: String, label: String, active: Bool = false, size: CGFloat = 14, needsConnection: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? model.musicTint : Color.white)
                .frame(width: 37, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchControlStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
        .help(label)
        .disabled(needsConnection && !connected)
    }

    private static func formatted(_ time: Double) -> String {
        let seconds = Int(max(0, time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct NotchControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.59 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

private extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    func paused(if paused: Bool) -> some TimelineSchedule {
        PreviewSchedule(schedule: self, paused: paused)
    }
}

private struct PreviewSchedule: TimelineSchedule {
    let schedule: PeriodicTimelineSchedule
    let paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> some Sequence<Date> {
        // Always render one snapshot so manual seeks and pause update the display.
        if paused {
            return AnySequence([startDate])
        }
        return AnySequence(schedule.entries(from: startDate, mode: mode))
    }
}
