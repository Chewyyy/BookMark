import SwiftUI
import UIKit

struct LibraryPaginationQueueView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.scenePhase) private var scenePhase

    let priorityBookID: String?

    @State private var activeBookID: String?
    @State private var pendingChapterJump: ReadiumChapterJump?
    @State private var navigatorReady = false
    @State private var targetChapter: Int?
    @State private var timeoutTask: Task<Void, Never>?
    @State private var pagesPerChapter: [Int] = []
    @State private var measuredIndexes: Set<Int> = []
    @State private var chaptersToMeasure: [Int] = []
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private var settings: ReaderSettings {
        var settings = ReaderSettings()
        settings.pageCountMode = .paginatedBook
        settings.keepAwake = false
        settings.pageAnim = .none
        return settings
    }

    private var activeBook: Book? {
        guard let activeBookID else { return nil }
        return store.books.first { $0.id == activeBookID }
    }

    private var activeURL: URL? {
        guard let fileName = activeBook?.fileName else { return nil }
        let url = Store.epubsDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        ZStack {
            if let activeURL, activeBook != nil {
                ReadiumReaderContainer(
                    epubURL: activeURL,
                    settings: settings,
                    initialProgress: 0,
                    pendingLocatorJSON: nil,
                    pendingChapterJump: pendingChapterJump,
                    diagnosticPageTurnRequest: nil,
                    highlights: [],
                    onLocationChange: { _ in },
                    onChapterPageChange: handleChapterPageState,
                    onPageTurn: { _ in },
                    onCenterTap: {},
                    onHighlightSelection: { _, _ in },
                    onPublicationReady: { publication in
                        guard publication != nil else { return }
                        navigatorReady = true
                        if targetChapter == nil {
                            advance()
                        }
                    },
                    onDiagnosticPageTurnResult: { _ in }
                )
                .ignoresSafeArea()
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            scheduleNextIfNeeded()
        }
        .onDisappear {
            stopActiveJob(cancelled: true)
        }
        .onChange(of: store.didHydrate) { _, _ in
            scheduleNextIfNeeded()
        }
        .onChange(of: store.books) { _, _ in
            if activeBookID != nil, activeBook == nil {
                stopActiveJob(cancelled: true)
            }
            scheduleNextIfNeeded()
        }
        .onChange(of: priorityBookID) { _, _ in
            scheduleNextIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                scheduleNextIfNeeded()
            case .background:
                beginBackgroundTaskIfNeeded()
            case .inactive:
                persistCurrentSettings()
            @unknown default:
                persistCurrentSettings()
            }
        }
    }

    private func scheduleNextIfNeeded() {
        guard store.didHydrate, activeBookID == nil else { return }
        guard let book = nextBookNeedingPagination() else {
            store.libraryPaginationStatus = nil
            return
        }
        start(book: book)
    }

    private func nextBookNeedingPagination() -> Book? {
        if let priorityBookID,
           let priorityBook = store.books.first(where: { $0.id == priorityBookID }),
           needsDefaultLibraryPagination(priorityBook) {
            return priorityBook
        }

        return store.sortedBooks().first(where: needsDefaultLibraryPagination)
    }

    private func needsDefaultLibraryPagination(_ book: Book) -> Bool {
        guard book.fileName != nil,
              store.epubFileExists(for: book),
              let counts = book.wordCountsPerSpine,
              !counts.isEmpty
        else {
            return false
        }
        return !book.hasCompleteDefaultLibraryPagination
    }

    private func start(book: Book) {
        let chapterCount = book.wordCountsPerSpine?.count ?? 0
        guard chapterCount > 0 else { return }

        timeoutTask?.cancel()
        activeBookID = book.id
        navigatorReady = false
        targetChapter = nil
        pendingChapterJump = nil

        let cached = book.paginationCache?[PaginationKey.defaultLibraryKey]
        var pages = cached?.pagesPerChapter ?? Array(repeating: 1, count: chapterCount)
        if pages.count != chapterCount {
            pages = Array(repeating: 1, count: chapterCount)
        }

        var measured = Set(cached?.measuredChapterIndexes ?? [])
        if measured.isEmpty, let measuredChapterIndex = cached?.measuredChapterIndex, measuredChapterIndex >= 0 {
            measured.insert(measuredChapterIndex)
        }
        measured = measured.filter { $0 >= 0 && $0 < chapterCount }

        pagesPerChapter = pages
        measuredIndexes = measured
        chaptersToMeasure = (0..<chapterCount).filter { !measured.contains($0) }
        updateStatus(for: book)

        guard !chaptersToMeasure.isEmpty else {
            stopActiveJob(cancelled: false)
            return
        }

        beginBackgroundTaskIfNeeded()
    }

    private func advance() {
        timeoutTask?.cancel()
        guard activeBookID != nil, navigatorReady else { return }

        guard let chapterIndex = chaptersToMeasure.first else {
            stopActiveJob(cancelled: false)
            scheduleNextAfterYield()
            return
        }

        targetChapter = chapterIndex
        pendingChapterJump = ReadiumChapterJump(chapterIndex: chapterIndex)
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard activeBookID != nil,
                  targetChapter == chapterIndex,
                  chaptersToMeasure.first == chapterIndex
            else { return }

            if pagesPerChapter.indices.contains(chapterIndex) {
                pagesPerChapter[chapterIndex] = max(1, pagesPerChapter[chapterIndex])
            }
            measuredIndexes.insert(chapterIndex)
            chaptersToMeasure.removeFirst()
            persistCurrentSettings()
            updateStatus()
            advance()
        }
    }

    private func handleChapterPageState(_ state: ReadiumChapterPageState?) {
        guard let state,
              let targetChapter,
              state.resourceIndex == targetChapter,
              chaptersToMeasure.first == targetChapter
        else { return }

        timeoutTask?.cancel()
        if pagesPerChapter.indices.contains(targetChapter) {
            pagesPerChapter[targetChapter] = max(1, state.totalPages)
        }
        measuredIndexes.insert(targetChapter)
        chaptersToMeasure.removeFirst()
        persistCurrentSettings()
        updateStatus()
        advance()
    }

    private func persistCurrentSettings() {
        guard let activeBookID, !pagesPerChapter.isEmpty else { return }
        let chapterCount = pagesPerChapter.count
        let progress = Double(measuredIndexes.count) / Double(max(1, chapterCount))
        let totalWords = activeBook?.totalWords ?? 0
        let totalPages = max(1, pagesPerChapter.reduce(0) { $0 + max(1, $1) })
        let density = totalWords > 0 ? Double(totalWords) / Double(totalPages) : 0
        let settings = PaginatedSettings(
            pagesPerChapter: pagesPerChapter,
            progress: progress,
            measuredChapterIndex: -1,
            wordsPerViewportPage: density,
            measuredChapterIndexes: Array(measuredIndexes)
        )
        store.updatePaginationCache(bookId: activeBookID, key: PaginationKey.defaultLibraryKey, settings: settings)
    }

    private func stopActiveJob(cancelled: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if cancelled {
            persistCurrentSettings()
        }
        activeBookID = nil
        pendingChapterJump = nil
        navigatorReady = false
        targetChapter = nil
        pagesPerChapter = []
        measuredIndexes = []
        chaptersToMeasure = []
        store.libraryPaginationStatus = nil
        endBackgroundTask()
    }

    private func updateStatus(for book: Book? = nil) {
        guard let book = book ?? activeBook else {
            store.libraryPaginationStatus = nil
            return
        }
        store.libraryPaginationStatus = LibraryPaginationStatus(
            bookTitle: book.title,
            measuredChapters: measuredIndexes.count,
            totalChapters: pagesPerChapter.count
        )
    }

    private func scheduleNextAfterYield() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            scheduleNextIfNeeded()
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard activeBookID != nil, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Library Exact Pagination") {
            Task { @MainActor in
                persistCurrentSettings()
                stopActiveJob(cancelled: true)
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

extension Book {
    var defaultLibraryPaginationSettings: PaginatedSettings? {
        paginationCache?[PaginationKey.defaultLibraryKey]
    }

    var hasCompleteDefaultLibraryPagination: Bool {
        guard let settings = defaultLibraryPaginationSettings,
              let chapterCount = wordCountsPerSpine?.count,
              chapterCount > 0,
              settings.pagesPerChapter.count == chapterCount
        else { return false }

        let measured = Set(settings.measuredChapterIndexes ?? [])
            .filter { $0 >= 0 && $0 < chapterCount }
        return measured.count == chapterCount
    }

    var defaultLibraryPaginationText: String? {
        guard let settings = defaultLibraryPaginationSettings else { return nil }
        let prefix = hasCompleteDefaultLibraryPagination ? "" : "~"
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: settings.totalPages), number: .decimal)
        return "\(prefix)\(formatted) pages"
    }
}
