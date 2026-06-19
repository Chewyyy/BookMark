import SwiftUI

struct JournalView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showGoalEditor = false
    @State private var calMonth = Date()
    @State private var daySheetKey: String?
    @State private var finishTarget: Book?
    @State private var detailTarget: Book?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    GoalCard(
                        todayMinutes: Fmt.minutes(store.todaySeconds()),
                        goalMinutes: max(1, store.goal.minutes),
                        streakDay: store.currentStreak(),
                        onEdit: { showGoalEditor = true }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 14)

                    StreakRow(
                        current: store.currentStreak(),
                        best: store.bestStreak()
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)

                    sectionLabel("Reading Calendar")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)

                    CalendarCard(
                        month: $calMonth,
                        secondsByDay: store.secondsByDay(),
                        goalSeconds: max(1, store.goal.minutes) * 60,
                        onTapDay: { key in daySheetKey = key }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                    Text("Tap any day to view or add reading sessions —\ncarry over streaks from other apps.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtle)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 22)

                    sectionLabel("Books Finished")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)

                    FinishedTimeline(
                        books: store.books.filter(\.finished).sorted {
                            ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast)
                        },
                        onTap: { detailTarget = $0 },
                        onEditDate: { finishTarget = $0 }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .readableContentWidth(hSizeClass == .regular ? 720 : .infinity)
            }
            .background(Theme.background)
        }
        .sheet(isPresented: $showGoalEditor) {
            GoalEditorSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(
            get: { daySheetKey.map { DayKey(id: $0) } },
            set: { daySheetKey = $0?.id }
        )) { key in
            DayDetailSheet(dayKey: key.id)
                .presentationDetents([.large])
        }
        .sheet(item: $finishTarget) { bk in
            FinishDateSheet(book: bk) { }
                .presentationDetents([.medium])
        }
        .sheet(item: $detailTarget) { bk in
            BookDetailsSheet(book: bk)
                .presentationDetents([.medium])
        }
    }

    private var header: some View {
        HStack {
            Text("Journal")
                .font(.system(size: 23, weight: .heavy))
                .tracking(-0.5)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background(Theme.background)
        .overlay(Divider().opacity(0.4), alignment: .bottom)
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(Theme.subtle)
            Spacer()
        }
    }
}

private struct DayKey: Identifiable { let id: String }

struct GoalCard: View {
    let todayMinutes: Int
    let goalMinutes: Int
    let streakDay: Int
    let onEdit: () -> Void

