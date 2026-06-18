import WidgetKit
import SwiftUI

struct StatsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: Date(), snapshot: .preview)
    }
    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        completion(StatsEntry(date: Date(), snapshot: WidgetSnapshotStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        let snap = WidgetSnapshotStore.load()
        let now = Date()
        let cal = Calendar.current
        var entries: [StatsEntry] = []
        for offset in stride(from: 0, through: 90, by: 30) {
            if let d = cal.date(byAdding: .minute, value: offset, to: now) {
                entries.append(StatsEntry(date: d, snapshot: snap))
            }
        }
        let refresh = cal.date(byAdding: .minute, value: 90, to: now) ?? now
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

struct BookMarkStatsWidget: Widget {
    let kind = "BookMarkStatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatsProvider()) { entry in
            StatsWidgetView(entry: entry)
                .containerBackgroundCompat()
        }
        .configurationDisplayName("Reading Stats")
        .description("All-time and weekly reading stats at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct StatsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatsEntry

    var body: some View {
        let s = entry.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("READING STATS")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Updated \(s.updatedAt, style: .relative)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            grid(for: s)
        }
        .padding(family == .systemLarge ? 14 : 12)
    }

    private func grid(for s: WidgetSnapshot) -> some View {
        let columns: [GridItem] = family == .systemLarge
            ? Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
            : Array(repeating: GridItem(.flexible(), spacing: 6), count: 2)

        let rows: [(label: String, value: String, sub: String, accent: Bool)] = family == .systemLarge ? [
            ("Total Read", WidgetFmt.duration(s.totalSeconds), "all time", true),
            ("Finished", "\(s.finishedBooks)", "books completed", false),
            ("Avg Session", WidgetFmt.duration(s.avgSessionSeconds), "per session", false),
            ("This Week", WidgetFmt.duration(s.weekSeconds), "last 7 days", false),
            ("Total Pages", "\(s.totalPages)", "all time", false),
            ("Pages / Week", "\(s.weekPages)", "last 7 days", false),
            ("Avg Pages", "\(s.avgPages)", "per session", false),
            ("Avg Pace", WidgetFmt.compactPace(s.avgPace), "pages/min", false),
        ] : [
            ("Total Read", WidgetFmt.duration(s.totalSeconds), "all time", true),
            ("Finished", "\(s.finishedBooks)", "books done", false),
            ("This Week", WidgetFmt.duration(s.weekSeconds), "last 7 days", false),
            ("Avg Pace", WidgetFmt.compactPace(s.avgPace), "pages/min", false),
        ]

        return LazyVGrid(columns: columns, spacing: family == .systemLarge ? 8 : 6) {
            ForEach(rows.indices, id: \.self) { i in
                cell(rows[i])
            }
        }
    }

    private func cell(_ row: (label: String, value: String, sub: String, accent: Bool)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(row.accent ? Color.white.opacity(0.78) : .secondary)
            Text(row.value)
                .font(.system(size: family == .systemLarge ? 19 : 16, weight: .heavy))
                .tracking(-0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(row.accent ? .white : .primary)
            Text(row.sub)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(row.accent ? Color.white.opacity(0.7) : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(row.accent ? Color.accentColor : Color.secondary.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

#Preview("Stats medium", as: .systemMedium) {
    BookMarkStatsWidget()
} timeline: {
    StatsEntry(date: .now, snapshot: .preview)
}

#Preview("Stats large", as: .systemLarge) {
    BookMarkStatsWidget()
} timeline: {
    StatsEntry(date: .now, snapshot: .preview)
}
