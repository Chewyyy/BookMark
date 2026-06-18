import SwiftUI
import WebKit
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
    @State private var contentsInitialTab: ReaderContentsSheet.ContentTab = .chapters
    @State private var showReaderMenu = false
    @State private var pendingLocatorJSON: String?
    @State private var pendingChapterJump: ReadiumChapterJump?
    @State private var returnLocatorJSON: String?
    @State private var readiumPublication: Publication?
    @State private var sessionStartedAt = Date()
    @State private var sessionStartProgress: Double?
    @State private var sessionStartPage: Int?
    @State private var sessionStartPosition: Int?
    @State private var sessionSaved = false
    @State private var elapsed = 0
    @State private var timer: Timer?
    @State private var endPromptShown = false
    @State private var finishPromptTarget: Book?

    private var book: Book? { store.books.first { $0.id == bookId } }

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
                    highlights: store.highlights[bookId] ?? [],
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
                    }
                )
                .ignoresSafeArea()
            } else if let err = model.error {
                errorView(err)
            } else {
                loadingView
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
            } else if model.epubURL != nil {
                hiddenPageIndicator
                    .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBar(hidden: !showChrome)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .task { await load() }
        .onAppear {
            sessionStartedAt = Date()
            sessionStartProgress = nil
            sessionStartPage = nil
            sessionStartPosition = nil
            sessionSaved = false
            elapsed = 0
            startTimer()
            UIApplication.shared.isIdleTimerDisabled = model.settings.keepAwake
        }
        .onDisappear {
            timer?.invalidate()
            UIApplication.shared.isIdleTimerDisabled = false
            saveSession()
            store.endLiveReadingSession(bookId: bookId)
        }
        .onChange(of: model.settings.keepAwake) { _, v in
            UIApplication.shared.isIdleTimerDisabled = v
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(model: model)
                .presentationDetents([.medium, .large])
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
                    pendingLocatorJSON = locatorJSON
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
            }
        }
        .sheet(item: $finishPromptTarget) { bk in
            FinishDateSheet(book: bk) { }
                .presentationDetents([.medium])
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
            Text(model.chapterPagesLeftText)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(model.theme.foregroundColor)
                .lineLimit(1)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
            Text(Fmt.timer(elapsed))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(model.theme.foregroundColor)
                .monospacedDigit()
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
                    Text(model.statusBottom)
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(model.theme.foregroundColor)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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

    private func handleTap(_ zone: TapZone) {
        switch zone {
        case .chapterBack:
            model.retreatChapter()
        case .chapterForward:
            model.advanceChapter()
        case .menu:
            toggleChrome()
        }
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.15)) {
            showChrome.toggle()
            if !showChrome {
                showReaderMenu = false
            }
        }
    }

    private func jumpToChapter(_ chapter: Int, page: Int?) {
        prepareReturnLocation()
        if model.epubURL != nil {
            pendingChapterJump = ReadiumChapterJump(chapterIndex: chapter)
            return
        }
        model.go(to: chapter, page: page)
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
        let progressDelta = max(0, model.overallProgress - (sessionStartProgress ?? model.overallProgress))
        let pagesRead: Int = {
            guard let startPage = sessionStartPage else { return 0 }
            let endPage = model.epubURL != nil ? model.displayPage : model.estimatedBookPage
            return max(0, endPage - startPage)
        }()
        // Device-independent counterpart to pagesRead. nil for legacy / non-EPUB
        // sessions; the snapshot aggregator falls back to pagesRead when this
        // is missing so historical numbers don't change.
        let posPagesRead: Int? = {
            guard let start = sessionStartPosition, let end = model.readiumPosition else { return nil }
            let delta = end - start
            return delta > 0 ? delta : nil
        }()
        let session = ReadingSession(
            bookId: book.id,
            bookTitle: book.title,
            start: sessionStartedAt,
            end: Date(),
            secs: elapsed,
            pages: pagesRead > 0 ? pagesRead : nil,
            posPages: posPagesRead,
            progressDelta: progressDelta > 0 ? progressDelta : nil,
            manual: false
        )
        store.endLiveReadingSession(bookId: book.id)
        store.addSession(session)
        // Persist this session's observed swipes/position ratio so the next
        // session opens with an accurate "Page X of Y" total from the first
        // swipe instead of having to re-establish the ratio mid-session.
        if let ratio = model.liveSwipesPerPosition {
            store.updateSwipesPerPosition(bookId: book.id, ratio: ratio)
        }
    }

    private func captureSessionStartIfNeeded() {
        if sessionStartProgress == nil {
            sessionStartProgress = model.overallProgress
        }
        if sessionStartPage == nil {
            sessionStartPage = model.epubURL != nil ? model.displayPage : model.estimatedBookPage
        }
        // Capture Readium's device-independent book position so the session's
        // posPages delta survives switching devices (e.g. iPhone → iPad).
        if sessionStartPosition == nil, model.epubURL != nil, let pos = model.readiumPosition {
            sessionStartPosition = pos
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
        // Seed dynamic-page-total math with the cached ratio from this book's
        // last session BEFORE resetting session metrics — resetReadiumSessionMetrics
        // reads cachedSwipesPerPosition to decide whether mid-session rescale is needed.
        model.cachedSwipesPerPosition = store.progress[book.id]?.swipesPerPosition
        model.resetReadiumSessionMetrics()
        sessionStartProgress = model.readiumProgress
        sessionStartPage = nil
        sessionStartPosition = nil
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

// MARK: - Theme

enum ReaderThemePalette {
    static func resolve(_ t: ReaderTheme) -> Palette {
        switch t {
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
    @Published var readiumResourceIndex: Int?
    @Published var readiumResourceTotal: Int?
    @Published var readiumChapterPosition: Int?
    @Published var readiumChapterPositionTotal: Int?
    @Published var readiumChapterTitle: String?
    @Published var readiumPublisherPageLabel: String?
    @Published var readiumPublisherPageCount: Int?
    @Published private(set) var readiumSessionPagesRead = 0
    @Published private var displayPageOverride: Int?
    var cachedSwipesPerPosition: Double?
    private var sessionSwipeStartPosition: Int?
    private var sessionSwipeCount = 0
    private var sessionRatioRescaleApplied = false
    private var pendingReadiumPageTurnDirection: Int?
    @Published var error: String?
    @Published var pendingInitialPage: InitialPage?
    @Published var suppressFirstPageUntilLastJump = false
    @Published var webIsReady = false

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
            return "Page \(displayPage) of \(displayPageTotal) · \(percent)%"
        }
        return "Page \(estimatedBookPage) of \(estimatedBookPages) · \(Int((overallProgress * 100).rounded()))%"
    }

    var pageOnlyText: String {
        if epubURL != nil {
            return "Page \(displayPage)"
        }
        return "Page \(estimatedBookPage)"
    }

    private var publisherPageText: String? {
        guard let label = readiumPublisherPageLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty,
              let count = readiumPublisherPageCount,
              count > 0 else {
            return nil
        }
        return "Page \(label) of \(count)"
    }

    var displayPageTotal: Int {
        max(1, readiumTotalPositions ?? estimatedBookPages)
    }

    var liveSwipesPerPosition: Double? {
        guard sessionSwipeCount > 0,
              let start = sessionSwipeStartPosition,
              let current = readiumPosition else {
            return cachedSwipesPerPosition
        }
        let positionDelta = current - start
        guard positionDelta > 0 else {
            return cachedSwipesPerPosition
        }
        return Double(sessionSwipeCount) / Double(positionDelta)
    }

    var displayPage: Int {
        displayPageOverride ?? rawDisplayPage
    }

    private var rawDisplayPage: Int {
        let fallback = Int(ceil(overallProgress * Double(displayPageTotal)))
        return boundedDisplayPage(readiumPosition ?? fallback)
    }

    var chapterPagesLeftText: String {
        if epubURL != nil {
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

    func updateReadiumProgress(_ progress: Double, locatorJSON: String?, position: Int?, totalPositions: Int?) {
        readiumProgress = max(0, min(1, progress))
        readiumLocatorJSON = locatorJSON
        readiumPosition = position
        readiumTotalPositions = totalPositions
    }

    func expectReadiumPageTurn(_ direction: Int) {
        pendingReadiumPageTurnDirection = direction == 0 ? nil : (direction > 0 ? 1 : -1)
    }

    func resetReadiumSessionMetrics() {
        readiumSessionPagesRead = 0
        readiumPublisherPageLabel = nil
        readiumPublisherPageCount = nil
        pendingReadiumPageTurnDirection = nil
        sessionSwipeStartPosition = nil
        sessionSwipeCount = 0
        // If we already have a cached ratio at session start, rawDisplayPage
        // produces ratio-scaled values from the first swipe, so no mid-session
        // rescale is needed. Only sessions that start with NO cached ratio
        // need to rescale when live samples become available.
        sessionRatioRescaleApplied = (cachedSwipesPerPosition != nil)
    }

    func updateReadiumLocation(_ location: ReadiumLocation) {
        let oldProgress = readiumProgress
        let oldPage = displayPageOverride ?? rawDisplayPage
        let oldLocator = readiumLocatorJSON
        let expectedDirection = pendingReadiumPageTurnDirection

        readiumProgress = max(0, min(1, location.totalProgress))
        readiumLocatorJSON = location.locatorJSON
        readiumPosition = location.bookPosition
        readiumTotalPositions = location.bookPositionTotal
        readiumResourceIndex = location.resourceIndex
        readiumResourceTotal = location.resourceTotal
        readiumChapterPosition = location.chapterPosition
        readiumChapterPositionTotal = location.chapterPositionTotal
        readiumChapterTitle = location.chapterTitle
        readiumPublisherPageLabel = location.publisherPageLabel
        readiumPublisherPageCount = location.publisherPageCount
        if let idx = location.resourceIndex { chapterIndex = idx }

        // Anchor the swipe-rate baseline at the resumed position so the ratio
        // measures THIS session's swipes per position. Captured once per
        // session at the first known location.
        if sessionSwipeStartPosition == nil, let pos = location.bookPosition {
            sessionSwipeStartPosition = pos
        }

        // First time the ratio becomes known mid-session (no cached value at
        // open, but we've now collected enough live samples), rescale the
        // page override so the displayed page matches the new scaled total
        // proportionally. Without this, the override sits at an unscaled
        // value while displayPageTotal suddenly drops, jumping the "X of Y"
        // ratio.
        if !sessionRatioRescaleApplied, let ratio = liveSwipesPerPosition {
            if let override = displayPageOverride {
                displayPageOverride = boundedDisplayPage(Int((Double(override) * ratio).rounded()))
            }
            sessionRatioRescaleApplied = true
        }

        let estimated = boundedDisplayPage(location.bookPosition ?? rawDisplayPage)
        guard oldLocator != location.locatorJSON else {
            if let expectedDirection {
                pendingReadiumPageTurnDirection = nil
                applyExpectedReadiumPageTurn(
                    from: oldPage,
                    direction: expectedDirection
                )
            } else if displayPageOverride == nil {
                displayPageOverride = estimated
            }
            return
        }

        pendingReadiumPageTurnDirection = nil
        if let expectedDirection {
            applyExpectedReadiumPageTurn(
                from: oldPage,
                direction: expectedDirection
            )
        } else if readiumProgress > oldProgress {
            displayPageOverride = boundedDisplayPage(max(estimated, oldPage + 1))
        } else if readiumProgress < oldProgress {
            displayPageOverride = boundedDisplayPage(min(estimated, oldPage - 1))
        } else {
            displayPageOverride = estimated
        }
    }

    private func applyExpectedReadiumPageTurn(
        from oldPage: Int,
        direction: Int
    ) {
        displayPageOverride = boundedDisplayPage(oldPage + direction)
        readiumSessionPagesRead = max(0, readiumSessionPagesRead + direction)
        // Count forward swipes for the ratio sample. Backward swipes are
        // intentionally excluded because re-reading content doesn't add fresh
        // sample data and can skew the ratio.
        if direction > 0 {
            sessionSwipeCount += 1
        }
    }

    private func boundedDisplayPage(_ page: Int) -> Int {
        max(1, min(displayPageTotal, page))
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

// MARK: - Tap zones

enum TapZone { case chapterBack, chapterForward, menu }

// MARK: - Web view

struct ReaderWebView: UIViewRepresentable {
    let package: EPUBPackage
    let chapterIndex: Int
    let settings: ReaderSettings
    let chapterBody: String
    let initialPage: ReaderModel.InitialPage?
    let onInitialPageHandled: () -> Void
    let onPageInfo: (Int, Int) -> Void
    let onTap: (TapZone) -> Void
    let onReady: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false

        let handler = EPUBResourceHandler(archive: package.archive)
        context.coordinator.schemeHandler = handler
        config.setURLSchemeHandler(handler, forURLScheme: "epubres")

        let content = WKUserContentController()
        content.add(context.coordinator, name: "page")
        content.add(context.coordinator, name: "tap")
        content.add(context.coordinator, name: "ready")
        config.userContentController = content

        let web = WKWebView(frame: .zero, configuration: config)
        web.scrollView.isPagingEnabled = false
        web.scrollView.bounces = false
        web.scrollView.showsHorizontalScrollIndicator = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.alwaysBounceHorizontal = false
        web.scrollView.alwaysBounceVertical = false
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.navigationDelegate = context.coordinator

        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        context.coordinator.webView = web

        // Initial load
        context.coordinator.lastChapter = -1
        context.coordinator.reloadIfNeeded(chapter: chapterIndex, body: chapterBody, settings: settings)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.reloadIfNeeded(chapter: chapterIndex, body: chapterBody, settings: settings)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let parent: ReaderWebView
        weak var webView: WKWebView?
        var schemeHandler: EPUBResourceHandler?
        var lastChapter: Int = -1
        var lastSettingsHash: Int = 0

        init(_ parent: ReaderWebView) { self.parent = parent }

        func reloadIfNeeded(chapter: Int, body: String, settings: ReaderSettings) {
            let settingsHash = settings.styleHash
            if chapter == lastChapter && settingsHash == lastSettingsHash { return }
            lastChapter = chapter
            lastSettingsHash = settingsHash
            let html = ReaderHTML.compose(body: body, settings: settings)
            webView?.loadHTMLString(html, baseURL: URL(string: "epubres:///"))
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "ready":
                Task { @MainActor in
                    parent.onReady()
                    if let initial = parent.initialPage {
                        let js: String
                        switch initial {
                        case .first: js = "window.bmGo && bmGo(1);"
                        case .last:  js = "window.bmGoLast && bmGoLast();"
                        case .page(let n): js = "window.bmGoStable && bmGoStable(\(n));"
                        }
                        _ = try? await self.webView?.evaluateJavaScript(js)
                        parent.onInitialPageHandled()
                    }
                }
            case "page":
                if let dict = message.body as? [String: Any],
                   let page = dict["page"] as? Int,
                   let total = dict["total"] as? Int {
                    Task { @MainActor in parent.onPageInfo(page, total) }
                }
            case "tap":
                if let zone = message.body as? String {
                    let z: TapZone = zone == "chapterBack" ? .chapterBack : zone == "chapterForward" ? .chapterForward : .menu
                    Task { @MainActor in parent.onTap(z) }
                }
            default: break
            }
        }
    }
}



// MARK: - HTML composition

enum ReaderHTML {
    static func compose(body: String, settings: ReaderSettings) -> String {
        let palette = ReaderThemePalette.resolve(settings.theme)
        let fontFamily = settings.font.cssFamily
        let textAlign = settings.justify ? "justify" : "left"
        let weight = settings.bold ? "600" : "400"
        let marginValue: String = {
            switch settings.margins {
            case .narrow: return "16px"
            case .normal: return "26px"
            case .wide:   return "44px"
            }
        }()

        // Paginated layout using CSS multi-column on a fixed-height container.
        // Pages = horizontal scroll positions. JS drives the page/turn count.
        let template = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
<style>
:root { color-scheme: \(palette.isDark ? "dark" : "light"); }
html, body {
  margin: 0; padding: 0;
  background: \(palette.bgHex);
  color: \(palette.fgHex);
  font-family: \(fontFamily);
  font-size: \(settings.fontSize)%;
  font-weight: \(weight);
  line-height: \(settings.lineHeight);
  text-align: \(textAlign);
  overflow: hidden;
  -webkit-text-size-adjust: 100%;
  -webkit-user-select: none;
  user-select: none;
}
a { color: \(palette.linkHex); text-decoration: none; }
img, svg, video { max-width: 100%; height: auto; display: block; margin: 6px auto 10px; }
#viewport {
  position: fixed; inset: 0;
  padding: calc(env(safe-area-inset-top, 0px) + 18px) \(marginValue) calc(env(safe-area-inset-bottom, 0px) + 22px) \(marginValue);
  box-sizing: border-box;
  overflow: hidden;
}
#paged {
  width: 100%;
  column-width: calc(100vw - 2 * \(marginValue));
  column-gap: 0;
  column-fill: auto;
  height: 100%;
  overflow: hidden;
  overflow-wrap: break-word;
  position: relative;
}
#paged p { orphans: 2; widows: 2; }
#paged h1, #paged h2, #paged h3 { line-height: 1.2; break-after: avoid; }
#paged hr { border: none; border-top: 1px solid \(palette.subHex); opacity: .35; margin: 1.5em 0; }
.bm-tap-zone { position: fixed; top: 0; bottom: 0; z-index: 9999; }
.bm-prev { left: 0; width: 26%; }
.bm-next { right: 0; width: 26%; }
.bm-menu { left: 26%; right: 26%; }
</style>
</head>
<body>
<div id="viewport">
  <div id="paged">\(body)</div>
</div>
<div class="bm-tap-zone bm-prev" data-zone="prev"></div>
<div class="bm-tap-zone bm-next" data-zone="next"></div>
<div class="bm-tap-zone bm-menu" data-zone="menu"></div>
<script>
(function() {
  const paged = document.getElementById('paged');
  const viewport = document.getElementById('viewport');
  let currentPageState = 1;

  function pageMetrics() {
    const colW = Math.max(1, Math.round(paged.clientWidth));
    const totalW = Math.max(paged.scrollWidth, colW);
    const totalPages = Math.max(1, Math.ceil((totalW - 1) / colW));
    currentPageState = Math.max(1, Math.min(totalPages, currentPageState));
    return { colW, totalPages, currentPage: currentPageState };
  }

  function postPage() {
    const { totalPages, currentPage } = pageMetrics();
    window.webkit?.messageHandlers?.page?.postMessage({ page: currentPage, total: totalPages });
  }

  function applyPagePosition(colW) {
    paged.style.transform = 'none';
    paged.scrollLeft = (currentPageState - 1) * colW;
  }

  function goTo(page) {
    const { colW, totalPages } = pageMetrics();
    currentPageState = Math.max(1, Math.min(totalPages, page));
    applyPagePosition(colW);
    setTimeout(postPage, 0);
  }

  function nextPage() {
    const { colW, totalPages, currentPage } = pageMetrics();
    if (currentPage >= totalPages) {
      window.webkit?.messageHandlers?.page?.postMessage({ page: currentPage, total: totalPages, eoc: true });
      return false;
    }
    currentPageState = currentPage + 1;
    applyPagePosition(colW);
    setTimeout(postPage, 0);
    return true;
  }

  function prevPage() {
    const { colW, totalPages, currentPage } = pageMetrics();
    if (currentPage <= 1) {
      window.webkit?.messageHandlers?.page?.postMessage({ page: currentPage, total: totalPages, boc: true });
      return false;
    }
    currentPageState = currentPage - 1;
    applyPagePosition(colW);
    setTimeout(postPage, 0);
    return true;
  }

  window.bmNext = nextPage;
  window.bmPrev = prevPage;
  window.bmGo   = goTo;
  window.bmGoStable = function(page) {
    let attempts = 0;
    function tryPage() {
      goTo(page);
      attempts += 1;
      if (attempts < 10) {
        setTimeout(tryPage, attempts < 4 ? 120 : 220);
      }
    }
    setTimeout(tryPage, 80);
  };
  window.bmGoLast = function() {
    let attempts = 0;
    let bestTotal = 1;
    let stableCount = 0;

    function tryLastPage() {
      const m = pageMetrics();
      if (m.totalPages > bestTotal) {
        bestTotal = m.totalPages;
        stableCount = 0;
      } else {
        stableCount += 1;
      }
      currentPageState = bestTotal;
      applyPagePosition(m.colW);
      attempts += 1;

      if (attempts < 16 && stableCount < 3) {
        setTimeout(tryLastPage, attempts < 5 ? 120 : 220);
      } else {
        postPage();
      }
    }

    setTimeout(tryLastPage, 80);
  };

  document.querySelectorAll('.bm-tap-zone').forEach(z => {
    z.addEventListener('click', e => {
      const zone = e.currentTarget.dataset.zone;
      if (zone === 'prev') nextOrPrev('prev');
      else if (zone === 'next') nextOrPrev('next');
      else window.webkit?.messageHandlers?.tap?.postMessage('menu');
    });
  });

  function nextOrPrev(dir) {
    const did = dir === 'next' ? nextPage() : prevPage();
    if (did) return;

    setTimeout(function() {
      const m = pageMetrics();
      if (dir === 'next' && m.currentPage >= m.totalPages) {
        window.webkit?.messageHandlers?.tap?.postMessage('chapterForward');
      } else if (dir === 'prev' && m.currentPage <= 1) {
        window.webkit?.messageHandlers?.tap?.postMessage('chapterBack');
      }
    }, 80);
  }

  // Layout-stable load: send metrics after images load.
  function waitForImages() {
    const imgs = Array.from(document.images || []);
    if (!imgs.length) return Promise.resolve();
    return Promise.all(imgs.map(img => img.complete ? Promise.resolve() : new Promise(res => {
      img.addEventListener('load', res, { once: true });
      img.addEventListener('error', res, { once: true });
    })));
  }

  function ready() {
    requestAnimationFrame(function() {
      setTimeout(function() {
        postPage();
        window.webkit?.messageHandlers?.ready?.postMessage(true);
      }, 60);
    });
  }

  if (document.readyState === 'complete') waitForImages().then(ready);
  else window.addEventListener('load', () => waitForImages().then(ready));

  window.addEventListener('resize', () => setTimeout(function() {
    const m = pageMetrics();
    applyPagePosition(m.colW);
    postPage();
  }, 50));
})();
</script>
</body>
</html>
"""
        return template
    }
}

private extension ReaderFont {
    var cssFamily: String {
        switch self {
        case .original, .georgia, .serif:
            return "Georgia, 'Times New Roman', serif"
        case .palatino:
            return "'Palatino Linotype', Palatino, 'Book Antiqua', serif"
        case .charter:
            return "Charter, 'Iowan Old Style', Georgia, serif"
        case .times:
            return "'Times New Roman', Times, serif"
        case .sans, .system:
            return "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif"
        case .rounded:
            return "ui-rounded, 'SF Pro Rounded', -apple-system, BlinkMacSystemFont, sans-serif"
        case .mono:
            return "ui-monospace, 'SF Mono', Menlo, monospace"
        }
    }
}

private extension ReaderSettings {
    /// Used to invalidate the HTML payload when style-affecting settings change.
    var styleHash: Int {
        var h = Hasher()
        h.combine(theme)
        h.combine(font)
        h.combine(fontSize)
        h.combine(bold)
        h.combine(lineHeight)
        h.combine(margins)
        h.combine(justify)
        return h.finalize()
    }
}

// MARK: - URL scheme handler

final class EPUBResourceHandler: NSObject, WKURLSchemeHandler {
    let archive: MiniZip.Archive
    init(archive: MiniZip.Archive) { self.archive = archive }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let body = archive.extract(name: path) else {
            urlSchemeTask.didFailWithError(NSError(domain: "epubres", code: 404))
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: mimeType(for: path),
            expectedContentLength: body.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func mimeType(for path: String) -> String {
        let lower = path.lowercased()
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
        if lower.hasSuffix(".png") { return "image/png" }
        if lower.hasSuffix(".gif") { return "image/gif" }
        if lower.hasSuffix(".webp") { return "image/webp" }
        if lower.hasSuffix(".svg") { return "image/svg+xml" }
        if lower.hasSuffix(".css") { return "text/css" }
        if lower.hasSuffix(".js")  { return "application/javascript" }
        if lower.hasSuffix(".woff") { return "font/woff" }
        if lower.hasSuffix(".woff2") { return "font/woff2" }
        if lower.hasSuffix(".ttf") || lower.hasSuffix(".otf") { return "font/ttf" }
        if lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm") { return "application/xhtml+xml" }
        return "application/octet-stream"
    }
}
