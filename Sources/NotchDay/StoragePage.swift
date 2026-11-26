import AppKit
import SwiftUI

struct StoragePage: View {
    let feed: StorageFeed
    let tint: Color

    @State private var hoverIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            statRow
            chartSection
            axisRow
            rangePills
        }
        .onChange(of: feed.range) { hoverIndex = nil }
        .onChange(of: feed.series.count) { hoverIndex = nil }
    }

    private var header: some View {
        Button(action: SystemLinks.openStorageSettings) {
            HStack(spacing: 9) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(tint)
                Text("储存空间")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.57))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开系统的储存空间设置")
        .help("在系统设置中打开储存空间")
    }

    private var statRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(gigabytes(feed.snapshot?.used ?? 0, decimals: 1))
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("已用 / \(gigabytes(feed.snapshot?.total ?? 0, decimals: 0))")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 8)
            deltaLabel
        }
    }

    @ViewBuilder
    private var deltaLabel: some View {
        if let delta = delta {
            Text(feed.range.deltaTitle)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Text(String(format: "%@%.1f GB", delta >= 0 ? "+" : "−", abs(delta)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var delta: Double? {
        guard let first = feed.series.first, let last = feed.series.last, feed.series.count >= 2 else { return nil }
        return Double(last.used - first.used) / 1_000_000_000
    }

    private var window: (start: Date, end: Date) {
        let end = Date()
        let span = feed.range.span ?? max(86_400, feed.series.last?.date.timeIntervalSince(feed.series.first?.date ?? end) ?? 0)
        return (end.addingTimeInterval(-span), end)
    }

    private var chartSection: some View {
        Group {
            if feed.hasTrend {
                let window = window
                StorageChart(
                    points: feed.series,
                    start: window.start,
                    end: window.end,
                    tint: tint,
                    hoverIndex: $hoverIndex
                )
            } else {
                Text(feed.snapshot == nil ? "无法读取容量。" : "数据积累中，每小时记录一次。")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, StorageChart.gutter)
            }
        }
        .frame(height: StorageChart.plotHeight, alignment: .leading)
        .padding(.top, 6)
    }

    private var axisRow: some View {
        HStack {
            Text(axisLabel(window.start))
            Spacer()
            Text(axisLabel(midDate))
            Spacer()
            Text("现在")
        }
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.leading, StorageChart.gutter)
        .padding(.top, 3)
        .accessibilityHidden(true)
    }

    private var midDate: Date {
        let window = window
        return window.start.addingTimeInterval(window.end.timeIntervalSince(window.start) / 2)
    }

    private func axisLabel(_ date: Date) -> String {
        let day = StorageFormat.day.string(from: date)
        guard feed.range == .day else { return day }
        return day + " " + StorageFormat.time.string(from: date)
    }

    private var rangePills: some View {
        HStack(spacing: 4) {
            ForEach(StorageRange.allCases) { range in
                let selected = feed.range == range
                let enabled = feed.isAvailable(range)
                Button { feed.select(range) } label: {
                    Text(range.title)
                        .font(.system(size: 10))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(
                            .white.opacity(selected ? 0.18 : enabled ? 0.06 : 0.03),
                            in: .capsule
                        )
                        .foregroundStyle(.white.opacity(selected ? 1 : enabled ? 0.55 : 0.24))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(enabled ? range.title : "记录不足，暂不可选")
            }
        }
        .padding(.top, 8)
    }

    private func gigabytes(_ bytes: Int64, decimals: Int) -> String {
        String(format: "%.\(decimals)f GB", Double(bytes) / 1_000_000_000)
    }
}

private struct StorageChart: View {
    static let gutter: CGFloat = 34
    static let plotHeight: CGFloat = 54

    let points: [StoragePoint]
    let start: Date
    let end: Date
    let tint: Color
    @Binding var hoverIndex: Int?

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: Self.gutter, y: 0,
                width: max(1, geometry.size.width - Self.gutter), height: Self.plotHeight
            )
            let bounds = Self.bounds(points)
            let coords = points.map { point in
                CGPoint(
                    x: x(for: point.date, in: plot),
                    y: y(for: Double(point.used) / 1_000_000_000, in: plot, bounds: bounds)
                )
            }

            ZStack(alignment: .topLeading) {
                grid(plot: plot)
                area(coords, plot: plot)
                line(coords)
                if let index = hoverIndex, coords.indices.contains(index) {
                    cursor(coords[index], height: plot.height)
                    dot(coords[index])
                    tooltip(coords[index], storage: points[index], width: geometry.size.width)
                }
                ticks(bounds: bounds, plot: plot)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hoverIndex = nearest(to: location.x, coords: coords)
                case .ended:
                    hoverIndex = nil
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("储存空间趋势")
        .accessibilityValue(chartSummary)
    }

    private var chartSummary: String {
        guard let first = points.first, let last = points.last else { return "暂无记录" }
        let low = Double(points.map(\.used).min() ?? 0) / 1_000_000_000
        let high = Double(points.map(\.used).max() ?? 0) / 1_000_000_000
        return String(
            format: "%d 个记录点，从 %.1f GB 到 %.1f GB，最低 %.1f GB，最高 %.1f GB",
            points.count, Double(first.used) / 1_000_000_000, Double(last.used) / 1_000_000_000, low, high
        )
    }

    private func x(for date: Date, in plot: CGRect) -> CGFloat {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return plot.maxX }
        let ratio = date.timeIntervalSince(start) / span
        return plot.minX + plot.width * CGFloat(min(max(ratio, 0), 1))
    }

    private func y(for value: Double, in plot: CGRect, bounds: (lo: Double, mid: Double, hi: Double)) -> CGFloat {
        let span = bounds.hi - bounds.lo
        guard span > 0 else { return plot.midY }
        let ratio = (value - bounds.lo) / span
        let raw = plot.maxY - plot.height * CGFloat(ratio)
        return min(max(raw, plot.minY), plot.maxY)
    }

    private func grid(plot: CGRect) -> some View {
        Path { path in
            for step in 0...2 {
                let y = plot.minY + plot.height * CGFloat(step) / 2
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.07), lineWidth: 1)
    }

    private func area(_ coords: [CGPoint], plot: CGRect) -> some View {
        curve(coords, closeTo: plot.maxY)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.22), tint.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                )
            )
    }

    private func line(_ coords: [CGPoint]) -> some View {
        curve(coords, closeTo: nil)
            .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }

    private func curve(_ coords: [CGPoint], closeTo bottom: CGFloat?) -> Path {
        var path = Path()
        guard let first = coords.first else { return path }
        path.move(to: first)
        if coords.count > 2 {
            for index in 0..<(coords.count - 1) {
                let previous = index > 0 ? coords[index - 1] : coords[index]
                let current = coords[index]
                let next = coords[index + 1]
                let following = index + 2 < coords.count ? coords[index + 2] : next
                let control1 = CGPoint(
                    x: current.x + (next.x - previous.x) / 6,
                    y: current.y + (next.y - previous.y) / 6
                )
                let control2 = CGPoint(
                    x: next.x - (following.x - current.x) / 6,
                    y: next.y - (following.y - current.y) / 6
                )
                path.addCurve(to: next, control1: control1, control2: control2)
            }
        } else {
            for point in coords.dropFirst() { path.addLine(to: point) }
        }
        if let bottom, let last = coords.last {
            path.addLine(to: CGPoint(x: last.x, y: bottom))
            path.addLine(to: CGPoint(x: first.x, y: bottom))
            path.closeSubpath()
        }
        return path
    }

    private func cursor(_ point: CGPoint, height: CGFloat) -> some View {
        Rectangle()
            .fill(.white.opacity(0.22))
            .frame(width: 1, height: height)
            .offset(x: point.x, y: 0)
    }

    private func dot(_ point: CGPoint) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(tint, lineWidth: 1.5))
            .offset(x: point.x - 3.5, y: point.y - 3.5)
    }

    private func tooltip(_ position: CGPoint, storage: StoragePoint, width: CGFloat) -> some View {
        Text(label(for: storage) + " · " + String(format: "%.1f GB", Double(storage.used) / 1_000_000_000))
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(.white.opacity(0.18), in: .rect(cornerRadius: 5))
            .fixedSize()
            .position(x: min(max(position.x, 72), width - 72), y: 9)
    }

    private func label(for point: StoragePoint) -> String {
        let day = StorageFormat.day.string(from: point.date)
        if point.bucketDays == 0 {
            return day + " " + StorageFormat.time.string(from: point.date)
        }
        guard point.bucketDays > 1 else { return day }
        let start = point.date.addingTimeInterval(-Double(point.bucketDays - 1) * 86_400)
        return StorageFormat.day.string(from: start) + "–" + StorageFormat.dayOnly.string(from: point.date)
    }

    private func ticks(bounds: (lo: Double, mid: Double, hi: Double), plot: CGRect) -> some View {
        ForEach(0...2, id: \.self) { index in
            let value = index == 0 ? bounds.hi : index == 1 ? bounds.mid : bounds.lo
            let y = plot.minY + plot.height * CGFloat(index) / 2
            Text(Self.tickText(value))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: Self.gutter - 8, alignment: .trailing)
                .offset(x: 0, y: y - 6)
        }
    }

    private func nearest(to x: CGFloat, coords: [CGPoint]) -> Int? {
        guard !coords.isEmpty else { return nil }
        var best = 0
        var distance = CGFloat.greatestFiniteMagnitude
        for (index, point) in coords.enumerated() {
            let current = abs(point.x - x)
            if current < distance {
                distance = current
                best = index
            }
        }
        return best
    }

    static func tickText(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// 三条刻度：取当前区间的最小/最大值向外取整，不从 0 起，避免曲线被压平。
    static func bounds(_ points: [StoragePoint]) -> (lo: Double, mid: Double, hi: Double) {
        let values = points.map { Double($0.used) / 1_000_000_000 }
        var low = values.min() ?? 0
        var high = values.max() ?? 1
        if high - low < 0.2 {
            low -= 0.5
            high += 0.5
        }
        let step = niceStep((high - low) / 2)
        let bottom = (low / step).rounded(.down) * step
        var top = (high / step).rounded(.up) * step
        if top <= bottom { top = bottom + step }
        return (bottom, (bottom + top) / 2, top)
    }

    private static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let exponent = (log10(raw)).rounded(.down)
        let scale = pow(10, exponent)
        let fraction = raw / scale
        let nice: Double
        switch fraction {
        case ...1: nice = 1
        case ...2: nice = 2
        case ...2.5: nice = 2.5
        case ...5: nice = 5
        default: nice = 10
        }
        return nice * scale
    }
}

private enum StorageFormat {
    static let day = formatter("M月d日")
    static let dayOnly = formatter("d日")
    static let time = formatter("HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter
    }
}
