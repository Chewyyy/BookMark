import WidgetKit
import SwiftUI

struct BookMarkEntry: TimelineEntry {
    var date: Date
    var snapshot: SharedSnapshot
}

struct BookMarkProvider: TimelineProvider {
    func placeholder(in context: Context) -> BookMarkEntry {
        BookMarkEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (BookMarkEntry) -> Void) {
        completion(BookMarkEntry(date: Date(), snapshot: SharedSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BookMarkEntry>) -> Void) {
        let snap = SharedSnapshotStore.load()
        let entry = BookMarkEntry(date: Date(), snapshot: snap)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Views

struct GoalRingView: View {
    let minutes: Int
    let goal: Int

    private var pct: Double { min(1, Double(minutes) / Double(max(1, goal))) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 6)
            Circle()
                .trim(from: 0, to: pct)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(minutes)").font(.system(size: 22, weight: .black))
                Text("/ \(goal)m").font(.system(size: 9, weight: .heavy)).foregroundStyle(.secondary)
            }
        }
    }
}

struct SmallHomeWidget: View {
    let snapshot: SharedSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 3) {
                    Text("🔥")
                    Text("\(snapshot.currentStreak)")
                        .font(.system(size: 12, weight: .heavy))
                }
            }
            GoalRingView(minutes: snapshot.todayMinutes, goal: snapshot.goalMinutes)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            if let title = snapshot.continueTitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .heavy))
                        .lineLimit(1)
                    if let pct = snapshot.continueProgressPct {
                        Text("\(pct)% read")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
    }
}

struct MediumHomeWidget: View {
    let snapshot: SharedSnapshot

    var body: some View {
        HStack(spacing: 14) {
            GoalRingView(minutes: snapshot.todayMinutes, goal: snapshot.goalMinutes)
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("🔥")
                    Text("\(snapshot.currentStreak)-day streak")
                        .font(.system(size: 12, weight: .heavy))
                }
                if let title = snapshot.continueTitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CONTINUE")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(.system(size: 14, weight: .heavy))
                            .lineLimit(2)
                        if let author = snapshot.continueAuthor {
                            Text(author)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let pct = snapshot.continueProgressPct {
                            ProgressView(value: Double(pct) / 100.0)
                                .tint(.accentColor)
                                .padding(.top, 2)
                        }
                    }
                } else {
                    Text("No book in progress")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }
}

struct LockCircularWidget: View {
    let snapshot: SharedSnapshot

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text("\(snapshot.todayMinutes)")
                    .font(.system(size: 18, weight: .black))
                Text("min")
                    .font(.system(size: 8, weight: .heavy))
            }
        }
    }
}

struct LockRectangularWidget: View {
    let snapshot: SharedSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "book")
                Text("\(snapshot.todayMinutes) / \(snapshot.goalMinutes) min today")
                    .font(.system(size: 11, weight: .heavy))
            }
            if let title = snapshot.continueTitle {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            HStack(spacing: 3) {
                Text("🔥")
                Text("\(snapshot.currentStreak)-day streak")
                    .font(.system(size: 10, weight: .heavy))
            }
        }
    }
}

// MARK: - Widget declarations

struct BookMarkHomeWidget: Widget {
    let kind = "BookMarkHomeWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BookMarkProvider()) { entry in
            entryView(entry: entry)
        }
        .configurationDisplayName("Today's Reading")
        .description("See today's reading time, streak, and what to read next.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }

    @ViewBuilder
    private func entryView(entry: BookMarkEntry) -> some View {
        if #available(iOS 17.0, *) {
            content(for: entry).containerBackground(.background, for: .widget)
        } else {
            content(for: entry).background(Color(uiColor: .systemBackground))
        }
    }

    @ViewBuilder
    private func content(for entry: BookMarkEntry) -> some View {
        switch widgetFamily {
        default:
            MediumHomeWidget(snapshot: entry.snapshot)
        }
    }

    @Environment(\.widgetFamily) private var widgetFamily
}

struct BookMarkLockWidget: Widget {
    let kind = "BookMarkLockWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BookMarkProvider()) { entry in
            entryView(entry: entry)
        }
        .configurationDisplayName("Reading Glance")
        .description("Today's reading minutes on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }

    @ViewBuilder
    private func entryView(entry: BookMarkEntry) -> some View {
        switch widgetFamily {
        case .accessoryCircular: LockCircularWidget(snapshot: entry.snapshot)
        case .accessoryRectangular: LockRectangularWidget(snapshot: entry.snapshot)
        case .accessoryInline:
            Text("📖 \(entry.snapshot.todayMinutes)/\(entry.snapshot.goalMinutes) min · 🔥\(entry.snapshot.currentStreak)")
        default:
            LockRectangularWidget(snapshot: entry.snapshot)
        }
    }

    @Environment(\.widgetFamily) private var widgetFamily
}
