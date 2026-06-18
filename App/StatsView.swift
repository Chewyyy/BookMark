import SwiftUI
import UniformTypeIdentifiers

struct StatsView: View {
    @EnvironmentObject private var store: Store
    @State private var showRestore = false
    @State private var showCsvImport = false
    @State private var showManualSession = false
    @State private var showBackupFolderPicker = false
    @State private var sessionsVisible = 10
    @State private var editingSession: ReadingSession?
    @State private var pendingDelete: ReadingSession?
    @State private var toastMessage: String?
    @State private var lastBackupStatus: String? = AutoBackup.lastBackupStatus()
    @State private var backupRefreshTick = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 20, pinnedViews: []) {
                    statsGrid
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    chartCard(title: "Last 7 Days") {
                        BarChart(data: last7DaysSeconds(), goalSeconds: max(1, store.goal.minutes) * 60)
                            .frame(height: 80)
                    }
                    .padding(.horizontal, 16)

                    chartCard(title: "Reading Pace · Last 7 Days") {
                        PaceChart(data: last7DaysPace())
                            .frame(height: 154)
                    }
                    .padding(.horizontal, 16)

                    YearBooksCard(books: yearFinishedBooks(), year: Calendar.current.component(.year, from: Date()))
                        .padding(.horizontal, 16)

                    DataAndBackupCard(
                        onExportBackup: exportBackup,
                        onExportCsv: exportCsv,
                        onRestore: { showRestore = true },
                        onImportCsv: { showCsvImport = true },
                        onAddManualSession: { showManualSession = true },
                        onSaveToIPhone: { saveToThisIPhone() },
                        onChooseBackupFolder: { showBackupFolderPicker = true },
                        onClearBackupFolder: {
                            store.clearBackupFolder()
                            showToast("Backups will save to On My iPhone / BookMark")
                        },
                        backupFolderName: store.backupFolderName,
                        lastBackupStatus: lastBackupStatus
                    )
                    .id(backupRefreshTick)
                    .padding(.horizontal, 16)

                    recentSessionsSection
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
            }
            .background(Theme.background)
        }
        // Each presentation modifier is hosted on its own empty background so
        // SwiftUI doesn't drop one when several are chained on the same view —
        // stacking two .fileImporter calls on the same view is a known
        // regression that broke the Restore Backup button.
        .background(
            Color.clear
                .fileImporter(
                    isPresented: $showRestore,
                    allowedContentTypes: [.json],
                    allowsMultipleSelection: false
                ) { result in
                    handleRestore(result)
                }
        )
        .background(
            Color.clear
                .fileImporter(
                    isPresented: $showCsvImport,
                    allowedContentTypes: [.commaSeparatedText, .plainText],
                    allowsMultipleSelection: false
                ) { result in
                    handleCsvImport(result)
                }
        )
        .background(
            Color.clear
                .sheet(isPresented: $showManualSession) {
                    DayDetailSheet(dayKey: Fmt.dayKey(Date()))
                        .presentationDetents([.large])
                }
        )
        .background(
            Color.clear
                .sheet(item: $editingSession) { s in
                    SessionEditorSheet(session: s)
                        .presentationDetents([.large])
                }
        )
        .background(
            Color.clear
                .sheet(isPresented: $showBackupFolderPicker) {
                    FolderPicker { url in
                        showBackupFolderPicker = false
                        do {
                            try store.setBackupFolder(url)
                            showToast("Backups will save to \(store.backupFolderName ?? url.lastPathComponent)")
                        } catch {
                            showToast("Couldn't save backup folder: \(error.localizedDescription)")
                        }
                    }
                }
        )
        .alert("Delete this session?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let s = pendingDelete { store.deleteSession(id: s.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the reading session permanently. It won't affect the book.")
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                ToastView(text: toastMessage)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Stats")
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

    private var statsGrid: some View {
        let totalSecs = store.sessions.reduce(0) { $0 + $1.secs }
        let finishedCount = store.books.filter(\.finished).count
        let avgSession = store.sessions.isEmpty ? 0 : totalSecs / store.sessions.count
        let weekSecs = lastNDaysSeconds(7).reduce(0, +)
        let totalPages = store.sessions.reduce(0) { $0 + ($1.pages ?? 0) }
        let pageSessions = store.sessions.filter { ($0.pages ?? 0) > 0 }
        let avgPages = pageSessions.isEmpty ? 0 : totalPages / pageSessions.count
        let weekPages = lastNDaysPages(7).reduce(0, +)
        let paceTotalMins = max(1, pageSessions.reduce(0) { $0 + $1.secs }) / 60
        let avgPace = pageSessions.isEmpty ? 0.0 : Double(pageSessions.reduce(0) { $0 + ($1.pages ?? 0) }) / Double(paceTotalMins)

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            statCard(label: "Total Read", value: Fmt.duration(totalSecs), sub: "all time", green: true)
            statCard(label: "Finished", value: "\(finishedCount)", sub: "books completed")
            statCard(label: "Avg Session", value: Fmt.duration(avgSession), sub: "per session")
            statCard(label: "This Week", value: Fmt.duration(weekSecs), sub: "last 7 days")
            statCard(label: "Total Pages", value: "\(totalPages)", sub: "all time")
            statCard(label: "Avg Pages", value: "\(avgPages)", sub: "per session")
            statCard(label: "Pages This Week", value: "\(weekPages)", sub: "last 7 days")
            statCard(label: "Avg Pace", value: String(format: "%.2f", avgPace), sub: "pages/min")
        }
    }

    private func statCard(label: String, value: String, sub: String, green: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(green ? Color.white.opacity(0.7) : Theme.subtle)
            Text(value)
                .font(.system(size: 28, weight: .heavy))
                .tracking(-1)
                .foregroundStyle(green ? .white : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(sub)
                .font(.system(size: 12))
                .foregroundStyle(green ? Color.white.opacity(0.75) : Theme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(green ? Theme.accent : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 2)
    }

    private func chartCard<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
            content()
        }
        .padding(16)
        .cardStyle()
    }

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Sessions")
                .font(.system(size: 14, weight: .bold))
            let sorted = store.sessions.sorted { $0.start > $1.start }
            if sorted.isEmpty {
                Text("No sessions yet.\nOpen a book to start reading!")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.subtle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                VStack(spacing: 8) {
                    ForEach(sorted.prefix(sessionsVisible)) { s in
                        sessionRow(s)
                    }
                    if sorted.count > sessionsVisible {
                        let nextBatch = min(10, sorted.count - sessionsVisible)
                        let remainingAfter = max(0, sorted.count - sessionsVisible - nextBatch)
                        Button {
                            sessionsVisible += 10
                        } label: {
                            Text(remainingAfter > 0
                                 ? "Show \(nextBatch) More · \(remainingAfter) remaining"
                                 : "Show \(nextBatch) More")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Theme.accent.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func sessionRow(_ s: ReadingSession) -> some View {
        HStack(spacing: 12) {
            Circle().fill(s.manual ? Theme.gold : Theme.accent).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.bookTitle.isEmpty ? "Untitled" : s.bookTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(Fmt.dateAndTime(s.start))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtle)
                if let pages = s.pages, pages > 0 {
                    Text("\(pages) page\(pages == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Theme.accent)
                }
                if let progressDelta = s.progressDelta, progressDelta > 0 {
                    Text("+\(String(format: "%.1f", progressDelta * 100))%")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            Text(Fmt.duration(s.secs))
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Theme.accent)
            Button {
                pendingDelete = s
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.subtle)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .smallCardStyle()
        .contentShape(Rectangle())
        .onTapGesture { editingSession = s }
    }

    private func lastNDaysSeconds(_ n: Int) -> [Int] {
        let map = store.secondsByDay()
        let cal = Calendar.current
        var out: [Int] = []
        for i in (0..<n).reversed() {
            if let d = cal.date(byAdding: .day, value: -i, to: Date()) {
                out.append(map[Fmt.dayKey(d)] ?? 0)
            }
        }
        return out
    }

    private func lastNDaysPages(_ n: Int) -> [Int] {
        let cal = Calendar.current
        var map: [String: Int] = [:]
        for s in store.sessions {
            map[Fmt.dayKey(s.start), default: 0] += s.pages ?? 0
        }
        var out: [Int] = []
        for i in (0..<n).reversed() {
            if let d = cal.date(byAdding: .day, value: -i, to: Date()) {
                out.append(map[Fmt.dayKey(d)] ?? 0)
            }
        }
        return out
    }

    private func last7DaysSeconds() -> [(label: String, secs: Int)] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        let map = store.secondsByDay()
        var out: [(String, Int)] = []
        for i in (0..<7).reversed() {
            if let d = cal.date(byAdding: .day, value: -i, to: Date()) {
                out.append((f.string(from: d), map[Fmt.dayKey(d)] ?? 0))
            }
        }
        return out
    }

    private func last7DaysPace() -> [(label: String, pace: Double)] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        var byDay: [String: (pages: Int, secs: Int)] = [:]
        for s in store.sessions where (s.pages ?? 0) > 0 && s.secs > 0 {
            let k = Fmt.dayKey(s.start)
            var v = byDay[k] ?? (0, 0)
            v.pages += s.pages ?? 0
            v.secs += s.secs
            byDay[k] = v
        }
        var out: [(String, Double)] = []
        for i in (0..<7).reversed() {
            if let d = cal.date(byAdding: .day, value: -i, to: Date()) {
                let v = byDay[Fmt.dayKey(d)] ?? (0, 0)
                let mins = max(1, v.secs / 60)
                let pace = v.pages == 0 ? 0 : Double(v.pages) / Double(mins)
                out.append((f.string(from: d), pace))
            }
        }
        return out
    }

    private func yearFinishedBooks() -> [Book] {
        let cal = Calendar.current
        let yr = cal.component(.year, from: Date())
        return store.books
            .filter { $0.finished && (cal.component(.year, from: $0.finishedAt ?? Date()) == yr) }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    private func exportBackup() {
        guard let data = try? store.makeBackupData() else { showToast("Backup failed"); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bookmark-backup.json")
        try? data.write(to: url, options: .atomic)
        ShareSheetPresenter.present([url])
    }

    private func exportCsv() {
        let csv = store.makeSessionsCSV()
        guard let data = csv.data(using: .utf8) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bookmark-sessions.csv")
        try? data.write(to: url, options: .atomic)
        ShareSheetPresenter.present([url])
    }

    private func saveToThisIPhone() {
        Task {
            if let msg = await AutoBackup.writeNow(store: store) {
                showToast(msg)
            } else {
                showToast("Couldn't save backup")
            }
            lastBackupStatus = AutoBackup.lastBackupStatus()
            backupRefreshTick &+= 1
        }
    }

    private func handleCsvImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                showToast("Could not read CSV file"); return
            }
            let r = SessionCSV.importCSV(data: data, into: store)
            var parts = ["\(r.added) added"]
            if r.updated > 0 { parts.append("\(r.updated) updated") }
            if r.skipped > 0 { parts.append("\(r.skipped) skipped") }
            showToast("CSV import complete · " + parts.joined(separator: " · "))
        case .failure(let err):
            showToast("CSV import failed: \(err.localizedDescription)")
        }
    }

    private func handleRestore(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let backup = BackupMigration.decode(data) else {
                    showToast("Backup file format not recognized")
                    return
                }
                store.restoreBackup(backup)
                showToast("Backup restored — \(backup.books.count) books, \(backup.sessions.count) sessions")
            } catch {
                showToast("Restore failed: \(error.localizedDescription)")
            }
        case .failure(let err):
            showToast("Restore failed: \(err.localizedDescription)")
        }
    }

    private func showToast(_ msg: String) {
        withAnimation(.easeOut(duration: 0.18)) { toastMessage = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(.easeIn(duration: 0.18)) { toastMessage = nil }
        }
    }
}