    private var pct: Double { min(1.0, Double(todayMinutes) / Double(max(1, goalMinutes))) }
    private var met: Bool { todayMinutes >= goalMinutes }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TODAY'S READING")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.72))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(todayMinutes)")
                            .font(.system(size: 26, weight: .heavy))
                            .tracking(-0.5)
                            .foregroundStyle(.white)
                        Text("/ \(goalMinutes) min")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                Spacer()
                Button("Edit Goal", action: onEdit)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Capsule())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.22))
                    Capsule()
                        .fill(met ? Color(red: 1, green: 0.85, blue: 0.44) : Color.white)
                        .frame(width: geo.size.width * CGFloat(pct))
                }
            }
            .frame(height: 10)

            HStack {
                Text(goalMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Text("\(Int((pct * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .padding(18)
        .background(Theme.accent)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .overlay(alignment: .topTrailing) {
            Circle().fill(Color.white.opacity(0.07))
                .frame(width: 120, height: 120)
                .offset(x: 30, y: -30)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
                .allowsHitTesting(false)
        }
    }

    private var goalMessage: String {
        if met {
            if streakDay > 0 { return "Goal met — streak day \(streakDay) 🔥" }
            return "Goal met — nice work!"
        }
        if todayMinutes == 0 { return "Read to start your day" }
        let remaining = max(1, goalMinutes - todayMinutes)
        return "\(remaining) min to go"
    }
}

struct StreakRow: View {
    let current: Int
    let best: Int

    var body: some View {
        HStack(spacing: 12) {
            streakCard(icon: "🔥", number: current, label: "Current streak")
            streakCard(icon: "🏆", number: best, label: "Best streak")
        }
    }

    private func streakCard(icon: String, number: Int, label: String) -> some View {
        HStack(spacing: 12) {
            Text(icon).font(.system(size: 24))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(number)")
                    .font(.system(size: 22, weight: .heavy))
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.subtle)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardStyle()
    }
}

struct CalendarCard: View {
    @Binding var month: Date
    let secondsByDay: [String: Int]
    let goalSeconds: Int
    let onTapDay: (String) -> Void

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f.string(from: month)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(monthTitle)
                    .font(.system(size: 15, weight: .heavy))
                Spacer()
                Button { shift(-1) } label: { navIcon("chevron.left") }
                    .disabled(false)
                Button { shift(1) } label: { navIcon("chevron.right") }
                    .disabled(isCurrentMonthOrLater)
                    .opacity(isCurrentMonthOrLater ? 0.3 : 1)
            }
            grid
            legend
        }
        .padding(16)
        .cardStyle()
    }

    private func navIcon(_ system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(Theme.accent)
            .frame(width: 30, height: 30)
            .background(Theme.accent.opacity(0.1))
            .clipShape(Circle())
    }

    private func shift(_ delta: Int) {
        if let new = Calendar.current.date(byAdding: .month, value: delta, to: month) {
            month = new
        }
    }

    private var isCurrentMonthOrLater: Bool {
        let cal = Calendar.current
        let nowComp = cal.dateComponents([.year, .month], from: Date())
        let monthComp = cal.dateComponents([.year, .month], from: month)
        return (monthComp.year ?? 0, monthComp.month ?? 0) >= (nowComp.year ?? 0, nowComp.month ?? 0)
    }

    private var dowSymbols: [String] {
        let f = DateFormatter()
        f.locale = Locale.current
        let cal = Calendar.current
        let first = cal.firstWeekday - 1
        let syms = f.veryShortStandaloneWeekdaySymbols ?? ["S","M","T","W","T","F","S"]
        return Array(syms[first...] + syms[..<first])
    }

    private var grid: some View {
        let cells = calendarCells()
        let spacing: CGFloat = 4
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 7),
            spacing: spacing
        ) {
            ForEach(Array(dowSymbols.enumerated()), id: \.offset) { _, sym in
                Text(sym.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Theme.subtle)
                    .frame(maxWidth: .infinity)
                    .frame(height: 18)
                    .padding(.bottom, 7)
            }
            ForEach(cells.indices, id: \.self) { i in
                cellView(cells[i])
            }
        }
    }

    private func cellView(_ cell: CalCell) -> some View {
        Group {
            if let day = cell.day {
                Button {
                    onTapDay(cell.key ?? Fmt.dayKey(day))
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(cell.met ? Theme.accent : Color.clear)
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(cell.today ? (cell.met ? Theme.gold : Theme.accent) : Color.clear, lineWidth: 2)
                        VStack(spacing: 2) {
                            Text("\(Calendar.current.component(.day, from: day))")
                                .font(.system(size: 13, weight: cell.met ? .heavy : .semibold))
                                .foregroundStyle(cellTextColor(cell))
                            Circle()
                                .fill(cell.met ? Color.white.opacity(0.85) :
                                      (cell.hasReading ? Theme.accent2 : Color.clear))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                }
                .buttonStyle(.plain)
                .disabled(cell.future)
                .opacity(cell.future ? 0.4 : 1)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
    }

    private func cellTextColor(_ cell: CalCell) -> Color {
        if cell.met { return .white }
        if cell.future { return Theme.subtle.opacity(0.4) }
        return Theme.text
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: Theme.accent2, label: "Read")
            legendItem(color: Theme.accent, label: "Goal met")
            HStack(spacing: 5) {
                Circle().stroke(Theme.accent, lineWidth: 2).frame(width: 8, height: 8)
                Text("Today").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.subtle)
            }
        }
        .padding(.top, 4)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.subtle)
        }
    }

    private struct CalCell {
        var day: Date?
        var key: String?
        var met: Bool
        var hasReading: Bool
        var today: Bool
        var future: Bool
    }

    private func calendarCells() -> [CalCell] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let firstOfMonth = cal.date(from: comps),
              let monthRange = cal.range(of: .day, in: .month, for: firstOfMonth)
        else { return [] }

        let weekdayFirst = (cal.component(.weekday, from: firstOfMonth) - cal.firstWeekday + 7) % 7
        var cells: [CalCell] = Array(repeating: CalCell(day: nil, key: nil, met: false, hasReading: false, today: false, future: false), count: weekdayFirst)

        let today = Date()
        let todayKey = Fmt.dayKey(today)
        for day in monthRange {
            if let d = cal.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                let key = Fmt.dayKey(d)
                let secs = secondsByDay[key] ?? 0
                let future = d > today && !cal.isDate(d, inSameDayAs: today)
                cells.append(CalCell(
                    day: d,
                    key: key,
                    met: secs >= goalSeconds,
                    hasReading: secs > 0,
                    today: key == todayKey,
                    future: future
                ))
            }
        }
        let remainder = (7 - cells.count % 7) % 7
        cells.append(contentsOf: Array(repeating: CalCell(day: nil, key: nil, met: false, hasReading: false, today: false, future: false), count: remainder))
        return cells
    }
}

struct FinishedTimeline: View {
    let books: [Book]
    let onTap: (Book) -> Void
    let onEditDate: (Book) -> Void

    var body: some View {
        if books.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Theme.subtle.opacity(0.4))
                Text("No finished books yet")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.subtle)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groupedByYear(), id: \.year) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(String(group.year))
                                .font(.system(size: 19, weight: .heavy))
                                .tracking(-0.4)
                            Text("\(group.books.count) book\(group.books.count == 1 ? "" : "s")")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.subtle)
                        }
                        VStack(spacing: 10) {
                            ForEach(group.books) { bk in
                                row(bk)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ bk: Book) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.gold).frame(width: 9, height: 9)
            BookCover(book: bk)
                .frame(width: 38, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(bk.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text(bk.finishedAt.map(Fmt.dateAndTime) ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                onEditDate(bk)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .smallCardStyle()
        .contentShape(Rectangle())
        .onTapGesture { onTap(bk) }
    }

    private struct YearGroup { var year: Int; var books: [Book] }

    private func groupedByYear() -> [YearGroup] {
        let cal = Calendar.current
        var map: [Int: [Book]] = [:]
        for b in books {
            let y = cal.component(.year, from: b.finishedAt ?? Date())
            map[y, default: []].append(b)
        }
        return map.keys.sorted(by: >).map { y in
            YearGroup(year: y, books: map[y] ?? [])
        }
    }
}
