import SwiftUI
import UIKit
import WebKit
import SafariServices
import ReadiumShared

// MARK: - Reader view

struct ReaderView: View {
    let bookId: String
    var onCloseWithElapsed: (Int) -> Void = { _ in }
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ReaderModel()

    @State private var showChrome: Bool = true
    @State private var showSettings = false
    @State private var showContents = false
    @State private var showSearch = false
    @State private var showPageAudit = false
    @State private var contentsInitialTab: ReaderContentsSheet.ContentTab = .chapters
    @State private var showReaderMenu = false
    @State private var pendingLocatorJSON: String?
    @State private var pendingChapterJump: ReadiumChapterJump?
    @State private var pendingTOCLinkJump: ReadiumTOCLinkJump?
    @State private var diagnosticPageTurnRequest: ReadiumDiagnosticPageTurnRequest?
    @State private var returnLocatorJSON: String?
    @State private var readiumPublication: Publication?
    @State private var pageAuditLog = ""
    @State private var isPageAuditRunning = false
    @State private var pageAuditTask: Task<Void, Never>?
    @State private var diagnosticPageTurnResult: ReadiumDiagnosticPageTurnResult?
    @State private var hiddenPaginationRunning = false
    @State private var hiddenPaginationNavigatorReady = false
    @State private var hiddenPaginationPendingChapterJump: ReadiumChapterJump?
    @State private var hiddenPaginationTargetChapter: Int?
    @State private var hiddenPaginationTimeoutTask: Task<Void, Never>?
    @State private var hiddenPaginationPagesPerChapter: [Int] = []
    @State private var hiddenPaginationMeasuredIndexes: Set<Int> = []
    @State private var hiddenPaginationChaptersToMeasure: [Int] = []
    @State private var hiddenPaginationMeasuredThisRun = 0
    @State private var hiddenPaginationLines: [String] = []
    @State private var automaticHiddenPaginationAttemptedKeys: Set<PaginationKey> = []
    @State private var automaticHiddenPaginationResumeTask: Task<Void, Never>?
    @State private var sessionStartedAt = Date()
    @State private var sessionStartProgress: Double?
    @State private var sessionStartPage: Int?
    @State private var sessionStartPublisherPage: Int?
    @State private var sessionStartWordOffset: Int?
    @State private var sessionSaved = false
    @State private var elapsed = 0
    @State private var timer: Timer?
    @State private var goalMetAtSessionStart = false
    @State private var goalCelebrationShown = false
    @State private var showGoalCelebration = false
    @State private var goalCelebrationTask: Task<Void, Never>?
    @State private var endPromptShown = false
    @State private var finishPromptTarget: Book?
    @State private var externalURL: BrowserURL?
    @State private var readerInteractionResetID: UUID?

    private var book: Book? { store.books.first { $0.id == bookId } }

    private var dailyGoalSeconds: Int { max(1, store.goal.minutes) * 60 }

    private var currentSessionDaySeconds: Int {
        Calendar.current.isDate(sessionStartedAt, inSameDayAs: Date()) ? elapsed : 0
    }

    private var todaySecondsIncludingCurrentSession: Int {
        store.todaySeconds() + currentSessionDaySeconds
    }

    private var readingGoalMet: Bool {
        todaySecondsIncludingCurrentSession >= dailyGoalSeconds
    }

    // MARK: - Reading speed estimates
    //
    // These derive from the per-book / per-library WPM in ReadingSpeedEstimator.
    // Returns nil whenever there's not yet enough data to make an honest
    // estimate, so chrome surfaces can show "Calculating..." instead of
    // hallucinating a number from the 240 WPM default.

    private var estimatedWPM: Double? {
        ReadingSpeedEstimator.wpm(forBookID: bookId, sessions: store.sessions)
    }

    private var minutesLeftInChapter: Int? {
        guard let book,
              let counts = book.wordCountsPerSpine,
              let idx = model.activeReadiumResourceIndex,
              counts.indices.contains(idx),
              let progression = model.activeChapterProgression,
              let wpm = estimatedWPM
        else { return nil }
        return ReadingSpeedEstimator.minutesRemainingInChapter(
            wordsInChapter: counts[idx],
            progressionInChapter: progression,
            wpm: wpm
        )
    }

    private var minutesLeftInBook: Int? {
        guard let book,
              let offset = model.currentWordOffset,
              let wpm = estimatedWPM
        else { return nil }
        return ReadingSpeedEstimator.minutesRemainingInBook(
            book: book,
            currentWordOffset: offset,
            wpm: wpm
        )
    }

    private var chapterTimeRemainingText: String {
        guard let mins = minutesLeftInChapter else { return "Calculating…" }
        return "~\(Fmt.duration(mins * 60)) left in this chapter"
    }

    private var resolvedWordsPerPageForReaderContext: Int {
        if store.readerSettings.wordsPerPageMode == .automatic,
           let estimate = currentChapterWordsPerPageEstimate() {
            return estimate
        }
        return store.resolvedWordsPerPageForCurrentDevice()
    }

    private var estimatedWordsPerPageDebugText: String {
        "Estimated \(resolvedWordsPerPageForReaderContext) words per page"
    }

    private func currentChapterWordsPerPageEstimate() -> Int? {
        guard let counts = book?.wordCountsPerSpine else { return nil }
        let index = model.activeReadiumResourceIndex ?? model.chapterIndex
        guard counts.indices.contains(index), counts[index] > 0,
              let settings = model.paginatedSettings,
              settings.pagesPerChapter.indices.contains(index)
        else { return nil }
        let pages = max(1, settings.pagesPerChapter[index])
        let raw = Double(counts[index]) / Double(pages)
        let rounded = Int((raw / 5.0).rounded() * 5.0)
        return ReaderSettings.clampedWordsPerPage(rounded)
    }

    private var bookTimeRemainingText: String {
        guard let mins = minutesLeftInBook else { return "Calculating…" }
        return "~\(Fmt.duration(mins * 60)) left in book"
    }