struct BarChart: View {
    let data: [(label: String, secs: Int)]
    let goalSeconds: Int

    private var maxSecs: Int {
        max(goalSeconds, data.map(\.secs).max() ?? 0, 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                GeometryReader { geo in
                    let goalY = geo.size.height * (1 - CGFloat(goalSeconds) / CGFloat(maxSecs))
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(data.enumerated()), id: \.offset) { _, d in
                            let h = max(3, geo.size.height * CGFloat(d.secs) / CGFloat(maxSecs))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(d.secs >= goalSeconds ? Theme.imsg : Theme.imsg.opacity(0.5))
                                .frame(height: h)
                                .frame(maxWidth: .infinity)
                                .opacity(d.secs == 0 ? 0.18 : 1)
                        }
                    }
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: goalY))
                        p.addLine(to: CGPoint(x: geo.size.width, y: goalY))
                    }
                    .stroke(Theme.gold.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
            HStack(spacing: 6) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, d in
                    Text(d.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.subtle)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct PaceChart: View {
    let data: [(label: String, pace: Double)]

    private var maxPace: Double {
        max(0.5, data.map(\.pace).max() ?? 0.5)
    }

    var body: some View {
        if data.allSatisfy({ $0.pace == 0 }) {
            VStack(spacing: 4) {
                Text("Not enough page data yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.subtle)
                Text("Add pages to your sessions to chart pace.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                GeometryReader { geo in
                    let pts = data.enumerated().map { (idx, d) -> CGPoint in
                        let x = data.count <= 1 ? geo.size.width / 2 : geo.size.width * CGFloat(idx) / CGFloat(data.count - 1)
                        let y = geo.size.height * (1 - CGFloat(d.pace / maxPace))
                        return CGPoint(x: x, y: y)
                    }
                    ZStack {
                        Path { p in
                            guard let first = pts.first else { return }
                            p.move(to: CGPoint(x: first.x, y: geo.size.height))
                            p.addLine(to: first)
                            for pt in pts.dropFirst() { p.addLine(to: pt) }
                            p.addLine(to: CGPoint(x: pts.last?.x ?? 0, y: geo.size.height))
                            p.closeSubpath()
                        }
                        .fill(Color(red: 0.13, green: 0.72, blue: 0.81).opacity(0.12))

                        Path { p in
                            guard let first = pts.first else { return }
                            p.move(to: first)
                            for pt in pts.dropFirst() { p.addLine(to: pt) }
                        }
                        .stroke(Color(red: 0.13, green: 0.72, blue: 0.81), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                        ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                            Circle()
                                .fill(Color(red: 0.13, green: 0.72, blue: 0.81))
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                                .position(pt)
                        }
                    }
                }
                HStack(spacing: 6) {
                    ForEach(Array(data.enumerated()), id: \.offset) { _, d in
                        Text(d.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.subtle)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

struct YearBooksCard: View {
    let books: [Book]
    let year: Int

    /// Mirrors the webapp's `YEARLY_BOOK_GOAL` constant.
    static let yearlyGoal = 10

    private var goalReached: Bool { books.count >= Self.yearlyGoal }
    private var statusText: String {
        goalReached ? "Yearly Goal Achieved" : "\(books.count) of \(Self.yearlyGoal) Books"
    }
    private var subText: String {
        if goalReached {
            return "\(books.count) book\(books.count == 1 ? "" : "s") finished — keep the streak going!"
        }
        let toGo = Self.yearlyGoal - books.count
        return "\(books.count) finished. \(toGo) to go."
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("\(String(year)) Reading")
                .font(.custom("Georgia-Bold", size: 20))
                .tracking(-0.2)

            if books.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Theme.subtle.opacity(0.4))
                    Text("No finished books in \(String(year)) yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.subtle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(54), spacing: 8), count: 4), spacing: 10) {
                    ForEach(books.prefix(11)) { bk in
                        ZStack(alignment: .bottomTrailing) {
                            BookCover(book: bk)
                                .frame(width: 54, height: 81)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
                            Circle().fill(Theme.imsg)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .heavy))
                                        .foregroundStyle(.white)
                                )
                                .offset(x: 6, y: 6)
                        }
                    }
                    if books.count > 11 {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.black.opacity(0.38))
                                .frame(width: 54, height: 81)
                            Text("+\(books.count - 11)")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                }
                VStack(spacing: 3) {
                    Text(statusText)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Theme.imsg)
                    Text(subText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtle)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }
}

struct DataAndBackupCard: View {
    let onExportBackup: () -> Void
    let onExportCsv: () -> Void
    let onRestore: () -> Void
    let onImportCsv: () -> Void
    let onAddManualSession: () -> Void
    let onSaveToIPhone: () -> Void
    let onChooseBackupFolder: () -> Void
    let onClearBackupFolder: () -> Void
    let backupFolderName: String?
    let lastBackupStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Data & Backup")
                .font(.system(size: 14, weight: .bold))

            backupFolderRow

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                actionButton("Export Backup", primary: true, action: onExportBackup)
                actionButton("Save to This iPhone", action: onSaveToIPhone)
                actionButton("Export CSV", action: onExportCsv)
                actionButton("Restore Backup", action: onRestore)
                actionButton("Import CSV", action: onImportCsv)
                actionButton("Add Manual Session", action: onAddManualSession)
            }
            VStack(spacing: 2) {
                if backupFolderName == nil {
                    Text("Local database active. Backups appear in Files › On My iPhone › BookMark.")
                } else {
                    Text("Pick a folder outside the app (e.g. iCloud Drive) so backups survive if you delete BookMark.")
                }
                Text(lastBackupStatus ?? "Never backed up yet.")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.subtle)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var backupFolderRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BACKUP FOLDER")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.subtle)
                Text(backupFolderName ?? "On My iPhone / BookMark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: onChooseBackupFolder) {
                Text(backupFolderName == nil ? "Choose…" : "Change")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
            }
            .buttonStyle(.plain)
            if backupFolderName != nil {
                Button(action: onClearBackupFolder) {
                    Text("Reset")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Theme.subtle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Theme.subtle.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
    }

    private func actionButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(primary ? .white : Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(primary ? Theme.accent : Theme.accent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
        }
        .buttonStyle(.plain)
    }
}
