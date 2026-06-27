import WidgetKit
import SwiftUI

// MARK: - Provider

struct ContinueReadingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let cover: UIImage?
}

struct ContinueReadingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueReadingEntry {
        ContinueReadingEntry(date: Date(), snapshot: .preview, cover: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueReadingEntry) -> Void) {
        let snap = WidgetSnapshotStore.load()
        let coverFile = context.family == .systemSmall ? snap.continueSmallCoverFile : snap.continueCoverFile
        let cover = WidgetSnapshotStore.loadCover(filename: coverFile)
        completion(ContinueReadingEntry(date: Date(), snapshot: snap, cover: cover))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueReadingEntry>) -> Void) {
        let snap = WidgetSnapshotStore.load()
        let coverFile = context.family == .systemSmall ? snap.continueSmallCoverFile : snap.continueCoverFile
        let cover = WidgetSnapshotStore.loadCover(filename: coverFile)
        let now = Date()
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        let postMidnight = cal.date(byAdding: .minute, value: 1, to: midnight) ?? midnight
        let entries = [
            ContinueReadingEntry(date: now, snapshot: adjustForDay(snap, entryDate: now), cover: cover),
            ContinueReadingEntry(date: midnight, snapshot: adjustForDay(snap, entryDate: midnight), cover: cover)
        ]

        completion(Timeline(entries: entries, policy: .after(postMidnight)))
    }

    private func adjustForDay(_ snap: WidgetSnapshot, entryDate: Date) -> WidgetSnapshot {
        guard !Calendar.current.isDate(snap.updatedAt, inSameDayAs: entryDate) else { return snap }
        var adjusted = snap
        adjusted.todayMinutes = 0
        return adjusted
    }
}

// MARK: - Continue Reading widget

struct BookMarkSmallContinueWidget: Widget {
    let kind = "BookMarkSmallContinueWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContinueReadingProvider()) { entry in
            ContinueReadingWidgetView(entry: entry)
                .containerBackgroundCompat()
        }
        .configurationDisplayName("Continue Reading")
        .description("Active book, progress, today's goal, and streak.")
        .supportedFamilies([.systemSmall])
    }
}