    var body: some View {
        ZStack {
            model.theme.backgroundColor.ignoresSafeArea()

            // Content
            if let epubURL = model.epubURL {
                ReadiumReaderContainer(
                    epubURL: epubURL,
                    settings: model.settings,
                    initialProgress: store.progress[bookId]?.pct ?? 0,
                    pendingLocatorJSON: pendingLocatorJSON,
                    pendingChapterJump: pendingChapterJump,
                    pendingTOCLinkJump: pendingTOCLinkJump,
                    diagnosticPageTurnRequest: diagnosticPageTurnRequest,
                    highlights: store.highlights[bookId] ?? [],
                    testCurlPageLabels: model.testCurlPageLabels,
                    showsChrome: showChrome,
                    interactionResetID: readerInteractionResetID,
                    onLocationChange: { location in
                        model.updateReadiumLocation(location)
                        captureSessionStartIfNeeded()
                        store.updateProgress(bookId: bookId, pct: model.overallProgress, cfi: location.locatorJSON)
                        store.updateLiveReadingSession(
                            bookId: bookId,
                            elapsedSeconds: elapsed,
                            progressPct: model.overallProgress,
                            cfi: location.locatorJSON
                        )
                        maybePromptFinish()
                    },
                    onChapterPageChange: { state in
                        model.updateReadiumChapterPageState(state)
                        requestAutomaticHiddenPaginationIfNeeded()
                    },
                    onPageTurn: { direction in
                        model.expectReadiumPageTurn(direction)
                    },
                    onCenterTap: {
                        toggleChrome()
                    },
                    onHighlightSelection: { locatorJSON, text in
                        addHighlight(locatorJSON: locatorJSON, text: text)
                    },
                    onPublicationReady: { publication in
                        readiumPublication = publication
                        requestAutomaticHiddenPaginationIfNeeded()
                    },
                    onExternalURL: { url in
                        readerInteractionResetID = UUID()
                        externalURL = BrowserURL(url: url)
                    },
                    onDiagnosticPageTurnResult: { result in
                        diagnosticPageTurnResult = result
                    }
                )
                .ignoresSafeArea()
            } else if let err = model.error {
                errorView(err)
            } else {
                loadingView
            }

            if hiddenPaginationRunning, let epubURL = model.epubURL {
                ReadiumReaderContainer(
                    epubURL: epubURL,
                    settings: hiddenPaginationSettings,
                    initialProgress: 0,
                    pendingLocatorJSON: nil,
                    pendingChapterJump: hiddenPaginationPendingChapterJump,
                    pendingTOCLinkJump: nil,
                    diagnosticPageTurnRequest: nil,
                    highlights: [],
                    testCurlPageLabels: nil,
                    showsChrome: false,
                    onLocationChange: { _ in },
                    onChapterPageChange: handleHiddenPaginationPageState,
                    onPageTurn: { _ in },
                    onCenterTap: {},
                    onHighlightSelection: { _, _ in },
                    onPublicationReady: { publication in
                        guard publication != nil else { return }
                        hiddenPaginationNavigatorReady = true
                        if hiddenPaginationRunning, hiddenPaginationTargetChapter == nil {
                            advanceHiddenPagination()
                        }
                    },
                    onExternalURL: { _ in },
                    onDiagnosticPageTurnResult: { _ in }
                )
                .ignoresSafeArea()
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            // Brightness overlay
            Color.black
                .opacity(1.0 - max(0.35, min(1.0, Double(model.settings.brightness) / 100.0)))
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Chrome
            if showChrome {
                VStack {
                    topBar
                    Spacer()
                }
                .transition(.opacity)

                readerBottomChrome
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if model.epubURL != nil, model.settings.pageAnim != .testCurl {
                hiddenPageIndicator
                    .transition(.opacity)
            }

            if showGoalCelebration {
                goalCelebrationBanner
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBar(hidden: !showChrome)
        .preferredColorScheme(model.settings.theme == .device ? nil : (model.theme.isDark ? .dark : .light))
        .task { await load() }
        .onAppear {
            sessionStartedAt = Date()
            sessionStartProgress = nil
            sessionStartPage = nil
            sessionStartPublisherPage = nil
            sessionStartWordOffset = nil
            sessionSaved = false
            elapsed = 0
            goalMetAtSessionStart = readingGoalMet
            goalCelebrationShown = readingGoalMet
            showGoalCelebration = false
            goalCelebrationTask?.cancel()
            goalCelebrationTask = nil
            startTimer()
            UIApplication.shared.isIdleTimerDisabled = model.settings.keepAwake
        }
        .onDisappear {
            timer?.invalidate()
            goalCelebrationTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            stopHiddenPaginationForReaderExit()
            saveSession()
            store.endLiveReadingSession(bookId: bookId)
        }
        .onChange(of: model.settings.keepAwake) { _, v in
            UIApplication.shared.isIdleTimerDisabled = v
        }
        .onChange(of: showSettings) { _, isPresented in
            if !isPresented { requestAutomaticHiddenPaginationIfNeeded() }
        }
        .onChange(of: showContents) { _, isPresented in
            if !isPresented { requestAutomaticHiddenPaginationIfNeeded() }
        }
        .onChange(of: showSearch) { _, isPresented in
            if !isPresented { requestAutomaticHiddenPaginationIfNeeded() }
        }
        .onChange(of: model.paginationKey) { _, key in
            model.hydratePaginatedSettings(book?.paginationCache?[key], for: key)
            requestAutomaticHiddenPaginationIfNeeded()
        }
        .onChange(of: model.paginatedSettings) { _, settings in
            guard let settings else { return }
            store.updatePaginationCache(bookId: bookId, key: model.paginationKey, settings: settings)
            requestAutomaticHiddenPaginationIfNeeded()
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showContents) {
            ReaderContentsSheet(
                model: model,
                bookId: bookId,
                initialTab: contentsInitialTab,
                onJump: { chapter, page in
                    jumpToChapter(chapter, page: page)
                    showContents = false
                },
                onLocatorJump: { locatorJSON in
                    prepareReturnLocation()
                    deferAutomaticHiddenPaginationAfterForegroundJump()
                    pendingLocatorJSON = locatorJSON
                    showContents = false
                },
                onTOCLinkJump: { href, title in
                    prepareReturnLocation()
                    deferAutomaticHiddenPaginationAfterForegroundJump()
                    pendingTOCLinkJump = ReadiumTOCLinkJump(href: href, title: title)
                    showContents = false
                }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showSearch) {
            if let readiumPublication {
                ReaderSearchSheet(publication: readiumPublication, model: model) { locatorJSON in
                    prepareReturnLocation()
                    pendingLocatorJSON = locatorJSON
                    showSearch = false
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
            }
        }
        #if DEBUG
        .sheet(isPresented: $showPageAudit, onDismiss: handlePageAuditDismiss) {
            ReaderPageAuditSheet(
                model: model,
                log: pageAuditLog,
                isRunning: isPageAuditRunning,
                onRunFromCurrent: { startPageAudit(fromStart: false) },
                onRunFromStart: { startPageAudit(fromStart: true) },
                onBuildExactPagination: startExactPaginationBuild,
                onBuildHiddenExactPagination: { startHiddenExactPaginationBuild() },
                onAutoWordsPerPageDebug: writeAutoWordsPerPageDebugLog,
                onStartChromeTrace: { model.startChromeTrace() },
                onLoadChromeTrace: {
                    model.stopChromeTrace()
                    pageAuditLog = (["BookMark Chrome Trace"] + pageAuditMetadataLines + ["", model.chromeTraceText()])
                        .joined(separator: "\n")
                },
                onStop: stopPageAudit,
                onClear: { pageAuditLog = "" }
            )
            .presentationDetents([.large])
        }
        #endif
        .sheet(item: $finishPromptTarget) { bk in
            FinishDateSheet(book: bk) { }
                .presentationDetents([.medium])
        }
        .sheet(item: $externalURL, onDismiss: {
            externalURL = nil
            readerInteractionResetID = UUID()
        }) { item in
            ReaderBrowserSheet(url: item.url)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading book…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Could not open this book")
                .font(.system(size: 16, weight: .heavy))
            Text(msg)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Close") { close() }
                .padding(.top, 8)
        }
    }

    private var goalCelebrationBanner: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.imsg)

                Text("Today’s reading goal achieved")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(model.theme.foregroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                if #available(iOS 26.0, *) {
                    Capsule()
                        .glassEffect(.regular)
                } else {
                    Capsule()
                        .fill(model.theme.panelMaterial)
                        .overlay(Capsule().strokeBorder(Color.gray.opacity(0.15), lineWidth: 1))
                }
            }
            .shadow(color: .black.opacity(model.theme.isDark ? 0.22 : 0.10), radius: 12, x: 0, y: 4)
            .padding(.top, 8)

            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { close() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .heavy))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(model.theme.foregroundColor)
            }
            if returnLocatorJSON != nil {
                Button {
                    goBackToPreJumpLocation()
                } label: {
                    Text("Go back")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(model.theme.foregroundColor)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Color.gray.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 1) {
                Text(model.chapterPagesLeftText)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(model.theme.foregroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .allowsTightening(true)
                    .monospacedDigit()
                Text(chapterTimeRemainingText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.theme.foregroundColor.opacity(0.55))
                    .lineLimit(1)
                    .monospacedDigit()
                Text(estimatedWordsPerPageDebugText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.theme.foregroundColor.opacity(0.42))
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 5) {
                if readingGoalMet {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.imsg)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(Fmt.timer(elapsed))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(model.theme.foregroundColor)
                    .monospacedDigit()
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: readingGoalMet)
            Button {
                toggleBookmark()
            } label: {
                Image(systemName: hasBookmarkHere ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(hasBookmarkHere ? Theme.gold : model.theme.foregroundColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(model.theme.panelMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.gray.opacity(0.15), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    private var readerBottomChrome: some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 16) {
                    progressBar
                    VStack(spacing: 2) {
                        Text(model.statusBottom)
                            .font(.system(size: 19, weight: .heavy))
                            .foregroundStyle(model.theme.foregroundColor)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(bookTimeRemainingText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.theme.foregroundColor.opacity(0.55))
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 56)
                .padding(.bottom, -8)

                VStack(alignment: .trailing, spacing: 12) {
                    if showReaderMenu {
                        readerMenu
                            .transition(.scale(scale: 0.94, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                    readerMenuToggle
                }
                .padding(.trailing, 20)
                .padding(.bottom, 62)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(model.theme.isDark ? 0.32 : 0.26))
                Capsule().fill(Theme.imsg)
                    .frame(width: geo.size.width * CGFloat(model.overallProgress))
            }
        }
        .frame(height: 6)
        .frame(maxWidth: 500)
    }

    private var readerMenuToggle: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                showReaderMenu.toggle()
            }
        } label: {
            Image(systemName: showReaderMenu ? "xmark" : "line.3.horizontal")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(model.theme.foregroundColor)
                .frame(width: 62, height: 62)
                .background(model.theme.panelMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.gray.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(model.theme.isDark ? 0.35 : 0.14), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showReaderMenu ? "Close reader menu" : "Open reader menu")
    }

    private var hiddenPageIndicator: some View {
        VStack {
            Spacer()
            Text(model.pageOnlyText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.theme.foregroundColor.opacity(0.75))
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .padding(.bottom, 18)
        }
        .allowsHitTesting(false)
    }

    private var readerMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            readerMenuButton(icon: "list.bullet", title: "Contents") {
                contentsInitialTab = .chapters
                showReaderMenu = false
                showContents = true
            }
            readerMenuButton(icon: "textformat.size", title: "Themes & Settings") {
                showReaderMenu = false
                showSettings = true
            }
            Divider().opacity(0.35)
            readerMenuButton(icon: "bookmark", title: "Bookmarks") {
                contentsInitialTab = .bookmarks
                showReaderMenu = false
                showContents = true
            }
            readerMenuButton(icon: "magnifyingglass", title: "Search", isPlaceholder: readiumPublication == nil) {
                showReaderMenu = false
                showSearch = true
            }
            #if DEBUG
            Divider().opacity(0.35)
            readerMenuButton(icon: "stethoscope", title: "Page Audit", isPlaceholder: model.epubURL == nil) {
                showReaderMenu = false
                showPageAudit = true
            }
            #endif
            // Placeholder: add navigation/book metadata actions here if needed later.
            readerMenuButton(icon: "ellipsis", title: "More", isPlaceholder: true) { }
        }
        .padding(8)
        .frame(width: 238)
        .background(model.theme.panelMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.gray.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(model.theme.isDark ? 0.35 : 0.14), radius: 18, y: 6)
    }

    private func readerMenuButton(
        icon: String,
        title: String,
        isPlaceholder: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if isPlaceholder {
                    Text("Soon")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(model.theme.secondaryForeground)
                }
            }
            .foregroundStyle(isPlaceholder ? model.theme.secondaryForeground : model.theme.foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPlaceholder)
        .opacity(isPlaceholder ? 0.55 : 1)
    }

    private var hasBookmarkHere: Bool {
        let bms = store.bookmarks[bookId] ?? []
        if model.epubURL != nil {
            guard let currentLocator = model.readiumLocatorJSON else { return false }
            return bms.contains { bookmark in
                bookmark.cfi.isReadiumLocatorJSON && bookmark.cfi == currentLocator
            }
        }
        guard let pkg = model.package, model.chapterIndex < pkg.spine.count else { return false }
        return bms.contains { $0.cfi.hasPrefix("ch:\(model.chapterIndex):") && $0.cfi == "ch:\(model.chapterIndex):p\(model.currentPage)" }
    }

    private func toggleBookmark() {
        if model.epubURL != nil {
            guard let locatorJSON = model.readiumLocatorJSON else { return }
            var list = store.bookmarks[bookId] ?? []
            let displayPage = model.displayPage
            if let i = list.firstIndex(where: {
                $0.cfi.isReadiumLocatorJSON && $0.cfi == locatorJSON
            }) {
                list.remove(at: i)
            } else {
                let title = model.readiumChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let pageText = "Page \(displayPage)"
                let label = title?.isEmpty == false && title != pageText ? "\(title!) · \(pageText)" : pageText
                list.append(Bookmark(cfi: locatorJSON, label: label, pct: model.overallProgress, page: displayPage))
            }
            store.bookmarks[bookId] = list
            store.scheduleSave()
            return
        }

        guard let pkg = model.package, model.chapterIndex < pkg.spine.count else { return }
        let chapterTitle = pkg.spine[model.chapterIndex].title
        let label = chapterTitle.isEmpty ? "Chapter \(model.chapterIndex + 1) · page \(model.currentPage)" : "\(chapterTitle) · page \(model.currentPage)"
        let cfi = "ch:\(model.chapterIndex):p\(model.currentPage)"

        var list = store.bookmarks[bookId] ?? []
        if let i = list.firstIndex(where: { $0.cfi == cfi }) {
            list.remove(at: i)
        } else {
            list.append(Bookmark(cfi: cfi, label: label, pct: model.overallProgress))
        }
        store.bookmarks[bookId] = list
        store.scheduleSave()
    }

    private func addHighlight(locatorJSON: String, text: String) {
        let cleanText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !cleanText.isEmpty else { return }

        var list = store.highlights[bookId] ?? []
        if list.contains(where: { $0.locatorJSON == locatorJSON }) {
            return
        }
        list.append(Highlight(locatorJSON: locatorJSON, text: cleanText))
        store.highlights[bookId] = list
        store.scheduleSave()
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.15)) {
            showChrome.toggle()
            if !showChrome {
                showReaderMenu = false
            }
        }
    }

    /// Settings for the off-screen pagination navigator. It only measures page
    /// counts, so it must never run the Test Curl preload machinery: that navigator
    /// is perpetually loading as it churns through every chapter, so each prep bails
    /// with `skipped=activeLoadingIndicator` and reschedules, and with one retry per
    /// location change this snowballs into a retry storm that starves the foreground
    /// reader (e.g. TOC jumps). Forcing `.none` keeps the hidden navigator silent.
    private var hiddenPaginationSettings: ReaderSettings {
        var settings = model.settings
        settings.pageAnim = .none
        return settings
    }

    private func jumpToChapter(_ chapter: Int, page: Int?) {
        prepareReturnLocation()
        deferAutomaticHiddenPaginationAfterForegroundJump()
        if model.epubURL != nil {
            pendingChapterJump = ReadiumChapterJump(chapterIndex: chapter)
            return
        }
        model.go(to: chapter, page: page)
    }

