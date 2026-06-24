import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showImporter = false
    @State private var bookActionTarget: Book?
    @State private var detailTarget: Book?
    @State private var finishTarget: Book?
    @State private var editSeriesTarget: Book?
    @State private var seriesMode = false
    @State private var activeDropBookID: String?
    @State private var draggingBookIDs: [String] = []
    @State private var toastMessage: String?

    let onOpenBook: (String) -> Void
    var onOpenJournal: () -> Void = {}

    private var columns: [GridItem] {
        Layout.libraryGridColumns(for: hSizeClass)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    if let bk = store.continueBook() {
                        ContinueReadingCard(
                            book: bk,
                            pct: store.progress[bk.id]?.pct ?? 0,
                            totalSeconds: store.sessionsForBook(bk).reduce(0) { $0 + $1.secs }
                        )
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 10)
                            .onTapGesture { onOpenBook(bk.id) }
                    }
                    statsStrip
                        .padding(.horizontal, 16)
                        .padding(.top, store.continueBook() == nil ? 16 : 6)
                        .padding(.bottom, 18)

                    if store.books.isEmpty {
                        emptyState
                    } else {
                        sectionHeader
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        if seriesMode {
                            seriesGroupedContent
                        } else {
                            grid
                        }
                    }
                }
                .readableContentWidth(hSizeClass == .regular ? 1000 : .infinity)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
        }
        .sheet(item: $bookActionTarget) { book in
            BookActionsSheet(
                book: book,
                onContinue: { onOpenBook(book.id); bookActionTarget = nil },
                onFinish: { finishTarget = book; bookActionTarget = nil },
                onDetails: { detailTarget = book; bookActionTarget = nil },
                onEditSeries: { editSeriesTarget = book; bookActionTarget = nil },
                onRemove: { store.removeBook(id: book.id); bookActionTarget = nil; toast("Book removed") }
            )
            .presentationDetents([.height(410)])
            .glassSheetPresentation()
        }
        .sheet(item: $detailTarget) { book in
            BookDetailsSheet(book: book, orderedIDs: currentOrderIDs)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $editSeriesTarget) { book in
            EditSeriesSheet(book: book)
                .presentationDetents([.medium])
                .glassSheetPresentation()
        }
        .sheet(item: $finishTarget) { book in
            FinishDateSheet(book: book) {
                toast(book.finished ? "Marked unfinished" : "Finished date saved")
            }
            .presentationDetents([.medium])
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                ToastView(text: toastMessage)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("BookMark")
                .font(.system(size: 23, weight: .heavy))
                .tracking(-0.5)
            Spacer()
            Button(action: onOpenJournal) {
                HomeGoalRing(
                    minutes: Fmt.minutes(store.todaySeconds()),
                    goal: max(1, store.goal.minutes)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Journal")
            Button { showImporter = true } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background(Theme.background)
        .overlay(Divider().opacity(0.4), alignment: .bottom)
    }

    private var statsStrip: some View {
        HStack(spacing: 10) {
            statCard(value: "\(store.books.count)", label: "Books")
            statCard(value: Fmt.duration(store.sessions.reduce(0) { $0 + $1.secs }), label: "Read")
            statCard(value: "\(store.currentStreak())", label: "Day Streak")
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.subtle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .smallCardStyle()
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Your Library")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.subtle)
                Spacer()
                if store.hasAnySeries {
                    viewModeToggle
                }
            }
            if let status = store.libraryPaginationStatus {
                progressLine(status.text)
            }
            if let series = store.librarySeriesStatus {
                progressLine(series.text)
            }
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(store.sortedBooks()) { book in
                    BookCard(book: book, progress: store.progress[book.id])
                        .scaleEffect(draggingBookIDs.contains(book.id) ? 1.025 : 1)
                        .shadow(
                            color: draggingBookIDs.contains(book.id) ? .black.opacity(0.22) : .clear,
                            radius: draggingBookIDs.contains(book.id) ? 14 : 0,
                            y: draggingBookIDs.contains(book.id) ? 8 : 0
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerLarge)
                                .stroke(activeDropBookID == book.id ? Theme.accent : Color.clear, lineWidth: 2)
                        )
                        .overlay(alignment: .leading) {
                            if activeDropBookID == book.id {
                                LibraryDropInsertionMarker()
                                    .offset(x: -7)
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
                        .onTapGesture {
                            onOpenBook(book.id)
                        }
                        .onDrag {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            draggingBookIDs = [book.id]
                            return NSItemProvider(object: book.id as NSString)
                        } preview: {
                            LibraryDragPreview(book: book)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: LibraryBookDropDelegate(
                                targetBook: book,
                                activeDropBookID: $activeDropBookID,
                                draggingBookIDs: $draggingBookIDs,
                                store: store
                            )
                        )
                        .overlay(alignment: .topTrailing) {
                            Button {
                                bookActionTarget = book
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 13, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                            }
                            .padding(7)
                        }
                }
            }

            Color.clear
                .frame(height: 36)
                .contentShape(Rectangle())
                .onDrop(
                    of: [.text],
                    delegate: LibraryEndDropDelegate(
                        activeDropBookID: $activeDropBookID,
                        draggingBookIDs: $draggingBookIDs,
                        store: store
                    )
                )
        }
        .padding(.horizontal, 16)
    }
    /// Book IDs in the order currently shown on screen, so Book Details' prev/
    /// next steps through the same sequence the user is looking at — flat library
    /// order in All Books, grouped order (series then standalone) in By Series.
    private var currentOrderIDs: [String] {
        if seriesMode {
            let groups = store.seriesGroups()
            return groups.series.flatMap { $0.books.map(\.id) } + groups.standalone.map(\.id)
        }
        return store.sortedBooks().map(\.id)
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.subtle)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityLabel(text)
    }

    private var viewModeToggle: some View {
        HStack(spacing: 2) {
            modePill(title: "All", active: !seriesMode) { seriesMode = false }
            modePill(title: "Series", active: seriesMode) { seriesMode = true }
        }
        .padding(2)
        .background(Theme.card)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
    }

    private func modePill(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(active ? .white : Theme.subtle)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(active ? Theme.accent : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Books grouped under series headers, with standalones gathered at the
    /// bottom. Reordering isn't offered here — order follows series position.
    private var seriesGroupedContent: some View {
        let groups = store.seriesGroups()
        return VStack(alignment: .leading, spacing: 22) {
            ForEach(groups.series) { group in
                VStack(alignment: .leading, spacing: 10) {
                    seriesGroupHeader(title: group.name, count: group.books.count)
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(group.books) { book in
                            seriesTile(book, showBadge: true)
                        }
                    }
                }
            }
            if !groups.standalone.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    seriesGroupHeader(title: "Standalone", count: groups.standalone.count)
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(groups.standalone) { book in
                            seriesTile(book, showBadge: false)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func seriesGroupHeader(title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.subtle)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.card)
                .clipShape(Capsule())
            Spacer()
        }
    }

    private func seriesTile(_ book: Book, showBadge: Bool) -> some View {
        BookCard(
            book: book,
            progress: store.progress[book.id],
            seriesBadge: showBadge ? book.seriesIndexBadge : nil
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .onTapGesture { onOpenBook(book.id) }
        .overlay(alignment: .topTrailing) { moreButton(book) }
    }

    private func moreButton(_ book: Book) -> some View {
        Button {
            bookActionTarget = book
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
        .padding(7)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.subtle.opacity(0.4))
            Text("Your library is empty")
                .font(.system(size: 18, weight: .bold))
            Text("Add an EPUB file to start reading and tracking your progress.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.subtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                showImporter = true
            } label: {
                Text("Add Your First Book")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall))
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 52)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private func toast(_ msg: String) {
        withAnimation(.easeOut(duration: 0.18)) { toastMessage = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(.easeIn(duration: 0.18)) { toastMessage = nil }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                let summary = await EPUBImporter.importFiles(urls, into: store)
                toast(importSummaryMessage(summary, empty: "No EPUBs imported"))
            }
        case .failure(let err):
            toast("Import failed: \(err.localizedDescription)")
        }
    }

    private func handleFolderRescan(_ url: URL) {
        Task {
            let summary = await EPUBImporter.rescanFolder(url, into: store)
            toast(importSummaryMessage(summary, empty: "No EPUBs found"))
        }
    }

    private func handleWatchedFolderSelection(_ url: URL) {
        do {
            try store.setWatchedFolder(url)
        } catch {
            toast("Couldn't watch that folder")
            return
        }
        Task {
            let summary = await EPUBImporter.rescanFolder(url, into: store)
            let name = store.watchedFolderName ?? "folder"
            toast(importSummaryMessage(summary, empty: "Watching \(name)"))
        }
    }

    private func importSummaryMessage(_ summary: EPUBImporter.ImportSummary, empty: String) -> String {
        var parts: [String] = []
        if summary.added > 0 {
            parts.append("Added \(summary.added)")
        }
        if summary.relinked > 0 {
            parts.append("relinked \(summary.relinked)")
        }
        if summary.skipped > 0 {
            parts.append("skipped \(summary.skipped)")
        }
        if summary.failed > 0 {
            parts.append("\(summary.failed) failed")
        }
        return parts.isEmpty ? empty : parts.joined(separator: ", ")
    }

    private func exportBackup() {
        guard let data = try? store.makeBackupData() else { toast("Backup failed"); return }
        share(data: data, filename: "bookmark-backup.json", uti: "public.json")
    }

    private func exportCsv() {
        let csv = store.makeSessionsCSV()
        guard let data = csv.data(using: .utf8) else { return }
        share(data: data, filename: "bookmark-sessions.csv", uti: "public.comma-separated-values-text")
    }

    private func share(data: Data, filename: String, uti: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: url, options: .atomic)
        ShareSheetPresenter.present([url])
    }
}


