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
    @State private var throttleTask: Task<Void, Never>?
    @State private var pagesPerChapter: [Int] = []
    @State private var measuredIndexes: Set<Int> = []
    @State private var chaptersToMeasure: [Int] = []
    @State private var measuredSinceLastPersist = 0
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
            publishStatus(nil)
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
        throttleTask?.cancel()
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

        let missingWordDetails = cached.map { !book.hasCompleteMeasuredWords(in: $0) } ?? true

        pagesPerChapter = pages
        measuredIndexes = measured
        chaptersToMeasure = missingWordDetails ? Array(0..<chapterCount) : (0..<chapterCount).filter { !measured.contains($0) }
        measuredSinceLastPersist = 0
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
            completeMeasuredChapter()
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
        completeMeasuredChapter()
    }

    private func completeMeasuredChapter() {
        targetChapter = nil
        measuredSinceLastPersist += 1
        if measuredSinceLastPersist >= 5 || chaptersToMeasure.isEmpty {
            persistCurrentSettings()
            measuredSinceLastPersist = 0
        }
        updateStatus()
        scheduleAdvanceAfterThrottle()
    }

    private func scheduleAdvanceAfterThrottle() {
        throttleTask?.cancel()
        let delay: UInt64 = activeBookID == priorityBookID ? 80_000_000 : 240_000_000
        throttleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard activeBookID != nil, targetChapter == nil else { return }
            advance()
        }
    }

    private func persistCurrentSettings() {
        guard let activeBookID, !pagesPerChapter.isEmpty else { return }
        let chapterCount = pagesPerChapter.count
        let progress = Double(measuredIndexes.count) / Double(max(1, chapterCount))
        let measuredWordsPerChapter: [Int]? = activeBook?.wordCountsPerSpine.map { counts in
            counts.indices.map { measuredIndexes.contains($0) ? max(0, counts[$0]) : 0 }
        }
        let density: Double = {
            guard let measuredWordsPerChapter else { return 0 }
            let measuredWords = measuredIndexes.reduce(0) { total, index in
                guard measuredWordsPerChapter.indices.contains(index), pagesPerChapter.indices.contains(index) else { return total }
                return total + measuredWordsPerChapter[index]
            }
            let measuredPages = measuredIndexes.reduce(0) { total, index in
                guard pagesPerChapter.indices.contains(index) else { return total }
                return total + max(1, pagesPerChapter[index])
            }
            guard measuredWords > 0, measuredPages > 0 else { return 0 }
            return Double(measuredWords) / Double(measuredPages)
        }()
        let settings = PaginatedSettings(
            pagesPerChapter: pagesPerChapter,
            progress: progress,
            measuredChapterIndex: -1,
            wordsPerViewportPage: density,
            measuredChapterIndexes: Array(measuredIndexes),
            measuredWordsPerChapter: measuredWordsPerChapter
        )
        // Defer the published Store mutation out of the current SwiftUI
        // view-update pass (this runs from onChange / Readium callbacks).
        // Values are captured synchronously, so a one-tick delay on the
        // persistence write is harmless.
        let bookId = activeBookID
        Task { @MainActor in
            store.updatePaginationCache(bookId: bookId, key: PaginationKey.defaultLibraryKey, settings: settings)
        }
    }

    private func stopActiveJob(cancelled: Bool) {
        timeoutTask?.cancel()
        throttleTask?.cancel()
        timeoutTask = nil
        throttleTask = nil
        if cancelled || measuredSinceLastPersist > 0 {
            persistCurrentSettings()
            measuredSinceLastPersist = 0
        }
        activeBookID = nil
        pendingChapterJump = nil
        navigatorReady = false
        targetChapter = nil
        pagesPerChapter = []
        measuredIndexes = []
        chaptersToMeasure = []
        publishStatus(nil)
        endBackgroundTask()
    }

    private func updateStatus(for book: Book? = nil) {
        guard let book = book ?? activeBook else {
            publishStatus(nil)
            return
        }
        publishStatus(LibraryPaginationStatus(
            bookTitle: book.title,
            measuredChapters: measuredIndexes.count,
            totalChapters: pagesPerChapter.count
        ))
    }

    /// Publishes the (purely cosmetic) pagination status to the shared Store
    /// on the next main-actor turn, so it never mutates a published property
    /// during a SwiftUI view-update pass. Dedupes to cut redundant churn.
    private func publishStatus(_ status: LibraryPaginationStatus?) {
        Task { @MainActor in
            if store.libraryPaginationStatus != status {
                store.libraryPaginationStatus = status
            }
        }
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
        return measured.count == chapterCount && hasCompleteMeasuredWords(in: settings)
    }

    func hasCompleteMeasuredWords(in settings: PaginatedSettings) -> Bool {
        guard let counts = wordCountsPerSpine,
              !counts.isEmpty,
              let measuredWords = settings.measuredWordsPerChapter,
              measuredWords.count == counts.count
        else { return false }

        let measured = Set(settings.measuredChapterIndexes ?? [])
            .filter { $0 >= 0 && $0 < counts.count }
        guard !measured.isEmpty else { return false }

        return measured.allSatisfy { measuredWords[$0] == max(0, counts[$0]) }
    }

    var defaultLibraryPaginationText: String? {
        guard let settings = defaultLibraryPaginationSettings else { return nil }
        let prefix = hasCompleteDefaultLibraryPagination ? "" : "~"
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: settings.totalPages), number: .decimal)
        return "\(prefix)\(formatted) pages"
    }
}