    private func deferAutomaticHiddenPaginationAfterForegroundJump() {
        automaticHiddenPaginationResumeTask?.cancel()
        if hiddenPaginationRunning {
            finishHiddenPagination(cancelled: true)
        }
        automaticHiddenPaginationResumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            automaticHiddenPaginationResumeTask = nil
            requestAutomaticHiddenPaginationIfNeeded()
        }
    }

    private func prepareReturnLocation() {
        guard returnLocatorJSON == nil, let locator = model.readiumLocatorJSON else { return }
        returnLocatorJSON = locator
    }

    private func goBackToPreJumpLocation() {
        guard let locator = returnLocatorJSON else { return }
        pendingLocatorJSON = locator
        returnLocatorJSON = nil
    }

    private var pageAuditMetadataLines: [String] {
        let started = ISO8601DateFormatter().string(from: Date())
        let measuredText: String = {
            let count = model.paginatedMeasuredChapterCount
            let total = model.paginationChapterCount
            guard total > 0 else { return "" }
            return "\(count)/\(total)"
        }()
        return [
            "startedAt\t\(started)",
            "bookId\t\(bookId)",
            "bookTitle\t\(book?.title ?? "")",
            "pageCountMode\t\(model.settings.pageCountMode.rawValue)",
            "font\t\(model.settings.font.rawValue)",
            "fontSize\t\(model.settings.fontSize)",
            "bold\t\(model.settings.bold)",
            "lineHeight\t\(model.settings.lineHeight)",
            "margins\t\(model.settings.margins.rawValue)",
            "justify\t\(model.settings.justify)",
            "paginationCacheHit\t\(model.paginationCacheHit)",
            "paginationStatus\t\(model.paginatedSettingsIsComplete ? "exact" : (model.paginatedSettings == nil ? "none" : "estimated"))",
            "paginationMeasured\t\(measuredText)",
            "paginationTotal\t\(model.paginatedSettings?.totalPages ?? 0)",
            "paginationCacheEntries\t\(book?.paginationCache?.count ?? 0)"
        ]
    }

    private func writeAutoWordsPerPageDebugLog() {
        var lines: [String] = ["BookMark Auto WPP Debug"] + pageAuditMetadataLines
        let globalResolved = store.resolvedWordsPerPageForCurrentDevice()
        let autoEstimate = store.automaticWordsPerPageEstimate()
        let currentChapterEstimate = currentChapterWordsPerPageEstimate()
        lines.append("readerSettingsMode\t\(store.readerSettings.wordsPerPageMode.rawValue)")
        lines.append("manualWordsPerPage\t\(store.readerSettings.wordsPerPageForCurrentDevice)")
        lines.append("globalAutoEstimate\t\(autoEstimate.map(String.init) ?? "nil")")
        lines.append("currentChapterAutoEstimate\t\(currentChapterEstimate.map(String.init) ?? "nil")")
        lines.append("globalResolvedWordsPerPage\t\(globalResolved)")
        lines.append("readerContextWordsPerPage\t\(resolvedWordsPerPageForReaderContext)")
        lines.append("currentPaginationKey\t\(paginationKeyDebug(model.paginationKey))")
        lines.append("storeCurrentPaginationKey\t\(paginationKeyDebug(store.currentPaginationKey))")
        lines.append("defaultLibraryKey\t\(paginationKeyDebug(.defaultLibraryKey))")
        lines.append("")

        if let book {
            lines.append(contentsOf: autoWordsPerPageDebugLines(book: book, key: model.paginationKey, label: "readerCurrentKey"))
            lines.append("")
            lines.append(contentsOf: autoWordsPerPageDebugLines(book: book, key: store.currentPaginationKey, label: "storeCurrentKey"))
            lines.append("")
            lines.append(contentsOf: autoWordsPerPageDebugLines(book: book, key: .defaultLibraryKey, label: "defaultLibraryKey"))
            lines.append("")
            lines.append(contentsOf: livePaginatedSettingsDebugLines(book: book))
        } else {
            lines.append("book\tnil")
        }

        pageAuditLog = lines.joined(separator: "\n")
    }

    private func autoWordsPerPageDebugLines(book: Book, key: PaginationKey, label: String) -> [String] {
        guard let settings = book.paginationCache?[key] else {
            return ["section\t\(label)", "cacheHit\tfalse"]
        }
        return autoWordsPerPageDebugLines(
            section: label,
            settings: settings,
            fallbackWordCounts: book.wordCountsPerSpine
        )
    }

    private func livePaginatedSettingsDebugLines(book: Book) -> [String] {
        guard let settings = model.paginatedSettings else {
            return ["section\tliveModel", "cacheHit\tfalse"]
        }
        return autoWordsPerPageDebugLines(
            section: "liveModel",
            settings: settings,
            fallbackWordCounts: book.wordCountsPerSpine
        )
    }

    private func autoWordsPerPageDebugLines(
        section: String,
        settings: PaginatedSettings,
        fallbackWordCounts: [Int]?
    ) -> [String] {
        var indexes = Set(settings.measuredChapterIndexes ?? [])
        if indexes.isEmpty, settings.measuredChapterIndex >= 0 {
            indexes.insert(settings.measuredChapterIndex)
        }
        indexes = indexes.filter { settings.pagesPerChapter.indices.contains($0) }

        let paired = autoWordsPerPageDebugTotals(
            indexes: indexes,
            pagesPerChapter: settings.pagesPerChapter,
            wordsPerChapter: settings.measuredWordsPerChapter
        )
        let legacy = autoWordsPerPageDebugTotals(
            indexes: indexes,
            pagesPerChapter: settings.pagesPerChapter,
            wordsPerChapter: fallbackWordCounts
        )

        return [
            "section\t\(section)",
            "cacheHit\ttrue",
            "settingsProgress\t\(settings.progress)",
            "settingsTotalPages\t\(settings.totalPages)",
            "settingsDensity\t\(settings.wordsPerViewportPage)",
            "measuredIndexesCount\t\(indexes.count)",
            "measuredIndexes\t\(indexes.sorted().map(String.init).joined(separator: ","))",
            "hasPairedWords\t\(settings.measuredWordsPerChapter != nil)",
            "pairedWords\t\(paired.words)",
            "pairedPages\t\(paired.pages)",
            "pairedSampleCount\t\(paired.sampleCount)",
            "pairedAggregateRawWPP\t\(paired.aggregateRawText)",
            "pairedChapterAverageWPP\t\(paired.chapterAverageText)",
            "pairedRoundedWPP\t\(paired.roundedText)",
            "legacyWords\t\(legacy.words)",
            "legacyPages\t\(legacy.pages)",
            "legacySampleCount\t\(legacy.sampleCount)",
            "legacyAggregateRawWPP\t\(legacy.aggregateRawText)",
            "legacyChapterAverageWPP\t\(legacy.chapterAverageText)",
            "legacyRoundedWPP\t\(legacy.roundedText)"
        ]
    }

    private func autoWordsPerPageDebugTotals(indexes: Set<Int>, pagesPerChapter: [Int], wordsPerChapter: [Int]?) -> (words: Int, pages: Int, sampleCount: Int, aggregateRawText: String, chapterAverageText: String, roundedText: String) {
        var words = 0
        var pages = 0
        var chapterSamples: [Double] = []

        for index in indexes where pagesPerChapter.indices.contains(index) {
            guard let wordsPerChapter,
                  wordsPerChapter.indices.contains(index),
                  wordsPerChapter[index] > 0
            else { continue }

            let chapterPages = pagesPerChapter[index]
            guard chapterPages > 0 else { continue }

            let chapterWords = wordsPerChapter[index]
            words += chapterWords
            pages += chapterPages
            chapterSamples.append(Double(chapterWords) / Double(chapterPages))
        }

        guard words >= 1_000, pages >= 5, !chapterSamples.isEmpty else {
            return (words, pages, chapterSamples.count, "nil", "nil", "nil")
        }

        let aggregateRaw = Double(words) / Double(pages)
        let chapterAverage = chapterSamples.reduce(0, +) / Double(chapterSamples.count)
        let rounded = ReaderSettings.clampedWordsPerPage(Int((chapterAverage / 5.0).rounded() * 5.0))
        return (
            words,
            pages,
            chapterSamples.count,
            String(format: "%.2f", aggregateRaw),
            String(format: "%.2f", chapterAverage),
            "\(rounded)"
        )
    }

    private func paginationKeyDebug(_ key: PaginationKey) -> String {
        [
            "font=\(key.font.rawValue)",
            "fontSize=\(key.fontSize)",
            "bold=\(key.bold)",
            "lineHeight=\(key.lineHeight)",
            "margins=\(key.margins.rawValue)",
            "justify=\(key.justify)",
            "device=\(key.deviceClass)"
        ].joined(separator: ";")
    }

    private func startPageAudit(fromStart: Bool) {
        guard model.epubURL != nil, !isPageAuditRunning else { return }
        pageAuditTask?.cancel()
        isPageAuditRunning = true

        var lines: [String] = ["BookMark Page Audit"] + pageAuditMetadataLines + ["", model.paginationAuditHeader]
        pageAuditLog = lines.joined(separator: "\n")

        pageAuditTask = Task { @MainActor in
            if fromStart {
                pendingChapterJump = ReadiumChapterJump(chapterIndex: 0)
                await waitForAuditStartChapter()
            }

            lines.append(model.paginationAuditLine(step: 0, event: fromStart ? "startFromFirstChapter" : "startFromCurrent"))
            pageAuditLog = lines.joined(separator: "\n")

            let maxSteps = min(max(model.paginatedSettings?.totalPages ?? model.displayPageTotal, 1) + 8, 20_000)

            for step in 1...maxSteps {
                if Task.isCancelled { break }
                let beforePage = model.paginatedBookCurrentPage
                let beforeLocator = model.readiumLocatorJSON
                let beforeProgress = model.overallProgress
                var didMove = false

                for attempt in 1...3 {
                    if Task.isCancelled { break }
                    let request = ReadiumDiagnosticPageTurnRequest(direction: 1)
                    diagnosticPageTurnRequest = request
                    didMove = await waitForAuditTurn(
                        request: request,
                        beforeLocator: beforeLocator,
                        beforeProgress: beforeProgress
                    )
                    if didMove { break }

                    lines.append(model.paginationAuditLine(step: step, event: "turnIgnored", note: "attempt:\(attempt)"))
                    pageAuditLog = lines.joined(separator: "\n")
                    try? await Task.sleep(nanoseconds: 180_000_000)
                }

                if !didMove {
                    lines.append(model.paginationAuditLine(step: step, event: "stopped", note: "noMovementAfter3Attempts"))
                    break
                }

                let afterPage = model.paginatedBookCurrentPage
                var notes: [String] = []
                if let beforePage, let afterPage {
                    let delta = afterPage - beforePage
                    if delta == 0 {
                        notes.append("repeat")
                    } else if delta != 1 {
                        notes.append("skip:\(delta)")
                    }
                } else {
                    notes.append("missingPage")
                }

                lines.append(model.paginationAuditLine(step: step, event: "forward", note: notes.joined(separator: ",")))
                pageAuditLog = lines.joined(separator: "\n")

                if let afterPage, let total = model.paginatedSettings?.totalPages, afterPage >= total {
                    lines.append(model.paginationAuditLine(step: step, event: "finished", note: "reachedGeneratedTotal"))
                    break
                }
            }

            lines.append("")
            let generatedTotalText = model.paginatedSettings.map { String($0.totalPages) } ?? ""
            let finalPageText = model.paginatedBookCurrentPage.map(String.init) ?? ""
            lines.append("summary\tgeneratedTotal=\(generatedTotalText)\tfinalPage=\(finalPageText)\tprogress=\(Int((model.overallProgress * 100).rounded()))%")
            pageAuditLog = lines.joined(separator: "\n")
            isPageAuditRunning = false
            pageAuditTask = nil
        }
    }

    private func startExactPaginationBuild() {
        guard model.epubURL != nil, !isPageAuditRunning else { return }
        let chapterCount = model.paginationChapterCount
        guard chapterCount > 0 else { return }

        pageAuditTask?.cancel()
        isPageAuditRunning = true

        var lines: [String] = ["BookMark Exact Pagination Build"] + pageAuditMetadataLines + [
            "chapterCount\t\(chapterCount)",
            "",
            "chapterIndex\tstatus\tpages\twords\tnote"
        ]
        pageAuditLog = lines.joined(separator: "\n")

        let restoreLocator = model.readiumLocatorJSON
        pageAuditTask = Task { @MainActor in
            var pagesPerChapter = model.paginatedSettings?.pagesPerChapter ?? Array(repeating: 1, count: chapterCount)
            if pagesPerChapter.count != chapterCount {
                pagesPerChapter = Array(repeating: 1, count: chapterCount)
            }
            var measuredIndexes = Set(model.paginatedSettings?.measuredChapterIndexes ?? [])
            if measuredIndexes.isEmpty,
               let measuredChapterIndex = model.paginatedSettings?.measuredChapterIndex,
               measuredChapterIndex >= 0 {
                measuredIndexes.insert(measuredChapterIndex)
            }
            measuredIndexes = measuredIndexes.filter { $0 >= 0 && $0 < chapterCount }
            let chaptersToMeasure: [Int] = {
                let missing = (0..<chapterCount).filter { !measuredIndexes.contains($0) }
                return missing.isEmpty ? Array(0..<chapterCount) : missing
            }()
            let previouslyMeasured = measuredIndexes.count
            var measuredThisRun = 0

            lines.append("resumeFromMeasured\t\(previouslyMeasured)")
            lines.append("chaptersToMeasure\t\(chaptersToMeasure.count)")
            pageAuditLog = lines.joined(separator: "\n")

            for chapterIndex in chaptersToMeasure {
                if Task.isCancelled { break }
                pendingChapterJump = ReadiumChapterJump(chapterIndex: chapterIndex)
                let state = await waitForChapterPageState(chapterIndex)
                if let state {
                    pagesPerChapter[chapterIndex] = max(1, state.totalPages)
                    measuredIndexes.insert(chapterIndex)
                    measuredThisRun += 1
                    lines.append("\(chapterIndex)\tmeasured\t\(state.totalPages)\t\(chapterWordsText(chapterIndex))\t")
                } else {
                    let fallback = max(1, pagesPerChapter[chapterIndex])
                    pagesPerChapter[chapterIndex] = fallback
                    measuredIndexes.insert(chapterIndex)
                    measuredThisRun += 1
                    lines.append("\(chapterIndex)\tinferred\t\(fallback)\t\(chapterWordsText(chapterIndex))\tviewportTimeoutFallback")
                }
                pageAuditLog = lines.joined(separator: "\n")
            }

            if !Task.isCancelled, !measuredIndexes.isEmpty {
                let measuredTotal = measuredIndexes.count
                let progress = Double(measuredTotal) / Double(max(1, chapterCount))
                model.applyExactPaginatedSettings(
                    pagesPerChapter: pagesPerChapter,
                    progress: progress,
                    measuredChapterIndexes: measuredIndexes
                )
                let total = model.paginatedSettings?.totalPages ?? pagesPerChapter.reduce(0, +)
                lines.append("")
                lines.append("summary\tstatus=\(measuredTotal == chapterCount ? "complete" : "partial")\tmeasured=\(measuredTotal)/\(chapterCount)\tnewThisRun=\(measuredThisRun)\ttotal=\(total)\tcacheKey=\(model.paginationKey.font.rawValue)-\(model.paginationKey.fontSize)")
                lines.append(contentsOf: exactPaginationWordsPerPageLines(pagesPerChapter: pagesPerChapter, measuredIndexes: measuredIndexes))
                pageAuditLog = lines.joined(separator: "\n")
            }

            if let restoreLocator {
                pendingLocatorJSON = restoreLocator
            }
            isPageAuditRunning = false
            pageAuditTask = nil
        }
    }

    private func requestAutomaticHiddenPaginationIfNeeded() {
        guard model.settings.pageCountMode == .paginatedBook,
              model.epubURL != nil,
              model.readiumChapterPageState != nil,
              !showSettings,
              !showContents,
              !showSearch,
              !isPageAuditRunning,
              !hiddenPaginationRunning,
              automaticHiddenPaginationResumeTask == nil,
              let settings = model.paginatedSettings
        else { return }

        let chapterCount = model.paginationChapterCount
        guard chapterCount > 0 else { return }

        let measuredCount = Set(settings.measuredChapterIndexes ?? []).filter { $0 >= 0 && $0 < chapterCount }.count
        let hasMeasuredWords = book?.hasCompleteMeasuredWords(in: settings) ?? false
        guard measuredCount < chapterCount || !hasMeasuredWords else { return }

        let key = model.paginationKey
        guard !automaticHiddenPaginationAttemptedKeys.contains(key) else { return }
        automaticHiddenPaginationAttemptedKeys.insert(key)
        startHiddenExactPaginationBuild(manual: false)
    }

    private func startHiddenExactPaginationBuild(manual: Bool = true) {
        guard model.epubURL != nil, !isPageAuditRunning, !hiddenPaginationRunning else { return }
        let chapterCount = model.paginationChapterCount
        guard chapterCount > 0 else { return }

        pageAuditTask?.cancel()
        hiddenPaginationTimeoutTask?.cancel()
        isPageAuditRunning = true
        hiddenPaginationRunning = true
        hiddenPaginationNavigatorReady = false

        var pagesPerChapter = model.paginatedSettings?.pagesPerChapter ?? Array(repeating: 1, count: chapterCount)
        if pagesPerChapter.count != chapterCount {
            pagesPerChapter = Array(repeating: 1, count: chapterCount)
        }
        var measuredIndexes = Set(model.paginatedSettings?.measuredChapterIndexes ?? [])
        if measuredIndexes.isEmpty,
           let measuredChapterIndex = model.paginatedSettings?.measuredChapterIndex,
           measuredChapterIndex >= 0 {
            measuredIndexes.insert(measuredChapterIndex)
        }
        measuredIndexes = measuredIndexes.filter { $0 >= 0 && $0 < chapterCount }
        let missing = (0..<chapterCount).filter { !measuredIndexes.contains($0) }
        let chaptersToMeasure = missing.isEmpty ? Array(0..<chapterCount) : missing

        hiddenPaginationPagesPerChapter = pagesPerChapter
        hiddenPaginationMeasuredIndexes = measuredIndexes
        hiddenPaginationChaptersToMeasure = chaptersToMeasure
        hiddenPaginationMeasuredThisRun = 0
        hiddenPaginationLines = ["BookMark Hidden Exact Pagination Build"] + pageAuditMetadataLines + [
            "trigger\t\(manual ? "manual" : "automatic")",
            "chapterCount\t\(chapterCount)",
            "resumeFromMeasured\t\(measuredIndexes.count)",
            "chaptersToMeasure\t\(chaptersToMeasure.count)",
            "",
            "chapterIndex\tstatus\tpages\twords\tnote"
        ]
        pageAuditLog = hiddenPaginationLines.joined(separator: "\n")
    }

    private func advanceHiddenPagination() {
        hiddenPaginationTimeoutTask?.cancel()
        guard hiddenPaginationRunning else { return }
        guard hiddenPaginationNavigatorReady else { return }

        guard let chapterIndex = hiddenPaginationChaptersToMeasure.first else {
            finishHiddenPagination(cancelled: false)
            return
        }

        hiddenPaginationTargetChapter = chapterIndex
        hiddenPaginationPendingChapterJump = ReadiumChapterJump(chapterIndex: chapterIndex)
        hiddenPaginationTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard hiddenPaginationRunning,
                  hiddenPaginationTargetChapter == chapterIndex,
                  hiddenPaginationChaptersToMeasure.first == chapterIndex
            else { return }

            let fallback = hiddenPaginationPagesPerChapter.indices.contains(chapterIndex)
                ? max(1, hiddenPaginationPagesPerChapter[chapterIndex])
                : 1
            if hiddenPaginationPagesPerChapter.indices.contains(chapterIndex) {
                hiddenPaginationPagesPerChapter[chapterIndex] = fallback
            }
            hiddenPaginationMeasuredIndexes.insert(chapterIndex)
            hiddenPaginationMeasuredThisRun += 1
            hiddenPaginationLines.append("\(chapterIndex)\tinferred\t\(fallback)\t\(chapterWordsText(chapterIndex))\tviewportTimeoutFallback")
            pageAuditLog = hiddenPaginationLines.joined(separator: "\n")
            hiddenPaginationChaptersToMeasure.removeFirst()
            advanceHiddenPagination()
        }
    }

    private func handleHiddenPaginationPageState(_ state: ReadiumChapterPageState?) {
        guard hiddenPaginationRunning,
              let state,
              let target = hiddenPaginationTargetChapter,
              state.resourceIndex == target,
              hiddenPaginationChaptersToMeasure.first == target
        else { return }

        hiddenPaginationTimeoutTask?.cancel()
        if hiddenPaginationPagesPerChapter.indices.contains(target) {
            hiddenPaginationPagesPerChapter[target] = max(1, state.totalPages)
        }
        hiddenPaginationMeasuredIndexes.insert(target)
        hiddenPaginationMeasuredThisRun += 1
        hiddenPaginationLines.append("\(target)\tmeasured\t\(state.totalPages)\t\(chapterWordsText(target))\thidden")
        pageAuditLog = hiddenPaginationLines.joined(separator: "\n")
        hiddenPaginationChaptersToMeasure.removeFirst()
        advanceHiddenPagination()
    }

    private func finishHiddenPagination(cancelled: Bool) {
        hiddenPaginationTimeoutTask?.cancel()
        hiddenPaginationTimeoutTask = nil

        if !hiddenPaginationMeasuredIndexes.isEmpty, !hiddenPaginationPagesPerChapter.isEmpty {
            let chapterCount = hiddenPaginationPagesPerChapter.count
            let measuredTotal = hiddenPaginationMeasuredIndexes.count
            let progress = Double(measuredTotal) / Double(max(1, chapterCount))
            model.applyExactPaginatedSettings(
                pagesPerChapter: hiddenPaginationPagesPerChapter,
                progress: progress,
                measuredChapterIndexes: hiddenPaginationMeasuredIndexes
            )
            if let settings = model.paginatedSettings {
                store.updatePaginationCache(bookId: bookId, key: model.paginationKey, settings: settings)
            }
            let total = model.paginatedSettings?.totalPages ?? hiddenPaginationPagesPerChapter.reduce(0, +)
            hiddenPaginationLines.append("")
            hiddenPaginationLines.append("summary\tstatus=\(cancelled ? "cancelled" : (measuredTotal == chapterCount ? "complete" : "partial"))\tmeasured=\(measuredTotal)/\(chapterCount)\tnewThisRun=\(hiddenPaginationMeasuredThisRun)\ttotal=\(total)\tcacheKey=\(model.paginationKey.font.rawValue)-\(model.paginationKey.fontSize)")
            hiddenPaginationLines.append(contentsOf: exactPaginationWordsPerPageLines(pagesPerChapter: hiddenPaginationPagesPerChapter, measuredIndexes: hiddenPaginationMeasuredIndexes))
            pageAuditLog = hiddenPaginationLines.joined(separator: "\n")
        }

        hiddenPaginationRunning = false
        hiddenPaginationNavigatorReady = false
        hiddenPaginationPendingChapterJump = nil
        hiddenPaginationTargetChapter = nil
        hiddenPaginationChaptersToMeasure = []
        hiddenPaginationMeasuredThisRun = 0
        isPageAuditRunning = false
        pageAuditTask = nil
    }

    private func chapterWords(_ chapterIndex: Int) -> Int? {
        guard let counts = book?.wordCountsPerSpine,
              counts.indices.contains(chapterIndex),
              counts[chapterIndex] > 0
        else { return nil }
        return counts[chapterIndex]
    }

    private func chapterWordsText(_ chapterIndex: Int) -> String {
        chapterWords(chapterIndex).map(String.init) ?? ""
    }

    private func exactPaginationWordsPerPageLines(pagesPerChapter: [Int], measuredIndexes: Set<Int>) -> [String] {
        var lines = [
            "",
            "Words Per Page",
            "chapterIndex\twords\tpages\twordsPerPage"
        ]
        var samples: [Double] = []

        for index in measuredIndexes.sorted() where pagesPerChapter.indices.contains(index) {
            let pages = max(1, pagesPerChapter[index])
            guard let words = chapterWords(index) else {
                lines.append("\(index)\t\t\(pages)\t")
                continue
            }

            let wordsPerPage = Double(words) / Double(pages)
            samples.append(wordsPerPage)
            lines.append("\(index)\t\(words)\t\(pages)\t\(String(format: "%.2f", wordsPerPage))")
        }

        guard !samples.isEmpty else {
            lines.append("summary\tstatus=noWordCounts")
            return lines
        }

        let average = samples.reduce(0, +) / Double(samples.count)
        let rounded = ReaderSettings.clampedWordsPerPage(Int((average / 5.0).rounded() * 5.0))
        lines.append("summary\tsamples=\(samples.count)\tchapterAverage=\(String(format: "%.2f", average))\trounded=\(rounded)")
        return lines
    }

    private func waitForAuditStartChapter() async {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            try? await Task.sleep(nanoseconds: 80_000_000)
            if model.readiumResourceIndex == 0 && model.readiumChapterPageState?.resourceIndex == 0 {
                try? await Task.sleep(nanoseconds: 160_000_000)
                return
            }
        } while Date() < deadline && !Task.isCancelled
    }

    private func waitForChapterPageState(_ chapterIndex: Int) async -> ReadiumChapterPageState? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let state = model.readiumChapterPageState, state.resourceIndex == chapterIndex {
                try? await Task.sleep(nanoseconds: 120_000_000)
                return model.readiumChapterPageState?.resourceIndex == chapterIndex ? model.readiumChapterPageState : state
            }
        } while Date() < deadline && !Task.isCancelled
        return nil
    }

    private func waitForAuditTurn(
        request: ReadiumDiagnosticPageTurnRequest,
        beforeLocator: String?,
        beforeProgress: Double
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        var navigatorAcceptedTurn: Bool?
        repeat {
            try? await Task.sleep(nanoseconds: 80_000_000)
            if diagnosticPageTurnResult?.requestID == request.id {
                navigatorAcceptedTurn = diagnosticPageTurnResult?.moved ?? false
            }
            if model.readiumLocatorJSON != beforeLocator || abs(model.overallProgress - beforeProgress) > 0.00001 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                return true
            }
            if navigatorAcceptedTurn == false {
                return false
            }
        } while Date() < deadline && !Task.isCancelled
        return false
    }

    private func stopPageAudit() {
        pageAuditTask?.cancel()
        pageAuditTask = nil
        if hiddenPaginationRunning {
            finishHiddenPagination(cancelled: true)
            return
        }
        isPageAuditRunning = false
    }

    private func stopHiddenPaginationForReaderExit() {
        automaticHiddenPaginationResumeTask?.cancel()
        automaticHiddenPaginationResumeTask = nil
        guard hiddenPaginationRunning else { return }
        pageAuditTask?.cancel()
        pageAuditTask = nil
        finishHiddenPagination(cancelled: true)
    }

    private func handlePageAuditDismiss() {
        if hiddenPaginationRunning {
            return
        }
        stopPageAudit()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                elapsed += 1
                store.updateLiveReadingSession(
                    bookId: bookId,
                    elapsedSeconds: elapsed,
                    progressPct: model.overallProgress,
                    cfi: model.readiumLocatorJSON
                )
                maybeShowGoalCelebration()
            }
        }
    }

    private func maybeShowGoalCelebration() {
        guard !goalCelebrationShown, !goalMetAtSessionStart, readingGoalMet else { return }
        goalCelebrationShown = true
        goalCelebrationTask?.cancel()

        withAnimation(.easeInOut(duration: 0.4)) {
            showGoalCelebration = true
        }

        goalCelebrationTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showGoalCelebration = false
                }
            }
        }
    }

    /// Once per reader open: when the user crosses ~99% of the book, prompt
    /// them with the Finish-Date sheet so they can record completion.
    /// (Matches the webapp's `endPromptShown` gating.)
    private func maybePromptFinish() {
        guard !endPromptShown else { return }
        guard let book = book, !book.finished else { return }
        if model.overallProgress >= 0.995 {
            endPromptShown = true
            finishPromptTarget = book
        }
    }

    private func saveSession() {
        guard !sessionSaved, let book, elapsed >= 5 else { return }
        sessionSaved = true
        let pagesRead: Int = {
            if model.epubURL != nil {
                return model.readiumSessionPagesRead
            }
            guard let startPage = sessionStartPage else { return 0 }
            return max(0, model.estimatedBookPage - startPage)
        }()
        guard pagesRead > 0 else { return }

        let progressDelta: Double = {
            let totalPages = model.epubURL != nil
                ? (model.paginatedSettings?.totalPages ?? model.displayPageTotal)
                : model.estimatedBookPages
            guard totalPages > 0 else { return 0 }
            return max(0, min(1, Double(pagesRead) / Double(totalPages)))
        }()

        let publisherPagesRead: Int? = {
            guard model.epubURL != nil,
                  let startPage = sessionStartPublisherPage,
                  let endPage = model.readiumPublisherPage
            else { return nil }
            let delta = endPage - startPage
            return delta > 0 ? delta : nil
        }()
        // Device-independent words-read delta. Nil for sessions on books that
        // haven't been word-counted yet (legacy library awaiting backfill, or
        // a corrupt EPUB that didn't parse).
        let wordsRead: Int? = {
            guard model.epubURL != nil,
                  let start = sessionStartWordOffset,
                  let end = model.currentWordOffset
            else { return nil }
            let delta = end - start
            return delta > 0 ? delta : nil
        }()
        let sessionWordsPerPage = model.readiumSessionWordsPerPage ?? resolvedWordsPerPageForReaderContext
        let pageBasedWordsPerMinute = ReadingSession.calculatedWordsPerMinute(
            wordsRead: nil,
            pages: pagesRead > 0 ? pagesRead : nil,
            seconds: elapsed,
            wordsPerPage: sessionWordsPerPage
        )
        let session = ReadingSession(
            bookId: book.id,
            bookTitle: book.title,
            start: sessionStartedAt,
            end: Date(),
            secs: elapsed,
            pages: pagesRead > 0 ? pagesRead : nil,
            publisherPages: publisherPagesRead,
            wordsRead: wordsRead,
            wordsPerMinute: pageBasedWordsPerMinute,
            wordsPerPage: sessionWordsPerPage,
            progressDelta: progressDelta > 0 ? progressDelta : nil,
            manual: false
        )
        store.endLiveReadingSession(bookId: book.id)
        store.addSession(session)
    }

    private func captureSessionStartIfNeeded() {
        if sessionStartProgress == nil {
            sessionStartProgress = model.overallProgress
        }
        if sessionStartPage == nil {
            sessionStartPage = model.epubURL != nil ? model.displayPage : model.estimatedBookPage
        }
        if sessionStartPublisherPage == nil {
            sessionStartPublisherPage = model.readiumPublisherPage
        }
        // Capture the word offset on the first valid Readium location, so
        // saveSession() can compute a device-independent words-read delta.
        if sessionStartWordOffset == nil, let offset = model.currentWordOffset {
            sessionStartWordOffset = offset
        }
    }

    private func close() {
        timer?.invalidate()
        let sessionElapsed = elapsed
        saveSession()
        dismiss()
        if sessionElapsed > 0 {
            onCloseWithElapsed(sessionElapsed)
        }
    }

    private func load() async {
        guard let book = book else {
            model.error = "Book not found"; return
        }
        guard let fileName = book.fileName else {
            model.error = "Missing EPUB file."; return
        }

        let url = Store.epubsDirectory().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            model.error = "Could not read EPUB at \(url.lastPathComponent)."; return
        }

        model.settings = store.readerSettings
        model.readiumProgress = store.progress[book.id]?.pct ?? 0
        // Seed the word-count lookup so currentWordOffset works from the
        // first Readium location callback. Stays nil for books awaiting
        // backfill — in that case wordsRead simply won't be recorded for
        // this session, and the rest of the reader behaves normally.
        model.wordCountsPerSpine = book.wordCountsPerSpine
        model.totalWords = book.totalWords
        model.resetReadiumSessionMetrics()
        model.hydratePaginatedSettings(book.paginationCache?[model.paginationKey])
        sessionStartProgress = nil
        sessionStartPage = nil
        sessionStartPublisherPage = nil
        sessionStartWordOffset = nil
        model.epubURL = url
        store.beginLiveReadingSession(
            bookId: book.id,
            progressPct: model.readiumProgress,
            cfi: store.progress[book.id]?.cfi
        )

        if let data = try? Data(contentsOf: url), let pkg = EPUBPackage.open(data: data), !pkg.spine.isEmpty {
            model.package = pkg
            model.chapterPageCounts = Array(repeating: 0, count: pkg.spine.count)
        }
    }
}

