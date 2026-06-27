import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct PublisherStat {
    var label: String
    var value: String
    var sub: String
}

struct StatsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showRestore = false
    @State private var showCsvImport = false
    @State private var showManualSession = false
    @State private var showWordsPerPageSettings = false
    @State private var showBackupFolderPicker = false
    @State private var showFolderPicker = false
    @State private var folderPickerPurpose: StatsFolderPickerPurpose = .rescan
    @State private var sessionsVisible = 10
    @State private var editingSession: ReadingSession?
    @State private var pendingDelete: ReadingSession?
    @State private var toastMessage: String?
    @State private var lastBackupStatus: String? = AutoBackup.lastBackupStatus()
    @State private var backupRefreshTick = 0
    @State private var publisherStatFlips: Set<String> = []
    @State private var showStatsTools = false
    @State private var showYearGoalEditor = false

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

                    YearBooksCard(
                        books: yearFinishedBooks(),
                        year: Calendar.current.component(.year, from: Date()),
                        goal: store.goal.booksPerYear,
                        onEditGoal: { showYearGoalEditor = true }
                    )
                        .padding(.horizontal, 16)

                    // Data & Backup moved into the Stats Tools sheet. Hidden on the
                    // Stats page for now — uncomment to bring the card back.
                    /*
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
                            showToast("Backups will save to On My iPhone / BookSmarts")
                        },
                        backupFolderName: store.backupFolderName,
                        lastBackupStatus: lastBackupStatus
                    )
                    .id(backupRefreshTick)
                    .padding(.horizontal, 16)
                    */

                    recentSessionsSection
                        .padding(.horizontal, 16)
                        .padding(.bottom, 96)
                }
                .readableContentWidth(hSizeClass == .regular ? 760 : .infinity)
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
                        .presentationDetents([.custom(TallerMediumDetent.self), .large])
                        .presentationDragIndicator(.hidden)
                        .glassSheetPresentation()
                }
        )
        .background(
            Color.clear
                .sheet(isPresented: $showStatsTools) {
                    statsToolsSheet
                        .presentationDetents([.large])
                        .glassSheetPresentation()
                }
        )
        .background(
            Color.clear
                .sheet(isPresented: $showWordsPerPageSettings) {
                    WordsPerPageSettingsSheet()
                        .presentationDetents([.height(385)])
                        .presentationBackground(Theme.background)
                }
        )
        .background(
            Color.clear
                .sheet(isPresented: $showYearGoalEditor) {
                    YearGoalEditorSheet()
                        .presentationDetents([.height(430)])
                        .glassSheetPresentation()
                }
        )
        .background(
            Color.clear
                .sheet(isPresented: $showFolderPicker) {
                    FolderPicker { url in
                        showFolderPicker = false
                        switch folderPickerPurpose {
                        case .rescan:
                            handleFolderRescan(url)
                        case .watch:
                            handleWatchedFolderSelection(url)
                        }
                    }
                }
        )
        .background(
            Color.clear
                .sheet(item: $editingSession) { s in
                    SessionEditorSheet(session: s)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.hidden)
                        .glassSheetPresentation()
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
            statsMenu
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background(Theme.background)
        .overlay(Divider().opacity(0.4), alignment: .bottom)
    }

    private var statsMenu: some View {
        Button {
            dismissKeyboard()
            showStatsTools = true
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel("Tools")
    }

    private var statsToolsSheet: some View {
        VStack(spacing: 0) {
            Grabber()
            Text("Tools")
                .font(.system(size: 16, weight: .heavy))
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 12) {
                    ActionGroup(translucent: true) {
                        statsBackupFolderRow
                    }

                    ActionGroup(translucent: true) {
                        statsToolRow("Words Per Page", systemImage: "textformat.size") {
                            showWordsPerPageSettings = true
                        }
                        statsToolRow("Rescan Folder", systemImage: "folder.badge.plus") {
                            folderPickerPurpose = .rescan
                            showFolderPicker = true
                        }
                        statsToolRow(store.watchedFolderName.map { "Watching: \($0)" } ?? "Watch Import Folder", systemImage: "folder.badge.gearshape") {
                            folderPickerPurpose = .watch
                            showFolderPicker = true
                        }
                        if store.watchedFolderName != nil {
                            statsToolRow("Stop Watching Folder", systemImage: "xmark.circle", role: .destructive) {
                                store.clearWatchedFolder()
                                showToast("Stopped watching folder")
                            }
                        }
                    }


                    Text("Data & Backup")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.subtle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .padding(.horizontal, 4)

                    ActionGroup(translucent: true) {
                        statsToolRow("Export Backup", systemImage: "arrow.down.doc", action: exportBackup)
                        statsToolRow("Save to This iPhone", systemImage: "iphone.gen2", action: saveToThisIPhone)
                        statsToolRow("Export CSV", systemImage: "tablecells", action: exportCsv)
                        statsToolRow("Restore Backup", systemImage: "arrow.up.doc") { showRestore = true }
                        statsToolRow("Import CSV", systemImage: "square.and.arrow.down") { showCsvImport = true }
                        statsToolRow("Add Manual Session", systemImage: "plus.rectangle.on.folder") { showManualSession = true }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
        }
    }


    private func statsToolRow(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role) {
            runStatsToolAction(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer()
            }
            .foregroundStyle(role == .destructive ? Theme.danger : Theme.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Divider().padding(.leading, 50), alignment: .bottom)
    }

    /// Backup-folder chooser shown at the top of the Stats Tools sheet. Mirrors
    /// the row that used to live in the (now hidden) Data & Backup card.
    private var statsBackupFolderRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BACKUP FOLDER")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.subtle)
                Text(store.backupFolderName ?? "On My iPhone / BookSmarts")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                runStatsToolAction { showBackupFolderPicker = true }
            } label: {
                Text(store.backupFolderName == nil ? "Choose…" : "Change")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
            }
            .buttonStyle(.plain)
            if store.backupFolderName != nil {
                Button {
                    runStatsToolAction {
                        store.clearBackupFolder()
                        showToast("Backups will save to On My iPhone / BookSmarts")
                    }
                } label: {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func runStatsToolAction(_ action: @escaping () -> Void) {
        dismissKeyboard()
        showStatsTools = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            action()
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var statsGrid: some View {
        let totalSecs = store.sessions.reduce(0) { $0 + $1.secs }
        let finishedCount = store.books.filter(\.finished).count
        let avgSession = store.sessions.isEmpty ? 0 : totalSecs / store.sessions.count
        let weekSecs = lastNDaysSeconds(7).reduce(0, +)
        // Swipe-page stats (the default face of the four page cards).
        let totalPages = store.sessions.reduce(0) { $0 + ($1.pages ?? 0) }
        let pageSessions = store.sessions.filter { ($0.pages ?? 0) > 0 }
        let avgPages = pageSessions.isEmpty ? 0 : totalPages / pageSessions.count
        let weekPages = lastNDaysPages(7).reduce(0, +)
        let paceTotalMins = max(1, pageSessions.reduce(0) { $0 + $1.secs }) / 60
        let avgPace = pageSessions.isEmpty ? 0.0 : Double(pageSessions.reduce(0) { $0 + ($1.pages ?? 0) }) / Double(paceTotalMins)
        // Word-based stats use actual EPUB word counts where available,
        // then each session's hidden words-per-page snapshot, then the current fallback.
        let wordsPerPage = store.resolvedWordsPerPageForCurrentDevice()
        let estimatedWordSessions = store.sessions.filter { estimatedWords(for: $0, wordsPerPage: wordsPerPage) > 0 }
        let totalWords = estimatedWordSessions.reduce(0) { $0 + estimatedWords(for: $1, wordsPerPage: wordsPerPage) }
        let avgWords = estimatedWordSessions.isEmpty ? 0 : totalWords / estimatedWordSessions.count
        let weekWords = lastNDaysEstimatedWords(7, wordsPerPage: wordsPerPage).reduce(0, +)
        let totalStdPages = EPUBWordCounter.standardizedPages(forWords: totalWords, wordsPerPage: wordsPerPage)
        let avgStdPages = EPUBWordCounter.standardizedPages(forWords: avgWords, wordsPerPage: wordsPerPage)
        let weekStdPages = EPUBWordCounter.standardizedPages(forWords: weekWords, wordsPerPage: wordsPerPage)
        let wpmSamples = store.sessions.compactMap { session in
            session.wordsPerMinute.flatMap { $0 > 0 ? $0 : nil }
        }
        let avgWPM = wpmSamples.isEmpty ? 0.0 : wpmSamples.reduce(0, +) / Double(wpmSamples.count)
        let wordSessionSeconds = estimatedWordSessions.reduce(0) { $0 + $1.secs }
        let avgStdPace = wordSessionSeconds > 0
            ? (Double(totalWords) / Double(wordsPerPage)) / (Double(wordSessionSeconds) / 60.0)
            : 0.0

        return LazyVGrid(columns: Layout.statsGridColumns(for: hSizeClass), spacing: 12) {
            statCard(label: "Total Read", value: Fmt.duration(totalSecs), sub: "all time", green: true)
            statCard(label: "Finished", value: "\(finishedCount)", sub: "books completed")
            // Time card flips between week total (default) and avg session.
            statCard(
                id: "session-week-flip",
                label: "This Week",
                value: Fmt.duration(weekSecs),
                sub: "last 7 days",
                publisher: PublisherStat(label: "Avg Session", value: Fmt.duration(avgSession), sub: "per session")
            )
            // Page cards: default = swipe-page count (device-dependent),
            // flip = standardized pages (device-independent, ~300w each).
            statCard(
                id: "total-pages",
                label: "Total Pages",
                value: "\(totalPages)",
                sub: "all time",
                publisher: PublisherStat(label: "Std Pages", value: "\(totalStdPages)", sub: "~\(wordsPerPage)w/page")
            )
            statCard(
                id: "avg-pages",
                label: "Avg Pages",
                value: "\(avgPages)",
                sub: "per session",
                publisher: PublisherStat(label: "Avg Std Pages", value: "\(avgStdPages)", sub: "per session")
            )
            statCard(
                id: "week-pages",
                label: "Pages This Week",
                value: "\(weekPages)",
                sub: "last 7 days",
                publisher: PublisherStat(label: "Std Pages Week", value: "\(weekStdPages)", sub: "last 7 days")
            )
            statCard(
                id: "avg-pace",
                label: "Avg Pace",
                value: String(format: "%.2f", avgPace),
                sub: "device pages/min",
                publisher: PublisherStat(label: "Avg Pace", value: String(format: "%.2f", avgStdPace), sub: "std pages/min")
            )
            statCard(label: "Avg WPM", value: String(format: "%.0f", avgWPM), sub: "words/min")
        }
    }

    private func statCard(
        id: String? = nil,
        label: String,
        value: String,
        sub: String,
        green: Bool = false,
        publisher: PublisherStat? = nil
    ) -> some View {
        let isPublisher = id.map { publisherStatFlips.contains($0) } ?? false
        let activeLabel = isPublisher ? (publisher?.label ?? label) : label
        let activeValue = isPublisher ? (publisher?.value ?? value) : value
        let activeSub = isPublisher ? (publisher?.sub ?? sub) : sub

        return statCardFace(
            label: activeLabel,
            value: activeValue,
            sub: activeSub,
            green: green,
            isPublisher: isPublisher
        )
        .rotation3DEffect(.degrees(isPublisher ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: isPublisher)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .onTapGesture {
            guard let id, publisher != nil else { return }
            if publisherStatFlips.contains(id) {
                publisherStatFlips.remove(id)
            } else {
                publisherStatFlips.insert(id)
            }
        }
    }

    private func statCardFace(label: String, value: String, sub: String, green: Bool, isPublisher: Bool) -> some View {
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
        .scaleEffect(x: isPublisher ? -1 : 1, y: 1)
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
                HStack(spacing: 8) {
                    if let pages = s.pages, pages > 0 {
                        Text("\(pages) page\(pages == 1 ? "" : "s")")
                    }
                    if let wpm = s.wordsPerMinute, wpm > 0 {
                        Text("\(Int(ceil(wpm))) WPM")
                    }
                }
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Theme.accent)
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

    private func lastNDaysEstimatedWords(_ n: Int, wordsPerPage: Int) -> [Int] {
        let cal = Calendar.current
        var map: [String: Int] = [:]
        for s in store.sessions {
            map[Fmt.dayKey(s.start), default: 0] += estimatedWords(for: s, wordsPerPage: wordsPerPage)
        }
        var out: [Int] = []
        for i in (0..<n).reversed() {
            if let d = cal.date(byAdding: .day, value: -i, to: Date()) {
                out.append(map[Fmt.dayKey(d)] ?? 0)
            }
        }
        return out
    }

    private func estimatedWords(for session: ReadingSession, wordsPerPage: Int) -> Int {
        session.resolvedWordsRead(fallbackWordsPerPage: wordsPerPage)
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
            .sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }

    private func handleFolderRescan(_ url: URL) {
        Task {
            let summary = await EPUBImporter.rescanFolder(url, into: store)
            showToast(importSummaryMessage(summary, empty: "No EPUBs found"))
        }
    }

    private func handleWatchedFolderSelection(_ url: URL) {
        do {
            try store.setWatchedFolder(url)
        } catch {
            showToast("Couldn't watch that folder")
            return
        }
        Task {
            let summary = await EPUBImporter.rescanFolder(url, into: store)
            let name = store.watchedFolderName ?? "folder"
            showToast(importSummaryMessage(summary, empty: "Watching \(name)"))
        }
    }

    private func importSummaryMessage(_ summary: EPUBImporter.ImportSummary, empty: String) -> String {
        var parts: [String] = []
        if summary.added > 0 { parts.append("Added \(summary.added)") }
        if summary.relinked > 0 { parts.append("relinked \(summary.relinked)") }
        if summary.skipped > 0 { parts.append("skipped \(summary.skipped)") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        return parts.isEmpty ? empty : parts.joined(separator: ", ")
    }

    private func exportBackup() {
        let backup = store.makeBackup()
        Task {
            do {
                let data = try await StorePersistence.shared.backupData(backup, prettyPrinted: true)
                let url = try await StorePersistence.shared.writeTemporaryFile(data: data, filename: "bookmark-backup.json")
                ShareSheetPresenter.present([url])
            } catch {
                showToast("Backup failed")
            }
        }
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
                let restoredMessage = "Backup restored — \(backup.books.count) books, \(backup.sessions.count) sessions"
                if let watchedFolder = store.resolveWatchedFolder() {
                    showToast("\(restoredMessage). Linking EPUBs…")
                    Task {
                        let summary = await EPUBImporter.rescanFolder(watchedFolder, into: store)
                        showToast("\(restoredMessage) · \(importSummaryMessage(summary, empty: "No EPUBs linked"))")
                    }
                } else {
                    showToast(restoredMessage)
                }
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

private enum StatsFolderPickerPurpose {
    case rescan
    case watch
}

private struct WordsPerPageSettingsSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var mode: WordsPerPageMode = .manual
    @State private var wordsPerPage = ReaderSettings.defaultWordsPerPageForCurrentDevice

    private var autoValue: Int? {
        store.automaticWordsPerPageEstimate()
    }

    private var displayedWordsPerPage: Int {
        mode == .automatic ? (autoValue ?? wordsPerPage) : wordsPerPage
    }

    private var valueLabel: String {
        mode == .automatic && autoValue != nil ? "auto words" : "words"
    }

    var body: some View {
        VStack(spacing: 14) {
            Grabber()
                .padding(.bottom, 0)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Words Per Page")
                        .font(.system(size: 17, weight: .heavy))
                    Text(ReaderSettings.currentDeviceName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.subtle)
                }
                Spacer()
                Button("Default") {
                    mode = .manual
                    wordsPerPage = ReaderSettings.defaultWordsPerPageForCurrentDevice
                }
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Theme.accent)
            }

            Picker("Words Per Page Mode", selection: $mode) {
                Text("Auto").tag(WordsPerPageMode.automatic)
                Text("Manual").tag(WordsPerPageMode.manual)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button {
                    wordsPerPage = max(50, wordsPerPage - 10)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(width: 42, height: 42)
                        .background(Theme.subtle.opacity(mode == .manual ? 0.12 : 0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(mode == .automatic)
                .opacity(mode == .automatic ? 0.45 : 1)

                VStack(spacing: 2) {
                    Text("\(displayedWordsPerPage)")
                        .font(.system(size: 36, weight: .heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(valueLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.subtle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))

                Button {
                    wordsPerPage = min(2_000, wordsPerPage + 10)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .heavy))
                        .frame(width: 42, height: 42)
                        .background(Theme.subtle.opacity(mode == .manual ? 0.12 : 0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(mode == .automatic)
                .opacity(mode == .automatic ? 0.45 : 1)
            }
            .foregroundStyle(Theme.text)

            HStack(spacing: 10) {
                Button("Cancel") {
                    dismiss()
                }
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))

                Button("Save Changes") {
                    save()
                }
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(Theme.background)
        .onAppear {
            mode = store.readerSettings.wordsPerPageMode
            wordsPerPage = store.readerSettings.wordsPerPageForCurrentDevice
        }
    }

    private func save() {
        store.readerSettings.wordsPerPageMode = mode
        store.readerSettings.setWordsPerPageForCurrentDevice(wordsPerPage)
        store.scheduleSave()
        dismiss()
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
    /// User's yearly books-read target (editable via the Edit Goal button).
    let goal: Int
    var onEditGoal: () -> Void = {}
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var goalReached: Bool { books.count >= goal }
    private var statusText: String {
        goalReached ? "Yearly Goal Achieved" : "\(books.count) of \(goal) Books"
    }
    private var subText: String {
        if goalReached {
            return "\(books.count) book\(books.count == 1 ? "" : "s") finished — keep the streak going!"
        }
        let toGo = goal - books.count
        return "\(books.count) finished. \(toGo) to go."
    }

    // Layout proportions are size-class aware: iPhone gets the original
    // 4-column / 54pt thumbnails; iPad uses 6 wider columns so the section
    // breathes into the wider canvas instead of looking like tiny postage
    // stamps in the middle of all that white space.
    private var coverWidth: CGFloat { hSizeClass == .regular ? 96 : 54 }
    private var coverHeight: CGFloat { coverWidth * 1.5 }
    private var columnCount: Int { 6 }

    /// iPad keeps fixed-width thumbnails; iPhone uses flexible columns so the six
    /// covers stretch to fill the card width instead of leaving blank space.
    private var gridColumns: [GridItem] {
        hSizeClass == .regular
            ? Array(repeating: GridItem(.fixed(coverWidth), spacing: 8), count: columnCount)
            : Array(repeating: GridItem(.flexible(), spacing: 6), count: columnCount)
    }

    /// Sizes a cover/placeholder to a fixed thumbnail on iPad, or to fill the
    /// flexible column at a 2:3 aspect ratio on iPhone.
    @ViewBuilder
    private func coverSized(_ content: some View) -> some View {
        if hSizeClass == .regular {
            content.frame(width: coverWidth, height: coverHeight)
        } else {
            content.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(maxWidth: .infinity)
        }
    }
    private var badgeSize: CGFloat { hSizeClass == .regular ? 32 : 22 }
    private var badgeIconSize: CGFloat { hSizeClass == .regular ? 15 : 11 }
    private var coverCornerRadius: CGFloat { hSizeClass == .regular ? 6 : 4 }

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
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    ForEach(books) { bk in
                        ZStack(alignment: .bottomTrailing) {
                            coverSized(BookCover(book: bk))
                                .clipShape(RoundedRectangle(cornerRadius: coverCornerRadius))
                                .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
                            Circle().fill(Theme.imsg)
                                .frame(width: badgeSize, height: badgeSize)
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .font(.system(size: badgeIconSize, weight: .heavy))
                                        .foregroundStyle(.white)
                                )
                                .offset(x: badgeSize * 0.27, y: badgeSize * 0.27)
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

            Button(action: onEditGoal) {
                HStack(spacing: 6) {
                    Image(systemName: "target")
                    Text("Edit Goal")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 8)
                .padding(.horizontal, 18)
                .background(Theme.accent.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
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
                    Text("Local database active. Backups appear in Files › On My iPhone › BookSmarts.")
                } else {
                    Text("Pick a folder outside the app (e.g. iCloud Drive) so backups survive if you delete BookSmarts.")
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
                Text(backupFolderName ?? "On My iPhone / BookSmarts")
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
