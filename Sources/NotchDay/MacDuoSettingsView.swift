import AppKit
import CoreGraphics
import SwiftUI

/// The Mac Duo section of the settings window.
///
/// Same layout language as `NotchSettingsView`: a stack of labelled rows
/// separated by dividers, with the values spelled out next to their sliders.
struct MacDuoSettingsView: View {
    @ObservedObject var preferences: DepthPreferences
    @ObservedObject var controller: DepthController

    private var hasScreenPermission: Bool { controller.hasScreenPermission }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider()

            // The sliders and their help text come to more than a screen
            // height, so the middle scrolls and the header and footer stay put.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if controller.isSensorAvailable {
                        status
                        Divider()
                        switches
                        Divider()
                        startGroup
                        Divider()
                        lookGroup
                        Divider()
                        perspectiveGroup
                    } else {
                        unavailable
                    }
                }
                .padding(22)
            }
            .frame(height: 452)

            Divider()

            footer
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .frame(width: 396)
        .onAppear { controller.refreshScreenPermission() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Mac Duo")
                .font(.title2.bold())
            Spacer()
            Text(String(format: "%.1f°", controller.currentAngle))
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("铰链角度")
        }
    }

    private var unavailable: some View {
        Text("这台 Mac 没有铰链角度传感器，景深效果不可用。只有部分 MacBook 机型带这个传感器。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("屏幕录制", systemImage: "rectangle.dashed.badge.record")
                Spacer()
                if hasScreenPermission {
                    Text("已授权")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Button("授权…", action: requestPermission)
                }
            }
            if !hasScreenPermission {
                Text("景深效果要读取屏幕内容才能把它画出来。如果系统要求，请重新打开 NotchDay。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Label("当前状态", systemImage: "laptopcomputer")
                Spacer()
                Text(controller.isActive ? "正在播放" : "待机")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleRow(
                "景深效果",
                isOn: $preferences.isEnabled,
                help: "合盖时把屏幕内容按透视推远、模糊并压暗。"
            )
            toggleRow(
                "实时渲染",
                isOn: $preferences.isLivePicture,
                help: "关闭后固定使用触发瞬间的那一帧画面。"
            )
            .disabled(!preferences.isEnabled)
        }
    }

    private var startGroup: some View {
        group("触发") {
            toggleRow(
                "静止后结束",
                isOn: $preferences.isTimeoutEnabled,
                help: "角度不再变化时提前结束效果，不必等盖子重新抬起。"
            )
            sliderRow(
                "起始角度", value: $preferences.thresholdAngle, in: 5...130, format: "%.0f°",
                help: "合盖到这个角度开始出现效果。"
            )
            sliderRow(
                "满效果角度", value: $preferences.blurSpan, in: 5...60, format: "%.0f°",
                help: "再合上这么多度，模糊与压暗达到最强。"
            )
        }
    }

    private var lookGroup: some View {
        group("观感") {
            sliderRow(
                "模糊", value: $preferences.maxBlurRadius, in: 10...160, format: "%.0f pt",
                help: "远端的模糊半径。"
            )
            sliderRow(
                "模糊扩散", value: $preferences.blurEvenness, in: 0...1, format: "%.0f%%", scale: 100,
                help: "0 只模糊远端，100 整幅画面一起模糊。"
            )
            sliderRow(
                "压暗", value: $preferences.maxDim, in: 0...1, format: "%.0f%%", scale: 100,
                help: "远端压到多黑。"
            )
            sliderRow(
                "压暗扩散", value: $preferences.dimReach, in: 0.2...1, format: "%.0f%%", scale: 100,
                help: "高于这个高度的地方完全变黑。"
            )
        }
    }

    private var perspectiveGroup: some View {
        group("透视") {
            sliderRow(
                "后仰倍数", value: $preferences.recession, in: 0...3, format: "%.1f×",
                help: "每合上一度，画面相对玻璃再后仰多少度。1 表示画面在房间里保持不动。"
            )
            sliderRow(
                "透视强度", value: perspective, in: 0...1, format: "%.0f%%", scale: 100,
                help: "0 保持两侧平行，100 收束最强。"
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("预览效果") {
                    controller.runPreview()
                }
                .disabled(!controller.isSensorAvailable || !hasScreenPermission || !preferences.isEnabled)
                Spacer()
                Button("恢复默认") { preferences.resetToDefaults() }
                Button("退出 NotchDay", role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
            Text("效果只作用于内置屏。点击会穿透到下方的 App，画面与可点区域并不一致。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var perspective: Binding<Double> {
        Binding(
            get: { (DepthPreferences.farthestEye - preferences.viewingDistance) / DepthPreferences.eyeRange },
            set: { preferences.viewingDistance = DepthPreferences.farthestEye - $0 * DepthPreferences.eyeRange }
        )
    }

    private func requestPermission() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        controller.refreshScreenPermission()
        if !hasScreenPermission {
            SystemLinks.openScreenRecordingPrivacy()
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .disabled(!preferences.isEnabled)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel(title)
            }
            Text(help)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String,
        scale: Double = 1,
        help: String
    ) -> some View {
        let reading = String(format: format, value.wrappedValue * scale)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(reading)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(reading)
            Text(help)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