private struct LibraryBookDropDelegate: DropDelegate {
    let targetBook: Book
    @Binding var activeDropBookID: String?
    @Binding var draggingBookIDs: [String]
    let store: Store

    func dropEntered(info: DropInfo) {
        guard !draggingBookIDs.isEmpty, !draggingBookIDs.contains(targetBook.id) else { return }
        activeDropBookID = targetBook.id
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            store.moveBookIDs(draggingBookIDs, before: targetBook.id)
        }
    }

    func dropExited(info: DropInfo) {
        if activeDropBookID == targetBook.id {
            activeDropBookID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        activeDropBookID = nil
        if !draggingBookIDs.isEmpty {
            draggingBookIDs = []
            return true
        }
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let raw = obj as? String else { return }
            let ids = raw
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty && $0 != targetBook.id }
            Task { @MainActor in
                guard !ids.isEmpty else { return }
                store.moveBookIDs(ids, before: targetBook.id)
            }
        }
        return true
    }
}

private struct LibraryEndDropDelegate: DropDelegate {
    @Binding var activeDropBookID: String?
    @Binding var draggingBookIDs: [String]
    let store: Store

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        activeDropBookID = nil
        if !draggingBookIDs.isEmpty {
            store.moveBookIDsToEnd(draggingBookIDs)
            draggingBookIDs = []
            return true
        }
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let raw = obj as? String else { return }
            let ids = raw
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
            Task { @MainActor in
                store.moveBookIDsToEnd(ids)
            }
        }
        return true
    }
}