private struct BrowserURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ReaderBrowserSheet: View {
    let url: URL

    var body: some View {
        SafariReaderView(url: url)
            .ignoresSafeArea()
    }
}

private struct SafariReaderView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private struct ReaderPageAuditSheet: View {
    @ObservedObject var model: ReaderModel
    let log: String
    let isRunning: Bool
    let onRunFromCurrent: () -> Void
    let onRunFromStart: () -> Void
    let onBuildExactPagination: () -> Void
    let onBuildHiddenExactPagination: () -> Void
    let onAutoWordsPerPageDebug: () -> Void
    let onStartChromeTrace: () -> Void
    let onLoadChromeTrace: () -> Void
    let onStop: () -> Void
    let onClear: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            Grabber()
            header
            controls
            Divider().opacity(0.4)
            logView
        }
        .background(model.theme.backgroundColor)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Page Audit")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(model.theme.foregroundColor)
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.theme.secondaryForeground)
                    .lineLimit(2)
            }
            Spacer()
            if isRunning {
                ProgressView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    onRunFromCurrent()
                } label: {
                    Label("Run Forward", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isRunning)

                Button {
                    onRunFromStart()
                } label: {
                    Label("From Start", systemImage: "backward.end.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isRunning)
            }

            Button {
                onBuildExactPagination()
            } label: {
                Label("Build Exact Pagination", systemImage: "ruler")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isRunning || model.epubURL == nil)

            HStack(spacing: 8) {
                Button {
                    onBuildHiddenExactPagination()
                } label: {
                    Label("Build Hidden Exact", systemImage: "eye.slash")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isRunning || model.epubURL == nil)

                Button {
                    onAutoWordsPerPageDebug()
                } label: {
                    Label("Auto WPP Debug", systemImage: "text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isRunning || model.epubURL == nil)
            }

            // Live chrome trace — records the "pages left in part/chapter"
            // line and the state feeding it on every page turn. Start it,
            // close this sheet, reproduce the bug (e.g. Realistic mode into
            // a Part's first chapter), reopen, then Load Trace + Share.
            HStack(spacing: 8) {
                if model.isChromeTracing {
                    Button {
                        onLoadChromeTrace()
                    } label: {
                        Label("Stop & Load Trace", systemImage: "record.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                } else {
                    Button {
                        onStartChromeTrace()
                    } label: {
                        Label("Start Chrome Trace", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isRunning || model.epubURL == nil)
                }
            }

            if model.isChromeTracing {
                Text("Tracing chrome… close this sheet, turn pages to reproduce, then reopen and tap Stop & Load Trace.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.theme.secondaryForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    onStop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!isRunning)

                Button {
                    UIPasteboard.general.string = log
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .disabled(log.isEmpty)

                ShareLink(item: log) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .disabled(log.isEmpty)

                Button {
                    didCopy = false
                    onClear()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isRunning || log.isEmpty)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var logView: some View {
        ScrollView {
            Text(log.isEmpty ? "Run the audit to collect page-order data." : log)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(log.isEmpty ? model.theme.secondaryForeground : model.theme.foregroundColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    private var statusText: String {
        if isRunning {
            if log.hasPrefix("BookMark Hidden Exact Pagination Build") {
                return "Measuring chapters with an invisible foreground navigator."
            }
            if log.hasPrefix("BookMark Exact Pagination Build") {
                return "Walking chapters and capturing exact viewport page totals."
            }
            return "Forcing no-animation page turns and recording observed page order."
        }
        if let total = model.paginatedSettings?.totalPages {
            let measured = model.paginatedMeasuredChapterCount
            let chapters = model.paginationChapterCount
            let status = model.paginatedSettingsIsComplete ? "Exact" : "Estimated"
            let totalText = model.paginatedBookTotalText(total)
            let coverage = chapters > 0 ? " · \(measured)/\(chapters) chapters" : ""
            return "\(status) total: \(totalText). Current: \(model.paginatedBookCurrentPage.map(String.init) ?? "unknown")\(coverage)."
        }
        return "Open a paginated EPUB page first so the generated total exists."
    }
}

// MARK: - Theme

enum ReaderThemePalette {
    static func resolve(_ t: ReaderTheme, colorScheme: ColorScheme? = nil) -> Palette {
        switch t {
        case .device:
            let isDark = colorScheme.map { $0 == .dark } ?? (UITraitCollection.current.userInterfaceStyle == .dark)
            return resolve(isDark ? .night : .original, colorScheme: colorScheme)
        case .original: return Palette(bg: 0xFFFFFF, fg: 0x1A1A1A, sub: 0x7A7D86, accent: 0x2D6A4F, link: 0x0B57D0, isDark: false)
        case .quiet:    return Palette(bg: 0xF2E8D5, fg: 0x3D2E1E, sub: 0x786957, accent: 0x7A5C2E, link: 0x7A5C2E, isDark: false)
        case .paper:    return Palette(bg: 0xFBF8F2, fg: 0x1A1A1A, sub: 0x7A7D86, accent: 0x2D6A4F, link: 0x2D6A4F, isDark: false)
        case .calm:     return Palette(bg: 0xE8EBEF, fg: 0x2B3440, sub: 0x76808E, accent: 0x3E5C8A, link: 0x3E5C8A, isDark: false)
        case .focus:    return Palette(bg: 0x23252A, fg: 0xE8E8EC, sub: 0x9A9AA4, accent: 0x9DB8E8, link: 0x9DB8E8, isDark: true)
        case .night:    return Palette(bg: 0x000000, fg: 0xD9D9DE, sub: 0x7E7E88, accent: 0x8FA8D8, link: 0x8FA8D8, isDark: true)
        }
    }

    struct Palette {
        var bg: UInt32
        var fg: UInt32
        var sub: UInt32
        var accent: UInt32
        var link: UInt32
        var isDark: Bool

        var bgHex: String { String(format: "#%06X", bg) }
        var fgHex: String { String(format: "#%06X", fg) }
        var subHex: String { String(format: "#%06X", sub) }
        var accentHex: String { String(format: "#%06X", accent) }
        var linkHex: String { String(format: "#%06X", link) }

        var backgroundColor: Color { Color(red: ch(bg, 16), green: ch(bg, 8), blue: ch(bg, 0)) }
        var foregroundColor: Color { Color(red: ch(fg, 16), green: ch(fg, 8), blue: ch(fg, 0)) }
        var secondaryForeground: Color { Color(red: ch(sub, 16), green: ch(sub, 8), blue: ch(sub, 0)) }
        var accentColor: Color { Color(red: ch(accent, 16), green: ch(accent, 8), blue: ch(accent, 0)) }
        var panelMaterial: AnyShapeStyle {
            isDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial)
        }

        private func ch(_ v: UInt32, _ shift: UInt32) -> Double {
            Double((v >> shift) & 0xFF) / 255.0
        }
    }
}

// MARK: - Reader chrome / TOC section logic
//
// Pure, dependency-free computation of the reader's "pages left in
// part / chapter" chrome text and the underlying TOC section range.
// Extracted from `ReaderModel` so the part-vs-chapter decision — the
// source of the Realistic-mode flicker when crossing into a Part's
// first chapter — can be unit-tested deterministically without a live
// navigator. `ReaderModel` builds the `[TOCRow]` from its package and
// delegates the decision here.
enum ReaderChromeLogic {
    struct TOCRow: Equatable {
        let offset: Int
        let title: String
        let href: String
        let chapterIndex: Int
        let depth: Int
    }

    struct SectionRange: Equatable {
        let kind: String
        let startPage: Int
        let endPage: Int
    }

    static func normalizedHref(_ href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        return decoded
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sectionKind(for title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("interlude") { return "interlude" }
        if lower.hasPrefix("part ") { return "part" }
        return "section"
    }

    /// A TOC row "starts a section" when it has children deeper than itself
    /// before the next peer, or its title reads like a Part/Interlude divider.
    static func rowIsSectionStart(_ row: TOCRow, rows: [TOCRow]) -> Bool {
        let nextPeerOffset = rows.first { candidate in
            candidate.offset > row.offset && candidate.depth <= row.depth
        }?.offset ?? Int.max
        if rows.contains(where: { $0.offset > row.offset && $0.offset < nextPeerOffset && $0.depth > row.depth }) {
            return true
        }
        let lower = row.title.lowercased()
        return lower.hasPrefix("part ") || lower == "interludes" || lower.hasPrefix("interlude")
    }

    static func sectionEndChapterIndex(for row: TOCRow, rows: [TOCRow], chapterCount: Int) -> Int {
        let nextPeer = rows.first { candidate in
            candidate.offset > row.offset && candidate.depth <= row.depth && candidate.chapterIndex > row.chapterIndex
        }
        let exclusiveEnd = nextPeer?.chapterIndex ?? chapterCount
        return max(row.chapterIndex, min(chapterCount - 1, exclusiveEnd - 1))
    }

    static func currentLocatorTOCRow(in rows: [TOCRow], locatorHref: String?, locatorJSON: String?) -> TOCRow? {
        let hrefText = locatorHref.map(normalizedHref) ?? ""
        let locatorJSON = locatorJSON ?? ""
        let matchingRows = rows.filter { row in
            let candidate = normalizedHref(row.href)
            return hrefText == candidate
                || hrefText.hasPrefix("\(candidate)#")
                || locatorJSON.contains(row.href)
                || locatorJSON.contains(candidate)
        }
        return matchingRows.max { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return normalizedHref(lhs.href).count < normalizedHref(rhs.href).count
        }
    }

    /// Resolve the global page range of the Part/section the reader is
    /// currently inside, or nil when the current resource is an ordinary
    /// chapter (which is what makes the chrome fall back to "pages left in
    /// chapter"). `currentResource` must be the resource the chrome should
    /// reflect — passing a stale value here is what produces the flicker.
    static func sectionRange(
        rows: [TOCRow],
        currentResource: Int,
        chapterPageOffsets: [Int],
        pagesPerChapter: [Int],
        totalPages: Int,
        locatorHref: String?,
        locatorJSON: String?
    ) -> SectionRange? {
        guard pagesPerChapter.indices.contains(currentResource),
              chapterPageOffsets.indices.contains(currentResource)
        else { return nil }

        let locatorRow = currentLocatorTOCRow(in: rows, locatorHref: locatorHref, locatorJSON: locatorJSON)
        let candidateRow: TOCRow? = {
            if let locatorRow,
               rowIsSectionStart(locatorRow, rows: rows),
               locatorRow.chapterIndex == currentResource {
                return locatorRow
            }
            return rows.last { row in
                row.chapterIndex == currentResource && rowIsSectionStart(row, rows: rows)
            }
        }()
        guard let sectionRow = candidateRow else { return nil }

        let endChapter = sectionEndChapterIndex(for: sectionRow, rows: rows, chapterCount: pagesPerChapter.count)
        guard endChapter >= sectionRow.chapterIndex,
              chapterPageOffsets.indices.contains(endChapter),
              pagesPerChapter.indices.contains(endChapter)
        else { return nil }

        let startPage = chapterPageOffsets[sectionRow.chapterIndex] + 1
        let endPage = chapterPageOffsets[endChapter] + max(1, pagesPerChapter[endChapter])
        return SectionRange(
            kind: sectionKind(for: sectionRow.title),
            startPage: max(1, min(totalPages, startPage)),
            endPage: max(1, min(totalPages, endPage))
        )
    }

    static func sectionPagesLeftText(range: SectionRange?, currentPage: Int?) -> String? {
        guard let section = range,
              let currentPage,
              section.endPage >= section.startPage
        else { return nil }
        let left = max(0, section.endPage - currentPage)
        if left == 0 { return "End of \(section.kind)" }
        return "\(left) page\(left == 1 ? "" : "s") left in \(section.kind)"
    }
}

// MARK: - View model

@MainActor
final class ReaderModel: ObservableObject {
    @Published var package: EPUBPackage?
    @Published var epubURL: URL?
    @Published var settings = ReaderSettings()
    @Published var chapterIndex = 0
    @Published var currentPage = 1
    @Published var totalPages = 1
    @Published var chapterPageCounts: [Int] = []
    @Published var readiumProgress: Double = 0
    @Published var readiumPosition: Int?
    @Published var readiumTotalPositions: Int?
    @Published var readiumLocatorJSON: String?
    @Published var readiumLocatorHref: String?
    @Published var readiumResourceProgression: Double?
    @Published var readiumResourceIndex: Int?
    @Published var readiumResourceTotal: Int?
    @Published var readiumChapterPosition: Int?
    @Published var readiumChapterPositionTotal: Int?
    @Published var readiumChapterPageState: ReadiumChapterPageState?
    @Published private(set) var paginatedSettings: PaginatedSettings?
    @Published var readiumChapterTitle: String?
    @Published var readiumPublisherPage: Int?
    @Published var readiumPublisherPageLabel: String?
    @Published var readiumPublisherPageTotal: Int?
    @Published private var readiumDisplayIsReady = false
    @Published private(set) var readiumSessionPagesRead = 0
    private var readiumSessionPageWordEstimates: [Int] = []
    @Published private var displayPageOverride: Int?
    @Published private var paginatedPageOverride: Int?
    @Published private(set) var paginatedSettingsLoadedFromCache = false
    private var pendingReadiumPageTurnDirection: Int?
    private var pendingPaginatedPageTurnBase: Int?
    private var paginatedSettingsKey: PaginationKey?

    // MARK: Word-count tracking (Option 2)
    //
    // Hydrated from the open Book's `wordCountsPerSpine` so `currentWordOffset`
    // can convert a Readium locator into an absolute "words read so far" value
    // — the basis for cross-device WPM and standardized pages. Stays nil for
    // books imported before word counting existed (until backfill catches up).
    var wordCountsPerSpine: [Int]?
    var totalWords: Int?

    @Published var error: String?
    @Published var pendingInitialPage: InitialPage?
    @Published var suppressFirstPageUntilLastJump = false
    @Published var webIsReady = false

    // MARK: Chrome trace (Page Audit debug capture)
    //
    // A live recorder for the bottom/top chrome and the state that feeds it.
    // Capturing at every model mutation (location, chapter page state, turn
    // intent) reproduces the exact sequence SwiftUI renders, so the
    // part-vs-chapter flicker in Realistic mode shows up as consecutive lines
    // with differing `chapterText`. Off by default; near-zero cost when off.
    @Published var isChromeTracing = false
    @Published private(set) var chromeTrace: [String] = []
    private var chromeTraceStartedAt: Date?
    private var lastChromeTracePayload: String?
    private let chromeTraceMaxLines = 4000

    static let chromeTraceHeader = [
        "ms", "event", "anim", "countMode", "chapterText", "statusBottom",
        "sectionRange", "activeRes", "locRes", "cvPage", "cvTotal",
        "globalPage", "rawGlobal", "pgOverride", "pendDir", "locHref"
    ].joined(separator: "\t")

    func startChromeTrace() {
        chromeTrace = []
        lastChromeTracePayload = nil
        chromeTraceStartedAt = Date()
        isChromeTracing = true
        recordChromeTrace(event: "start", force: true)
    }

    func stopChromeTrace() {
        guard isChromeTracing else { return }
        recordChromeTrace(event: "stop", force: true)
        isChromeTracing = false
    }

    func chromeTraceText() -> String {
        ([ReaderModel.chromeTraceHeader] + chromeTrace).joined(separator: "\n")
    }

    /// Append one snapshot line. Identical consecutive payloads are collapsed
    /// (unless `force`) so the log highlights genuine transitions rather than
    /// repeated re-renders of the same state.
    func recordChromeTrace(event: String, force: Bool = false) {
        guard isChromeTracing else { return }
        let payload = chromeTracePayload()
        if !force, payload == lastChromeTracePayload { return }
        lastChromeTracePayload = payload
        let ms = chromeTraceStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        chromeTrace.append("\(ms)\t\(event)\t\(payload)")
        if chromeTrace.count > chromeTraceMaxLines {
            chromeTrace.removeFirst(chromeTrace.count - chromeTraceMaxLines)
        }
    }

    private func chromeTracePayload() -> String {
        let sectionText: String = currentTOCSectionRange.map { "\($0.kind):\($0.startPage)-\($0.endPage)" } ?? "nil"
        let hrefTail: String = {
            guard let href = readiumLocatorHref else { return "" }
            return String(href.suffix(34))
        }()
        let fields: [String] = [
            settings.pageAnim.rawValue,
            settings.pageCountMode.rawValue,
            chapterPagesLeftText,
            statusBottom,
            sectionText,
            activeReadiumResourceIndex.map(String.init) ?? "",
            readiumResourceIndex.map(String.init) ?? "",
            readiumChapterPageState.map { String($0.currentPage) } ?? "",
            readiumChapterPageState.map { String($0.totalPages) } ?? "",
            paginatedBookCurrentPage.map(String.init) ?? "",
            rawPaginatedBookCurrentPage.map(String.init) ?? "",
            paginatedPageOverride.map(String.init) ?? "nil",
            pendingReadiumPageTurnDirection.map(String.init) ?? "nil",
            hrefTail
        ]
        return fields.joined(separator: "\t")
    }

    enum InitialPage: Equatable {
        case first, last, page(Int)
    }

    var theme: ReaderThemePalette.Palette {
        ReaderThemePalette.resolve(settings.theme)
    }

    var currentChapterBody: String {
        guard let pkg = package else { return "" }
        return pkg.chapterBody(at: chapterIndex) ?? ""
    }

    var estimatedBookPage: Int {
        pagesBeforeCurrentChapter + currentPage
    }

    var readiumSessionEstimatedWordsRead: Int {
        readiumSessionPageWordEstimates.reduce(0, +)
    }

    var readiumSessionWordsPerPage: Int? {
        guard !readiumSessionPageWordEstimates.isEmpty else { return nil }
        let rawAverage = Double(readiumSessionEstimatedWordsRead) / Double(readiumSessionPageWordEstimates.count)
        return ReaderSettings.clampedWordsPerPage(Int((rawAverage / 5.0).rounded() * 5.0))
    }

    var estimatedBookPages: Int {
        guard let pkg = package, !pkg.spine.isEmpty else { return max(1, totalPages) }
        return max(1, estimatedChapterPageCounts.prefix(pkg.spine.count).reduce(0, +))
    }

    var pagesBeforeCurrentChapter: Int {
        guard chapterIndex > 0 else { return 0 }
        return estimatedChapterPageCounts.prefix(chapterIndex).reduce(0, +)
    }

    var overallProgress: Double {
        if epubURL != nil {
            return max(0, min(1, readiumProgress))
        }
        let total = max(1, estimatedBookPages)
        let page = max(1, min(total, estimatedBookPage))
        return min(1, max(0, Double(page - 1) / Double(max(1, total - 1))))
    }

    var statusBottom: String {
        if epubURL != nil {
            let percent = Int((overallProgress * 100).rounded())
            // Viewport-aware chapter mode — pulls from Readium's
            // NavigatorViewport, refreshes with font/spread changes.
            if settings.pageCountMode == .viewportChapter,
               let state = readiumChapterPageState {
                return "Page \(state.currentPage) of \(state.totalPages) in chapter · \(percent)%"
            }
            if settings.pageCountMode == .paginatedBook,
               let page = paginatedBookCurrentPage,
               let total = paginatedSettings?.totalPages {
                return "Page \(page) of \(paginatedBookTotalText(total)) · \(percent)%"
            }
            // Whole-book viewport estimate — refreshes whenever density
            // changes. Falls back to position mode if word counts or
            // chapter page state aren't ready yet (briefly at book open).
            if settings.pageCountMode == .viewportBook,
               let page = viewportBookCurrentPage,
               let total = viewportBookPageTotal {
                return "Page \(page) of \(total) · \(percent)%"
            }
            if let label = readiumPublisherPageLabel, let total = readiumPublisherPageTotal, total > 0 {
                return "Page \(label) of \(total) · \(percent)%"
            }
            // Visible page = Readium's raw position. The +1-per-swipe override
            // (`displayPageOverride`) still ticks in the background and is read
            // by `displayPage` for sessions/bookmarks — flipping the visible
            // bar back to the swipe counter is a one-liner here.
            return "Page \(rawDisplayPage) of \(displayPageTotal) · \(percent)%"
        }
        return "Page \(estimatedBookPage) of \(estimatedBookPages) · \(Int((overallProgress * 100).rounded()))%"
    }

    var pageOnlyText: String {
        if epubURL != nil {
            if settings.pageCountMode == .paginatedBook,
               let page = paginatedBookCurrentPage {
                return "Page \(page)"
            }
            if settings.pageCountMode == .viewportBook,
               let page = viewportBookCurrentPage {
                return "Page \(page)"
            }
            if let label = readiumPublisherPageLabel {
                return "Page \(label)"
            }
            return "Page \(rawDisplayPage)"
        }
        return "Page \(estimatedBookPage)"
    }

    var testCurlPageLabels: TestCurlPageLabels {
        if epubURL != nil {
            guard readiumDisplayIsReady else { return .empty }
            if settings.pageCountMode == .viewportChapter,
               let state = readiumChapterPageState {
                return TestCurlPageLabels(currentPage: state.currentPage, totalPages: state.totalPages)
            }
            if settings.pageCountMode == .paginatedBook,
               let page = paginatedBookCurrentPage {
                return TestCurlPageLabels(currentPage: page, totalPages: paginatedSettings?.totalPages)
            }
            if settings.pageCountMode == .viewportBook,
               let page = viewportBookCurrentPage {
                return TestCurlPageLabels(currentPage: page, totalPages: viewportBookPageTotal)
            }
            if let label = readiumPublisherPageLabel,
               let page = Int(label.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return TestCurlPageLabels(currentPage: page, totalPages: readiumPublisherPageTotal)
            }
            return TestCurlPageLabels(currentPage: rawDisplayPage, totalPages: displayPageTotal)
        }
        return TestCurlPageLabels(currentPage: estimatedBookPage, totalPages: estimatedBookPages)
    }

    var displayPageTotal: Int {
        max(1, readiumTotalPositions ?? estimatedBookPages)
    }

    var activeReadiumResourceIndex: Int? {
        guard let state = readiumChapterPageState else {
            return readiumResourceIndex
        }
        guard let locationIndex = readiumResourceIndex else {
            return state.resourceIndex
        }
        if locationIndex == state.resourceIndex {
            return locationIndex
        }
        if state.currentPage <= 1, locationIndex < state.resourceIndex {
            return state.resourceIndex
        }
        return locationIndex
    }

    var activeChapterProgression: Double? {
        if activeReadiumResourceIndex == readiumResourceIndex,
           let progression = readiumResourceProgression {
            return max(0, min(1, progression))
        }
        if let state = readiumChapterPageState,
           activeReadiumResourceIndex == state.resourceIndex,
           state.totalPages > 0 {
            let pageOffset = max(0, state.currentPage - 1)
            return max(0, min(1, Double(pageOffset) / Double(state.totalPages)))
        }
        guard let pos = readiumChapterPosition,
              let total = readiumChapterPositionTotal,
              total > 0
        else { return nil }
        return max(0, min(1, Double(pos) / Double(total)))
    }

    /// Read by session tracking (`saveSession`), bookmarks, and anything else
    /// that needs a stable swipe-driven counter. The visible status bar uses
    /// `rawDisplayPage` directly so the override doesn't smooth out Readium's
    /// natural per-swipe page jumps on iPad.
    var displayPage: Int {
        displayPageOverride ?? rawDisplayPage
    }

    var rawDisplayPage: Int {
        let fallback = Int(ceil(overallProgress * Double(displayPageTotal)))
        return boundedDisplayPage(readiumPosition ?? fallback)
    }

    var chapterPagesLeftText: String {
        if epubURL != nil {
            if let sectionText = sectionPagesLeftText {
                return sectionText
            }
            if let pageState = readiumChapterPageState,
               pageState.resourceIndex == activeReadiumResourceIndex,
               pageState.totalPages > 0 {
                let left = max(0, pageState.totalPages - pageState.currentPage)
                if left == 0 { return "End of chapter" }
                return "\(left) page\(left == 1 ? "" : "s") left in chapter"
            }
            if let pos = readiumChapterPosition, let total = readiumChapterPositionTotal, total > 0 {
                let left = max(0, total - pos)
                if left == 0 { return "End of chapter" }
                return "\(left) page\(left == 1 ? "" : "s") left in chapter"
            }
            return "Reading"
        }
        let left = max(0, totalPages - currentPage)
        if left == 0 { return "End of chapter" }
        return "\(left) page\(left == 1 ? "" : "s") left in chapter"
    }

    private var sectionPagesLeftText: String? {
        ReaderChromeLogic.sectionPagesLeftText(
            range: currentTOCSectionRange,
            currentPage: paginatedBookCurrentPage
        )
    }

    private var estimatedChapterPageCounts: [Int] {
        guard let pkg = package else { return [max(1, totalPages)] }
        let fallback = max(1, totalPages)
        return pkg.spine.indices.map { idx in
            if chapterPageCounts.indices.contains(idx), chapterPageCounts[idx] > 0 {
                return chapterPageCounts[idx]
            }
            return fallback
        }
    }

    func expectReadiumPageTurn(_ direction: Int) {
        if direction == 0 {
            pendingReadiumPageTurnDirection = nil
            pendingPaginatedPageTurnBase = nil
            recordChromeTrace(event: "turnIntent:0", force: true)
            return
        }
        pendingReadiumPageTurnDirection = direction > 0 ? 1 : -1
        pendingPaginatedPageTurnBase = paginatedBookCurrentPage
        recordChromeTrace(event: "turnIntent:\(direction > 0 ? 1 : -1)", force: true)
    }

    func resetReadiumSessionMetrics() {
        readiumSessionPagesRead = 0
        readiumSessionPageWordEstimates = []
        pendingReadiumPageTurnDirection = nil
        pendingPaginatedPageTurnBase = nil
        readiumDisplayIsReady = false
        displayPageOverride = nil
        paginatedPageOverride = nil
        readiumPosition = nil
        readiumTotalPositions = nil
        readiumLocatorJSON = nil
        readiumLocatorHref = nil
        readiumResourceProgression = nil
        readiumResourceIndex = nil
        readiumResourceTotal = nil
        readiumChapterPosition = nil
        readiumChapterPositionTotal = nil
        readiumChapterPageState = nil
        paginatedSettings = nil
        paginatedSettingsKey = nil
        paginatedSettingsLoadedFromCache = false
        readiumChapterTitle = nil
        readiumPublisherPage = nil
        readiumPublisherPageLabel = nil
        readiumPublisherPageTotal = nil
    }

    func invalidatePaginatedSettings() {
        paginatedSettings = nil
        paginatedSettingsKey = nil
        paginatedSettingsLoadedFromCache = false
        paginatedPageOverride = nil
        pendingPaginatedPageTurnBase = nil
    }

    func updateReadiumChapterPageState(_ state: ReadiumChapterPageState?) {
        readiumChapterPageState = state
        readiumDisplayIsReady = state != nil
        if let idx = state?.resourceIndex {
            chapterIndex = idx
        }
        refreshPaginatedSettingsIfNeeded(from: state)
        if paginatedPageOverride == nil {
            paginatedPageOverride = rawPaginatedBookCurrentPage
        }
        recordChromeTrace(event: "chapterState")
    }

    func updateReadiumLocation(_ location: ReadiumLocation) {
        defer { recordChromeTrace(event: "location") }
        let oldProgress = readiumProgress
        let oldPage = displayPageOverride ?? rawDisplayPage
        let oldPaginatedPage = pendingPaginatedPageTurnBase ?? paginatedBookCurrentPage
        let oldResourceIndex = readiumResourceIndex
        let oldLocator = readiumLocatorJSON
        let expectedDirection = pendingReadiumPageTurnDirection

        readiumProgress = max(0, min(1, location.totalProgress))
        readiumLocatorJSON = location.locatorJSON
        readiumLocatorHref = location.locatorHref
        readiumResourceProgression = location.resourceProgression
        readiumPosition = location.bookPosition
        readiumTotalPositions = location.bookPositionTotal
        readiumResourceIndex = location.resourceIndex
        readiumResourceTotal = location.resourceTotal
        readiumChapterPosition = location.chapterPosition
        readiumChapterPositionTotal = location.chapterPositionTotal
        readiumChapterTitle = location.chapterTitle
        readiumPublisherPage = location.publisherPage
        readiumPublisherPageLabel = location.publisherPageLabel
        readiumPublisherPageTotal = location.publisherPageTotal
        if let state = location.chapterPageState {
            readiumChapterPageState = state
            readiumDisplayIsReady = true
            chapterIndex = state.resourceIndex
            refreshPaginatedSettingsIfNeeded(from: state)
            if paginatedPageOverride == nil {
                paginatedPageOverride = rawPaginatedBookCurrentPage
            }
        } else if let idx = location.resourceIndex {
            chapterIndex = idx
            if readiumChapterPageState?.resourceIndex != idx {
                readiumChapterPageState = nil
                readiumDisplayIsReady = false
            }
        }

        let estimated = boundedDisplayPage(location.bookPosition ?? rawDisplayPage)
        guard oldLocator != location.locatorJSON else {
            if displayPageOverride == nil {
                displayPageOverride = estimated
            }
            if paginatedPageOverride == nil {
                paginatedPageOverride = rawPaginatedBookCurrentPage
            }
            return
        }

        pendingReadiumPageTurnDirection = nil
        pendingPaginatedPageTurnBase = nil
        if let expectedDirection {
            displayPageOverride = boundedDisplayPage(oldPage + expectedDirection)
            if let oldPaginatedPage {
                paginatedPageOverride = boundedPaginatedBookPage(oldPaginatedPage + expectedDirection)
            }
            if expectedDirection > 0 {
                let sampleChapter = oldResourceIndex ?? location.resourceIndex
                if let sampleChapter,
                   let wordsPerPage = roundedWordsPerPageEstimate(for: sampleChapter) {
                    readiumSessionPageWordEstimates.append(wordsPerPage)
                }
            } else if expectedDirection < 0, !readiumSessionPageWordEstimates.isEmpty {
                readiumSessionPageWordEstimates.removeLast()
            }
            // Allow the counter to go negative so that turning backward N pages
            // and then forward N pages nets to 0 (the reader is back where they
            // started). Clamping at 0 here caused backward-first navigation to
            // be "forgotten", then double-counted on the way forward. The save
            // path clamps with `max(0, …)` so a net-negative session simply
            // records no pages read.
            readiumSessionPagesRead += expectedDirection
        } else if readiumProgress > oldProgress {
            displayPageOverride = boundedDisplayPage(max(estimated, oldPage + 1))
            paginatedPageOverride = nil
        } else if readiumProgress < oldProgress {
            displayPageOverride = boundedDisplayPage(min(estimated, oldPage - 1))
            paginatedPageOverride = nil
        } else {
            displayPageOverride = estimated
            paginatedPageOverride = nil
        }
    }

    private func boundedDisplayPage(_ page: Int) -> Int {
        max(1, min(displayPageTotal, page))
    }

    private func roundedWordsPerPageEstimate(for chapterIndex: Int) -> Int? {
        guard let counts = wordCountsPerSpine,
              counts.indices.contains(chapterIndex),
              counts[chapterIndex] > 0,
              let settings = paginatedSettings,
              settings.pagesPerChapter.indices.contains(chapterIndex)
        else { return nil }
        let pages = max(1, settings.pagesPerChapter[chapterIndex])
        let raw = Double(counts[chapterIndex]) / Double(pages)
        return ReaderSettings.clampedWordsPerPage(Int((raw / 5.0).rounded() * 5.0))
    }

    /// Convert the current Readium location into an absolute word offset
    /// across the whole book. Returns nil if the book hasn't been word-counted
    /// yet (legacy books awaiting backfill, or the parser failed). Uses
    /// `resourceIndex` for the chapter and `chapterPosition / chapterPositionTotal`
    /// as the within-chapter progression, so the result is content-based and
    /// stays the same on iPhone, iPad, and at any font size.
    var currentWordOffset: Int? {
        guard let counts = wordCountsPerSpine,
              let idx = activeReadiumResourceIndex,
              counts.indices.contains(idx)
        else { return nil }
        let before = counts.prefix(idx).reduce(0, +)
        let inChapter: Int = {
            guard let progression = activeChapterProgression else { return 0 }
            return Int((Double(counts[idx]) * progression).rounded())
        }()
        return before + inChapter
    }

    // MARK: Viewport-based whole-book pagination (Apple Books-style)
    //
    // Combines word counts (content-derived) with Readium's viewport-aware
    // chapter page count to produce a dynamic whole-book total that updates
    // whenever font / spread / device changes. The estimate uses the CURRENT
    // chapter's density, so chapters with very different content shapes
    // (image-heavy front matter, dense academic prose) can shift the total
    // when you cross into them. This matches Apple Books' early behavior.

    /// Words that fit on one visible page at the current settings, inferred
    /// from the current chapter. Nil when there's no chapter page state yet
    /// or the book hasn't been word-counted.
    var wordsPerViewportPage: Double? {
        guard let counts = wordCountsPerSpine,
              let idx = activeReadiumResourceIndex,
              counts.indices.contains(idx),
              let state = readiumChapterPageState,
              state.totalPages > 0
        else { return nil }
        let chapterWords = counts[idx]
        guard chapterWords > 0 else { return nil }
        return Double(chapterWords) / Double(state.totalPages)
    }

    /// Total visible pages across the whole book at current settings.
    /// Refreshes any time the viewport-aware density changes.
    var viewportBookPageTotal: Int? {
        guard let total = totalWords, total > 0,
              let density = wordsPerViewportPage, density > 0
        else { return nil }
        return max(1, Int(ceil(Double(total) / density)))
    }

    /// Current visible page across the whole book — i.e., where the user
    /// is in the projected total.
    var viewportBookCurrentPage: Int? {
        guard let total = viewportBookPageTotal,
              let offset = currentWordOffset,
              let density = wordsPerViewportPage, density > 0
        else { return nil }
        let page = Int((Double(offset) / density).rounded())
        return max(1, min(total, page))
    }

    // MARK: Stable single-density pagination

    var paginationKey: PaginationKey {
        PaginationKey(
            font: settings.font,
            fontSize: settings.fontSize,
            bold: settings.bold,
            lineHeight: settings.lineHeight,
            margins: settings.margins,
            justify: settings.justify,
            deviceClass: UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        )
    }

    var paginatedBookCurrentPage: Int? {
        guard paginatedSettingsKey == paginationKey else { return nil }
        return paginatedPageOverride ?? rawPaginatedBookCurrentPage
    }

    var paginationCacheHit: Bool {
        paginatedSettingsLoadedFromCache && paginatedSettingsKey == paginationKey && paginatedSettings != nil
    }

    var paginatedSettingsIsComplete: Bool {
        guard let settings = paginatedSettings,
              paginatedSettingsKey == paginationKey
        else { return false }
        let chapterCount = paginationChapterCount
        guard chapterCount > 0 else { return settings.progress >= 1 }
        return paginatedMeasuredChapterCount == chapterCount
    }

    var paginatedMeasuredChapterCount: Int {
        guard let settings = paginatedSettings,
              paginatedSettingsKey == paginationKey
        else { return 0 }
        let chapterCount = paginationChapterCount
        guard chapterCount > 0 else { return settings.progress >= 1 ? 1 : 0 }
        return Set(settings.measuredChapterIndexes ?? [])
            .filter { $0 >= 0 && $0 < chapterCount }
            .count
    }

    func paginatedBookTotalText(_ total: Int) -> String {
        paginatedSettingsIsComplete ? "\(total)" : "~\(total)"
    }

    var paginationChapterCount: Int {
        if let count = wordCountsPerSpine?.count, count > 0 { return count }
        if let total = readiumResourceTotal, total > 0 { return total }
        if let count = package?.spine.count, count > 0 { return count }
        return 0
    }

    var paginationAuditHeader: String {
        [
            "step",
            "event",
            "note",
            "globalPage",
            "generatedTotal",
            "rawGlobalPage",
            "readiumDisplayPage",
            "readiumDisplayTotal",
            "resourceIndex",
            "chapterViewportPage",
            "chapterViewportTotal",
            "chapterPosition",
            "chapterPositionTotal",
            "progressPercent",
            "locatorHash"
        ].joined(separator: "\t")
    }

    func paginationAuditLine(step: Int, event: String, note: String = "") -> String {
        let locatorHash = readiumLocatorJSON.map { String(abs($0.hashValue), radix: 16) } ?? ""
        let globalPageText = paginatedBookCurrentPage.map(String.init) ?? ""
        let generatedTotalText = paginatedSettings.map { String($0.totalPages) } ?? ""
        let rawGlobalPageText = rawPaginatedBookCurrentPage.map(String.init) ?? ""
        let resourceIndexText = readiumResourceIndex.map(String.init) ?? ""
        let chapterViewportPageText = readiumChapterPageState.map { String($0.currentPage) } ?? ""
        let chapterViewportTotalText = readiumChapterPageState.map { String($0.totalPages) } ?? ""
        let chapterPositionText = readiumChapterPosition.map(String.init) ?? ""
        let chapterPositionTotalText = readiumChapterPositionTotal.map(String.init) ?? ""
        let progressText = String(Int((overallProgress * 100).rounded()))
        let fields: [String] = [
            "\(step)",
            event,
            note,
            globalPageText,
            generatedTotalText,
            rawGlobalPageText,
            "\(rawDisplayPage)",
            "\(displayPageTotal)",
            resourceIndexText,
            chapterViewportPageText,
            chapterViewportTotalText,
            chapterPositionText,
            chapterPositionTotalText,
            progressText,
            locatorHash
        ]
        return fields.joined(separator: "\t")
    }

    func generatedPageCount(forChapterIndex chapterIndex: Int) -> Int {
        guard let settings = paginatedSettings,
              paginatedSettingsKey == paginationKey,
              settings.pagesPerChapter.indices.contains(chapterIndex)
        else { return 1 }
        return max(1, settings.pagesPerChapter[chapterIndex])
    }

    func generatedPageNumber(forChapterIndex chapterIndex: Int, pageOffsetInChapter: Int = 0) -> Int? {
        guard let settings = paginatedSettings,
              paginatedSettingsKey == paginationKey,
              settings.chapterPageOffsets.indices.contains(chapterIndex),
              settings.pagesPerChapter.indices.contains(chapterIndex)
        else { return nil }
        let chapterOffset = min(max(0, pageOffsetInChapter), max(0, settings.pagesPerChapter[chapterIndex] - 1))
        return max(1, min(settings.totalPages, settings.chapterPageOffsets[chapterIndex] + 1 + chapterOffset))
    }

    private var rawPaginatedBookCurrentPage: Int? {
        guard let settings = paginatedSettings,
              paginatedSettingsKey == paginationKey,
              let state = readiumChapterPageState,
              settings.chapterPageOffsets.indices.contains(state.resourceIndex)
        else { return nil }
        let offset = settings.chapterPageOffsets[state.resourceIndex]
        let page = offset + max(1, state.currentPage)
        return max(1, min(settings.totalPages, page))
    }

    private var currentTOCSectionRange: ReaderChromeLogic.SectionRange? {
        guard let package,
              let currentResource = activeReadiumResourceIndex,
              let settings = paginatedSettings,
              paginatedSettingsKey == paginationKey,
              settings.pagesPerChapter.indices.contains(currentResource),
              settings.chapterPageOffsets.indices.contains(currentResource)
        else { return nil }

        let rows = package.toc.enumerated().compactMap { offset, entry -> ReaderChromeLogic.TOCRow? in
            let chapterIndex = spineIndex(for: entry.href, in: package) ?? firstDescendantSpineIndex(after: offset, in: package)
            guard let chapterIndex else { return nil }
            let title = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ReaderChromeLogic.TOCRow(
                offset: offset,
                title: title,
                href: entry.href,
                chapterIndex: chapterIndex,
                depth: max(0, entry.depth)
            )
        }

        return ReaderChromeLogic.sectionRange(
            rows: rows,
            currentResource: currentResource,
            chapterPageOffsets: settings.chapterPageOffsets,
            pagesPerChapter: settings.pagesPerChapter,
            totalPages: settings.totalPages,
            locatorHref: readiumLocatorHref,
            locatorJSON: readiumLocatorJSON
        )
    }

    private func firstDescendantSpineIndex(after offset: Int, in package: EPUBPackage) -> Int? {
        guard package.toc.indices.contains(offset) else { return nil }
        let parentDepth = package.toc[offset].depth
        for candidate in package.toc.dropFirst(offset + 1) {
            if candidate.depth <= parentDepth {
                return nil
            }
            if let index = spineIndex(for: candidate.href, in: package) {
                return index
            }
        }
        return nil
    }

    private func spineIndex(for href: String, in package: EPUBPackage) -> Int? {
        let target = ReaderChromeLogic.normalizedHref(href)
        return package.spine.firstIndex { entry in
            let spineHref = ReaderChromeLogic.normalizedHref(entry.href)
            return target == spineHref || target.hasPrefix("\(spineHref)#")
        }
    }

    private func boundedPaginatedBookPage(_ page: Int) -> Int {
        max(1, min(paginatedSettings?.totalPages ?? page, page))
    }

    func hydratePaginatedSettings(_ settings: PaginatedSettings?, for key: PaginationKey? = nil) {
        let targetKey = key ?? paginationKey
        paginatedSettingsKey = targetKey
        if let settings, isUsableCachedPaginatedSettings(settings, for: targetKey) {
            paginatedSettings = settings
            paginatedSettingsLoadedFromCache = true
        } else {
            paginatedSettings = nil
            paginatedSettingsLoadedFromCache = false
        }
        paginatedPageOverride = rawPaginatedBookCurrentPage
        pendingPaginatedPageTurnBase = nil
    }

    func applyExactPaginatedSettings(
        pagesPerChapter: [Int],
        progress: Double,
        measuredChapterIndexes: Set<Int>
    ) {
        guard !pagesPerChapter.isEmpty else { return }
        let measuredWordsPerChapter: [Int]? = wordCountsPerSpine.map { counts in
            counts.indices.map { measuredChapterIndexes.contains($0) ? max(0, counts[$0]) : 0 }
        }
        let density: Double = {
            guard let measuredWordsPerChapter else { return wordsPerViewportPage ?? 0 }
            let measuredWords = measuredChapterIndexes.reduce(0) { total, index in
                guard measuredWordsPerChapter.indices.contains(index), pagesPerChapter.indices.contains(index) else { return total }
                return total + measuredWordsPerChapter[index]
            }
            let measuredPages = measuredChapterIndexes.reduce(0) { total, index in
                guard pagesPerChapter.indices.contains(index) else { return total }
                return total + max(1, pagesPerChapter[index])
            }
            guard measuredWords > 0, measuredPages > 0 else { return wordsPerViewportPage ?? 0 }
            return Double(measuredWords) / Double(measuredPages)
        }()
        paginatedSettingsKey = paginationKey
        paginatedSettings = PaginatedSettings(
            pagesPerChapter: pagesPerChapter,
            progress: progress,
            measuredChapterIndex: -1,
            wordsPerViewportPage: density,
            measuredChapterIndexes: Array(measuredChapterIndexes),
            measuredWordsPerChapter: measuredWordsPerChapter
        )
        paginatedSettingsLoadedFromCache = false
        paginatedPageOverride = rawPaginatedBookCurrentPage
        pendingPaginatedPageTurnBase = nil
    }

    private func refreshPaginatedSettingsIfNeeded(from state: ReadiumChapterPageState?) {
        let key = paginationKey
        if paginatedSettingsKey != key {
            paginatedSettings = nil
            paginatedSettingsKey = key
            paginatedSettingsLoadedFromCache = false
            paginatedPageOverride = nil
        }
        guard paginatedSettings == nil,
              let state,
              let next = makePaginatedSettings(from: state)
        else { return }
        paginatedSettings = next
        paginatedSettingsLoadedFromCache = false
        paginatedPageOverride = rawPaginatedBookCurrentPage
    }

    private func makePaginatedSettings(from state: ReadiumChapterPageState) -> PaginatedSettings? {
        guard let counts = wordCountsPerSpine,
              counts.indices.contains(state.resourceIndex),
              state.totalPages > 0
        else { return nil }

        let measuredChapterWords = counts[state.resourceIndex]
        guard canAnchorPagination(chapterWords: measuredChapterWords, chapterPages: state.totalPages) else { return nil }

        let density = Double(measuredChapterWords) / Double(state.totalPages)
        guard density >= minimumReasonableWordsPerPage(for: paginationKey) else { return nil }

        var pagesPerChapter = counts.map { words in
            max(1, Int(ceil(Double(max(0, words)) / density)))
        }
        pagesPerChapter[state.resourceIndex] = max(1, state.totalPages)

        let measuredWordsPerChapter = counts.indices.map { $0 == state.resourceIndex ? max(0, counts[$0]) : 0 }
        return PaginatedSettings(
            pagesPerChapter: pagesPerChapter,
            progress: counts.isEmpty ? 0 : 1.0 / Double(counts.count),
            measuredChapterIndex: state.resourceIndex,
            wordsPerViewportPage: density,
            measuredChapterIndexes: [state.resourceIndex],
            measuredWordsPerChapter: measuredWordsPerChapter
        )
    }

    private func isUsableCachedPaginatedSettings(_ settings: PaginatedSettings, for key: PaginationKey) -> Bool {
        guard settings.totalPages > 0 else { return false }

        if let totalWords, totalWords > 0 {
            let maximumPages = max(1, Int(ceil(Double(totalWords) / minimumReasonableWordsPerPage(for: key))))
            guard settings.totalPages <= maximumPages else { return false }
        }

        if let counts = wordCountsPerSpine {
            guard settings.pagesPerChapter.count == counts.count,
                  settings.chapterPageOffsets.count == counts.count
            else { return false }

            let measuredIndexes = Set(settings.measuredChapterIndexes ?? [])
                .filter { $0 >= 0 && $0 < counts.count }
            let isCompleteExactCache = (0..<counts.count).allSatisfy { measuredIndexes.contains($0) }
            if isCompleteExactCache || !measuredIndexes.isEmpty {
                return true
            }
        }

        guard settings.wordsPerViewportPage >= minimumReasonableWordsPerPage(for: key) else { return false }

        return true
    }

    private func canAnchorPagination(chapterWords: Int, chapterPages: Int) -> Bool {
        chapterWords >= 1_200 && chapterPages >= 4
    }

    private func minimumReasonableWordsPerPage(for key: PaginationKey) -> Double {
        max(45, 120 * (100.0 / Double(max(60, key.fontSize))))
    }

    func go(to index: Int, page: Int? = nil, animated: Bool = true) {
        guard let pkg = package else { return }
        let bounded = max(0, min(pkg.spine.count - 1, index))
        chapterIndex = bounded
        currentPage = 1
        totalPages = chapterPageCounts.indices.contains(bounded) ? max(1, chapterPageCounts[bounded]) : 1
        suppressFirstPageUntilLastJump = false
        if let page, page > 1 {
            pendingInitialPage = .page(page)
        } else {
            pendingInitialPage = .first
        }
    }

    /// Called when the JS layer reports that pageNext would go past the last page.
    /// Advance to the next chapter starting on page 1.
    func advanceChapter() {
        guard let pkg = package, chapterIndex + 1 < pkg.spine.count else { return }
        chapterIndex += 1
        currentPage = 1
        totalPages = chapterPageCounts.indices.contains(chapterIndex) ? max(1, chapterPageCounts[chapterIndex]) : 1
        pendingInitialPage = .first
    }

    /// Called when the JS layer reports that pagePrev would go before page 1.
    /// Step back to the previous chapter and request the last page.
    func retreatChapter() {
        guard chapterIndex > 0 else { return }
        chapterIndex -= 1
        if chapterPageCounts.indices.contains(chapterIndex), chapterPageCounts[chapterIndex] > 1 {
            let knownLastPage = max(1, chapterPageCounts[chapterIndex])
            currentPage = knownLastPage
            totalPages = knownLastPage
            pendingInitialPage = .page(knownLastPage)
        } else {
            currentPage = 1
            totalPages = 1
            suppressFirstPageUntilLastJump = true
            pendingInitialPage = .last
        }
    }

    func shouldSuppressFirstPageDuringLastJump(page: Int, total: Int) -> Bool {
        suppressFirstPageUntilLastJump && total > 1 && page <= 1
    }

    func updatePageInfo(page: Int, total: Int) {
        totalPages = max(1, total)
        currentPage = max(1, min(page, totalPages))
        if suppressFirstPageUntilLastJump && (currentPage > 1 || totalPages <= 1) {
            suppressFirstPageUntilLastJump = false
        }
        guard chapterIndex >= 0 else { return }
        if chapterPageCounts.count <= chapterIndex {
            chapterPageCounts.append(contentsOf: Array(repeating: 0, count: chapterIndex - chapterPageCounts.count + 1))
        }
        chapterPageCounts[chapterIndex] = max(1, total)
    }
}

private extension Bookmark {
    func displayPage(total: Int) -> Int {
        max(1, min(max(1, total), Int(ceil(pct * Double(max(1, total))))))
    }
}

private extension String {
    var isReadiumLocatorJSON: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }
}
