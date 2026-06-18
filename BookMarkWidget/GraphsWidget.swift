import WidgetKit
import SwiftUI

struct GraphsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct GraphsProvider: TimelineProvider {
    func placeholder(in context: Context) -> GraphsEntry {
        GraphsEntry(date: Date(), snapshot: .preview)
    }
    func getSnapshot(in context: Context, completion: @escaping (GraphsEntry) -> Void) {
        completion(GraphsEntry(date: Date(), snapshot: WidgetSnapshotStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GraphsEntry>) -> Void) {
        let snap = WidgetSnapshotStore.load()
        let now = Date()
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        var entries: [GraphsEntry] = [GraphsEntry(date: now, snapshot: snap)]
        if let plus45 = cal.date(byAdding: .minute, value: 45, to: now) {
            entries.append(GraphsEntry(date: plus45, snapshot: snap))
        }
        entries.append(GraphsEntry(date: midnight, snapshot: snap))
        let ninetyOut = cal.date(byAdding: .minute, value: 90, to: now) ?? now
        let postMidnight = cal.date(byAdding: .minute, value: 1, to: midnight) ?? midnight
        let refresh = min(postMidnight, ninetyOut)
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

struct BookMarkGraphsWidget: Widget {
    let kind = "BookMarkGraphsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GraphsProvider()) { entry in
            GraphsWidgetView(entry: entry)
                .containerBackgroundCompat()
        }
        .configurationDisplayName("Reading Charts")
        .description("Last 7 days of reading minutes and pace.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct GraphsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GraphsEntry

    var body: some View {
        let s = entry.snapshot
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 8) {
            if family == .systemLarge {
                section(title: "READING TIME") {
                    BarChart7Day(
                        labels: s.last7DayLabels,
                        values: s.last7DaySeconds,
                        goalSeconds: s.goalMinutes * 60,
                        yAxisLabel: "",
                        xAxisLabel: ""
                    )
                    .frame(maxHeight: 122)
                }
                section(title: "READING PACE") {
                    PaceLine7Day(
                        labels: s.last7DayLabels,
                        values: s.last7DayPace,
                        yAxisLabel: "Pages/min",
                        xAxisLabel: ""
                    )
                    .frame(maxHeight: 116)
                }
            } else {
                section(title: "READING TIME") {
                    BarChart7Day(
                        labels: s.last7DayLabels,
                        values: s.last7DaySeconds,
                        goalSeconds: s.goalMinutes * 60,
                        yAxisLabel: "",
                        xAxisLabel: ""
                    )
                    .frame(maxHeight: 100)
                }
            }
        }
        .padding(family == .systemLarge ? 14 : 12)
    }

    private func section<C: View>(title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// Shared metrics so the Y-axis column / chart / X-axis name all stay aligned.
private enum AxisLayout {
    static let yLabelWidth: CGFloat = 10
    static let yTicksWidth: CGFloat = 32
    static let columnSpacing: CGFloat = 5
    static let plotHeight: CGFloat = 70
    static var leadingInset: CGFloat { yLabelWidth + columnSpacing + yTicksWidth + columnSpacing }
}

private struct VerticalAxisLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.secondary)
            .fixedSize()
            .rotationEffect(.degrees(-90))
    }
}

// MARK: - Tiny charts (no external deps so widget stays small)

struct BarChart7Day: View {
    let labels: [String]
    let values: [Int]   // seconds
    let goalSeconds: Int
    let yAxisLabel: String
    let xAxisLabel: String

    private var maxVal: Int {
        max(goalSeconds, values.max() ?? 0, 1)
    }

    private var maxMinutes: Int {
        max(1, Int(ceil(Double(maxVal) / 60.0)))
    }

    private var goalMinutes: Int {
        max(1, Int(ceil(Double(goalSeconds) / 60.0)))
    }

    private var leadingInset: CGFloat {
        (yAxisLabel.isEmpty ? 0 : AxisLayout.yLabelWidth + AxisLayout.columnSpacing)
            + AxisLayout.yTicksWidth
            + AxisLayout.columnSpacing
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: AxisLayout.columnSpacing) {
                if !yAxisLabel.isEmpty {
                    VerticalAxisLabel(text: yAxisLabel)
                        .frame(width: AxisLayout.yLabelWidth, height: AxisLayout.plotHeight, alignment: .center)
                }

                VStack(alignment: .trailing) {
                    Text("\(maxMinutes)m")
                    Spacer()
                    Text("\(goalMinutes)m goal")
                    Spacer()
                    Text("0")
                }
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: AxisLayout.yTicksWidth, alignment: .trailing)