private struct LibraryDropInsertionMarker: View {
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 9, height: 9)
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.accent)
                .frame(width: 4)
            Circle()
                .fill(Theme.accent)
                .frame(width: 9, height: 9)
        }
        .frame(width: 14)
        .padding(.vertical, 8)
        .shadow(color: Theme.accent.opacity(0.35), radius: 6)
    }
}

private struct LibraryDragPreview: View {
    let book: Book

    var body: some View {
        BookCover(book: book)
            .frame(width: 86, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        .padding(12)
    }
}

struct BookCover: View {
    let book: Book

    var body: some View {
        ZStack {
            if let data = book.coverData, let ui = UIImage(data: data) {
                // Plain .resizable() (no .scaledToFit/Fill) stretches the image
                // to exactly fill the cover frame, so every book renders at the
                // same 2:3 silhouette regardless of the source artwork's ratio.
                Image(uiImage: ui).resizable()
            } else {
                CoverGradient.gradient(for: book.id)
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipped()
    }
}

struct BookCard: View {
    let book: Book
    let progress: ReadingProgress?
    var seriesBadge: String? = nil
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                BookCover(book: book)
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                if book.finished {
                    HStack(spacing: 3) {
                        Text("✓")
                        Text("READ")
                    }
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.gold)
                    .clipShape(Capsule())
                    .padding(7)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let seriesBadge {
                    Text(seriesBadge)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                        .padding(7)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.92)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
                Text(book.author)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.94)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.border)
                            .frame(height: 3)
                        Capsule().fill(Theme.accent)
                            .frame(width: geo.size.width * pct, height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.top, 2)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(statusText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.subtle)
                    Spacer()
                    if totalSecs > 0 {
                        Text(Fmt.duration(totalSecs))
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(book.defaultLibraryPaginationText ?? " ")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Always reserve the date-range line (use a space when empty)
                // so every card lays out at the same height in the 2-column
                // grid, even when some books have no sessions yet.
                Text(dateRangeText ?? " ")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .cardStyle()
    }