struct BookMarkWidget: Widget {
    let kind = "BookMarkWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContinueReadingProvider()) { entry in
            ContinueReadingWidgetView(entry: entry)
                .containerBackgroundCompat()
        }
        .configurationDisplayName("Continue Reading")
        .description("Active book, progress, today's goal, and streak.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - View

struct ContinueReadingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueReadingEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var cover: UIImage? { entry.cover }

    @ViewBuilder
    var body: some View {
        Group {
            switch family {
            case .systemSmall:  smallBody
            case .systemMedium: mediumBody
            case .systemLarge:  largeBody
            default:            mediumBody
            }
        }
    }

    // ---- Small ----

    private var smallBody: some View {
        let author = snapshot.continueAuthor
        let title = snapshot.continueTitle ?? "No book in progress"
        let progress = snapshot.continueProgressPct ?? 0
        let goalProgress = min(1, Double(snapshot.todayMinutes) / Double(max(1, snapshot.goalMinutes)))

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                smallCoverView

                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: goalProgress)
                        .stroke(snapshot.todayMinutes >= snapshot.goalMinutes ? Color.yellow : Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: -1) {
                        Text("\(min(999, snapshot.todayMinutes))")
                            .font(.system(size: 15, weight: .black))
                            .monospacedDigit()
                        Text("/ \(snapshot.goalMinutes)m")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .offset(x: 2, y: -2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)

                if let author {
                    Text(author)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.75)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(4, CGFloat(progress) / 100 * 86), height: 4)
                    }
                    .frame(width: 86)

                Text("\(progress)% read")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    @ViewBuilder
    private var smallCoverView: some View {
        if let cover {
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
                .frame(width: 54, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.22))
                .frame(width: 54, height: 72)
                .overlay(
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                )
        }
    }

    // ---- Medium (Apple Books-style) ----

    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 12) {
            coverView(width: 72, height: 108)

            VStack(alignment: .leading, spacing: 0) {
                Text("CONTINUE READING")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.continueTitle ?? "No book in progress")
                        .font(.system(size: 15, weight: .heavy))
                        .lineLimit(2)
                    if let author = snapshot.continueAuthor {
                        Text(author)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .leading, spacing: 4) {
                    if let pct = snapshot.continueProgressPct {
                        progressBar(pct: pct)
                    }
                    if let secs = snapshot.continueBookSeconds, secs > 0 {
                        Text("\(WidgetFmt.duration(secs)) read")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .trailing, spacing: 0) {
                GoalRing(minutes: snapshot.todayMinutes, goal: snapshot.goalMinutes)
                    .frame(width: 64, height: 64)
                Spacer(minLength: 8)
                StreakChip(streak: snapshot.currentStreak)
                    .fixedSize()
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // ---- Large ----

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                coverView(width: 60, height: 90)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CONTINUE READING")
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(0.6)
                                .foregroundStyle(.secondary)
                            Text(snapshot.continueTitle ?? "No book in progress")
                                .font(.system(size: 16, weight: .heavy))
                                .lineLimit(2)
                            if let author = snapshot.continueAuthor {
                                Text(author)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        GoalRing(minutes: snapshot.todayMinutes, goal: snapshot.goalMinutes)
                            .frame(width: 52, height: 52)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        if let pct = snapshot.continueProgressPct {
                            progressBar(pct: pct)
                        }

                        HStack(alignment: .top, spacing: 8) {
                            if let secs = snapshot.continueBookSeconds, secs > 0 {
                                Text("\(WidgetFmt.duration(secs)) total read")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            Spacer(minLength: 0)
                            streakPair
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 3) {
                Text("READING TIME")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                BarChart7Day(
                    labels: snapshot.last7DayLabels,
                    values: snapshot.last7DaySeconds,
                    goalSeconds: snapshot.goalMinutes * 60,
                    yAxisLabel: "",
                    xAxisLabel: "",
                    plotHeight: 54
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("READING PACE")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                PaceLine7Day(
                    labels: snapshot.last7DayLabels,
                    values: snapshot.last7DayPace,
                    yAxisLabel: "",
                    xAxisLabel: "",
                    plotHeight: 50
                )
            }
        }
        .padding(12)
    }

    private var streakPair: some View {
        HStack(spacing: 6) {
            statBlock(emoji: "🔥", number: snapshot.currentStreak, label: "Current")
            statBlock(emoji: "🏆", number: snapshot.bestStreak, label: "Best")
        }
    }

    private func statBlock(emoji: String, number: Int, label: String) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                Text(emoji).font(.system(size: 10))
                Text("\(number)")
                    .font(.system(size: 15, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(label.uppercased())
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: 42)
    }

    // ---- Subviews ----

    @ViewBuilder
    private func coverView(width: CGFloat, height: CGFloat) -> some View {
        if let img = cover {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(
                    colors: [Color(red: 0.18, green: 0.42, blue: 0.31), Color(red: 0.32, green: 0.72, blue: 0.53)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: width, height: height)
                .overlay(
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: width * 0.42))
                        .foregroundStyle(.white.opacity(0.85))
                )
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        }
    }

    private func progressBar(pct: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.28))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, pct))) / 100)
                }
            }
            .frame(height: 3)
            Text("\(pct)%")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared widget pieces

struct GoalRing: View {
    let minutes: Int
    let goal: Int

    private var pct: Double { min(1, Double(minutes) / Double(max(1, goal))) }
    private var met: Bool { minutes >= goal }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 5)
            Circle()
                .trim(from: 0, to: pct)
                .stroke(met ? Color.yellow : Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text("\(min(999, minutes))m")
                    .font(.system(size: 17, weight: .black))
                Text("/ \(goal)m")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StreakChip: View {
    let streak: Int
    var body: some View {
        Text("\(streak) day streak")
            .font(.system(size: 12, weight: .heavy))
            .monospacedDigit()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.18), in: Capsule())
    }
}

// MARK: - iOS 16/17 container background compat

extension View {
    @ViewBuilder
    func containerBackgroundCompat() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(.background, for: .widget)
        } else {
            self.padding()
                .background(Color(uiColor: .systemBackground))
        }
    }
}

#Preview("Small", as: .systemSmall) {
    BookMarkSmallContinueWidget()
} timeline: {
    ContinueReadingEntry(date: .now, snapshot: .preview, cover: nil)
}

#Preview("Medium", as: .systemMedium) {
    BookMarkWidget()
} timeline: {
    ContinueReadingEntry(date: .now, snapshot: .preview, cover: nil)
}

#Preview("Large", as: .systemLarge) {
    BookMarkWidget()
} timeline: {
    ContinueReadingEntry(date: .now, snapshot: .preview, cover: nil)
}