                GeometryReader { geo in
                    let goalY = geo.size.height * (1 - CGFloat(goalSeconds) / CGFloat(maxVal))
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Divider().opacity(0.18)
                            Spacer()
                            Divider().opacity(0.18)
                            Spacer()
                            Divider().opacity(0.18)
                        }
                        HStack(alignment: .bottom, spacing: 6) {
                            ForEach(values.indices, id: \.self) { i in
                                let v = values[i]
                                let h = max(3, geo.size.height * CGFloat(v) / CGFloat(maxVal))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(v >= goalSeconds ? Color.accentColor : Color.accentColor.opacity(0.45))
                                    .frame(height: h)
                                    .frame(maxWidth: .infinity)
                                    .opacity(v == 0 ? 0.18 : 1)
                            }
                        }
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: goalY))
                            p.addLine(to: CGPoint(x: geo.size.width, y: goalY))
                        }
                        .stroke(Color.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    }
                }
            }
            .frame(height: AxisLayout.plotHeight)
            HStack(spacing: AxisLayout.columnSpacing) {
                Color.clear.frame(width: leadingInset - AxisLayout.columnSpacing)
                HStack(spacing: 6) {
                    ForEach(labels.indices, id: \.self) { i in
                        Text(labels[i])
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if !xAxisLabel.isEmpty {
                HStack(spacing: AxisLayout.columnSpacing) {
                    Color.clear.frame(width: leadingInset - AxisLayout.columnSpacing)
                    Text(xAxisLabel)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }
}

struct PaceLine7Day: View {
    let labels: [String]
    let values: [Double]
    let yAxisLabel: String
    let xAxisLabel: String

    private var maxVal: Double {
        max(0.5, values.max() ?? 0.5)
    }

    private var maxLabel: String {
        String(format: "%.1f", maxVal)
    }

    private var midLabel: String {
        String(format: "%.1f", maxVal / 2)
    }

    private var leadingInset: CGFloat {
        (yAxisLabel.isEmpty ? 0 : AxisLayout.yLabelWidth + AxisLayout.columnSpacing)
            + AxisLayout.yTicksWidth
            + AxisLayout.columnSpacing
    }

    var body: some View {
        if values.allSatisfy({ $0 == 0 }) {
            VStack(spacing: 4) {
                Text("Not enough page data yet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Log pages on a session to see pace.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 2) {
                HStack(alignment: .top, spacing: AxisLayout.columnSpacing) {
                    if !yAxisLabel.isEmpty {
                        VerticalAxisLabel(text: yAxisLabel)
                            .frame(width: AxisLayout.yLabelWidth, height: AxisLayout.plotHeight, alignment: .center)
                    }

                    VStack(alignment: .trailing) {
                        Text(maxLabel)
                        Spacer()
                        Text(midLabel)
                        Spacer()
                        Text("0.0")
                    }
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: AxisLayout.yTicksWidth, alignment: .trailing)

                    GeometryReader { geo in
                        let pts: [CGPoint] = values.enumerated().map { idx, v in
                            let x = values.count <= 1 ? geo.size.width / 2
                                : geo.size.width * CGFloat(idx) / CGFloat(values.count - 1)
                            let y = geo.size.height * (1 - CGFloat(v / maxVal))
                            return CGPoint(x: x, y: y)
                        }
                        ZStack {
                            VStack(spacing: 0) {
                                Divider().opacity(0.18)
                                Spacer()
                                Divider().opacity(0.18)
                                Spacer()
                                Divider().opacity(0.18)
                            }
                            Path { p in
                                guard let first = pts.first else { return }
                                p.move(to: CGPoint(x: first.x, y: geo.size.height))
                                p.addLine(to: first)
                                for pt in pts.dropFirst() { p.addLine(to: pt) }
                                p.addLine(to: CGPoint(x: pts.last?.x ?? 0, y: geo.size.height))
                                p.closeSubpath()
                            }
                            .fill(Color.teal.opacity(0.18))

                            Path { p in
                                guard let first = pts.first else { return }
                                p.move(to: first)
                                for pt in pts.dropFirst() { p.addLine(to: pt) }
                            }
                            .stroke(Color.teal, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                            ForEach(pts.indices, id: \.self) { i in
                                Circle()
                                    .fill(Color.teal)
                                    .frame(width: 5, height: 5)
                                    .position(pts[i])
                            }
                        }
                    }
                }
                .frame(height: AxisLayout.plotHeight)
                HStack(spacing: AxisLayout.columnSpacing) {
                    Color.clear.frame(width: leadingInset - AxisLayout.columnSpacing)
                    HStack(spacing: 6) {
                        ForEach(labels.indices, id: \.self) { i in
                            Text(labels[i])
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                if !xAxisLabel.isEmpty {
                    HStack(spacing: AxisLayout.columnSpacing) {
                        Color.clear.frame(width: leadingInset - AxisLayout.columnSpacing)
                        Text(xAxisLabel)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }
}

#Preview("Graphs medium", as: .systemMedium) {
    BookMarkGraphsWidget()
} timeline: {
    GraphsEntry(date: .now, snapshot: .preview)
}

#Preview("Graphs large", as: .systemLarge) {
    BookMarkGraphsWidget()
} timeline: {
    GraphsEntry(date: .now, snapshot: .preview)
}