    private var pct: CGFloat {
        let p = progress?.pct ?? 0
        return CGFloat(max(0, min(1, p)))
    }
    private var statusText: String {
        if book.finished { return "Finished" }
        let n = Int((progress?.pct ?? 0) * 100)
        return n == 0 ? "Not started" : "\(n)%"
    }
    private var totalSecs: Int {
        store.sessionsForBook(book).reduce(0) { $0 + $1.secs }
    }
    private var dateRangeText: String? {
        let s = store.sessionsForBook(book).sorted { $0.start < $1.start }
        guard let first = s.first?.start, let last = (s.last?.end ?? s.last?.start) else { return nil }
        return Fmt.dateRange(first, last)
    }
}

struct ContinueReadingCard: View {
    let book: Book
    let pct: Double
    let totalSeconds: Int

    var body: some View {
        HStack(spacing: 12) {
            BookCover(book: book)
                .frame(width: 42, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("CONTINUE READING")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Theme.accent)
                Text(book.title)
                    .font(.system(size: 15, weight: .heavy))
                    .lineLimit(1)
                Text("\(book.author) · \(Int(pct * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
                    .lineLimit(1)
                Text("Total read: \(Fmt.duration(totalSeconds))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.subtle)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.subtle)
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [Theme.accent.opacity(0.18), Theme.gold.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .background(Theme.card)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 2)
    }
}

struct HomeGoalRing: View {
    let minutes: Int
    let goal: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.24), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, Double(minutes) / Double(max(1, goal)))))
                .stroke(Theme.imsg, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(min(999, minutes))")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Theme.imsg)
                Text("\(goal)")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Theme.subtle)
            }
        }
        .frame(width: 42, height: 42)
        .background(Theme.card.clipShape(Circle()))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.9))
            .clipShape(Capsule())
    }
}

enum ShareSheetPresenter {
    static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(vc, animated: true)
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let dismiss: DismissAction

        init(onPick: @escaping (URL) -> Void, dismiss: DismissAction) {
            self.onPick = onPick
            self.dismiss = dismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { dismiss(); return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            dismiss()
        }
    }
}
