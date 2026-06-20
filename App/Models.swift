import Foundation
import UIKit

struct Book: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var author: String
    var added: Date
    var order: Int
    var finished: Bool
    var finishedAt: Date?
    var coverData: Data?
    var fileBookmark: Data?
    var fileName: String?
    var contentFingerprint: String?
    var totalLocations: Int?
    /// Word count per spine item, in spine order. Populated at import time
    /// by `EPUBWordCounter`. Used by the reader to convert a Readium locator
    /// (chapter index + progression within chapter) into an absolute word
    /// offset for device-independent reading-speed stats.
    var wordCountsPerSpine: [Int]?
    /// Sum of `wordCountsPerSpine`. Cached separately so widgets and stats
    /// surfaces don't need the array materialized to use the headline number.
    var totalWords: Int?
    /// Per-layout pagination snapshots keyed by reader settings. These let the
    /// reader show a stable whole-book "Page X of Y" immediately on reopen.
    var paginationCache: [PaginationKey: PaginatedSettings]?

    init(
        id: String = UUID().uuidString,
        title: String,
        author: String,
        added: Date = Date(),
        order: Int = 0,
        finished: Bool = false,
        finishedAt: Date? = nil,
        coverData: Data? = nil,
        fileBookmark: Data? = nil,
        fileName: String? = nil,
        contentFingerprint: String? = nil,
        totalLocations: Int? = nil,
        wordCountsPerSpine: [Int]? = nil,
        totalWords: Int? = nil,
        paginationCache: [PaginationKey: PaginatedSettings]? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.added = added
        self.order = order
        self.finished = finished
        self.finishedAt = finishedAt
        self.coverData = coverData
        self.fileBookmark = fileBookmark
        self.fileName = fileName
        self.contentFingerprint = contentFingerprint
        self.totalLocations = totalLocations
        self.wordCountsPerSpine = wordCountsPerSpine
        self.totalWords = totalWords
        self.paginationCache = paginationCache
    }
}

struct PaginationKey: Codable, Hashable {
    var font: ReaderFont
    var fontSize: Int
    var bold: Bool
    var lineHeight: Double
    var margins: LayoutMargin
    var justify: Bool
    var deviceClass: String

    static var defaultLibraryKey: PaginationKey {
        PaginationKey(
            font: .original,
            fontSize: 100,
            bold: false,
            lineHeight: 1.6,
            margins: .normal,
            justify: false,
            deviceClass: UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        )
    }
}

struct PaginatedSettings: Codable, Hashable {
    var pagesPerChapter: [Int]
    var chapterPageOffsets: [Int]
    var totalPages: Int
    var progress: Double
    var computedAt: Date
    var measuredChapterIndex: Int
    var wordsPerViewportPage: Double
    var measuredChapterIndexes: [Int]?
    var measuredWordsPerChapter: [Int]?

    init(
        pagesPerChapter: [Int],
        progress: Double,
        computedAt: Date = Date(),
        measuredChapterIndex: Int,
        wordsPerViewportPage: Double,
        measuredChapterIndexes: [Int]? = nil,
        measuredWordsPerChapter: [Int]? = nil
    ) {
        self.pagesPerChapter = pagesPerChapter.map { max(1, $0) }
        self.chapterPageOffsets = Self.offsets(for: self.pagesPerChapter)
        self.totalPages = max(1, self.pagesPerChapter.reduce(0, +))
        self.progress = max(0, min(1, progress))
        self.computedAt = computedAt
        self.measuredChapterIndex = measuredChapterIndex
        self.wordsPerViewportPage = wordsPerViewportPage
        self.measuredChapterIndexes = measuredChapterIndexes?.sorted()
        self.measuredWordsPerChapter = measuredWordsPerChapter
    }

    private static func offsets(for pagesPerChapter: [Int]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(pagesPerChapter.count)
        var runningTotal = 0
        for pages in pagesPerChapter {
            offsets.append(runningTotal)
            runningTotal += max(1, pages)
        }
        return offsets
    }
}

struct LibraryPaginationStatus: Equatable {
    var bookTitle: String
    var measuredChapters: Int
    var totalChapters: Int

    var text: String {
        guard totalChapters > 0 else { return "Paginating library" }
        return "Paginating \(bookTitle) \(measuredChapters)/\(totalChapters)"
    }
}

struct ReadingSession: Identifiable, Codable, Hashable {
    var id: String
    var bookId: String?
    var bookTitle: String
    var start: Date
    var end: Date?
    var secs: Int
    var pages: Int?
    var publisherPages: Int?
    /// Device-independent count of words read in this session. Derived from
    /// the book's per-spine word counts and Readium's locator (resource index
    /// + progression). Foundation of WPM and standardized-page stats.
    var wordsRead: Int?
    /// Words per minute calculated when the session is saved. For EPUB sessions
    /// this comes from actual words read; for page-only sessions it uses the
    /// active words-per-page estimate at that time.
    var wordsPerMinute: Double?
    /// Hidden snapshot of the effective words per device page for this session.
    /// Used for stable historical word and standardized-page stats.
    var wordsPerPage: Int?
    var progressDelta: Double?
    var manual: Bool

    init(
        id: String = UUID().uuidString,
        bookId: String?,
        bookTitle: String,
        start: Date,
        end: Date? = nil,
        secs: Int,
        pages: Int? = nil,
        publisherPages: Int? = nil,
        wordsRead: Int? = nil,
        wordsPerMinute: Double? = nil,
        wordsPerPage: Int? = nil,
        progressDelta: Double? = nil,
        manual: Bool = false
    ) {
        self.id = id
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.start = start
        self.end = end
        self.secs = secs
        self.pages = pages
        self.publisherPages = publisherPages
        self.wordsRead = wordsRead
        self.wordsPerMinute = wordsPerMinute
        self.wordsPerPage = wordsPerPage
        self.progressDelta = progressDelta
        self.manual = manual
    }

    static func calculatedWordsPerMinute(wordsRead: Int?, pages: Int?, seconds: Int, wordsPerPage: Int) -> Double? {
        guard seconds > 0 else { return nil }
        let words = max(0, pages ?? 0) * wordsPerPage
        guard words > 0 else { return nil }
        return ceil(Double(words) / (Double(seconds) / 60.0))
    }

    func resolvedWordsRead(fallbackWordsPerPage: Int) -> Int {
        if let wordsRead, wordsRead > 0 { return wordsRead }
        if let sessionWordsPerPage = wordsPerPage, sessionWordsPerPage > 0 {
            return max(0, pages ?? 0) * sessionWordsPerPage
        }
        if let wordsPerMinute, wordsPerMinute > 0, secs > 0 {
            return Int((wordsPerMinute * Double(secs) / 60.0).rounded())
        }
        return max(0, pages ?? 0) * fallbackWordsPerPage
    }

    func storedOrActualWordsPerMinute() -> Double? {
        if let wordsPerMinute, wordsPerMinute > 0 { return wordsPerMinute }
        guard let wordsRead, wordsRead > 0, secs > 0 else { return nil }
        return Double(wordsRead) / (Double(secs) / 60.0)
    }

    func resolvedWordsPerMinute(wordsPerPage: Int) -> Double? {
        if let stored = storedOrActualWordsPerMinute() { return stored }
        return Self.calculatedWordsPerMinute(
            wordsRead: wordsRead,
            pages: pages,
            seconds: secs,
            wordsPerPage: self.wordsPerPage ?? wordsPerPage
        )
    }
}

struct ReadingProgress: Codable, Hashable {
    var pct: Double
    var cfi: String?
    var lastRead: Date

    init(pct: Double = 0, cfi: String? = nil, lastRead: Date = Date()) {
        self.pct = pct
        self.cfi = cfi
        self.lastRead = lastRead
    }
}

struct Bookmark: Identifiable, Codable, Hashable {
    var id: String
    var cfi: String
    var label: String
    var pct: Double
    var page: Int?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        cfi: String,
        label: String,
        pct: Double,
        page: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.cfi = cfi
        self.label = label
        self.pct = pct
        self.page = page
        self.createdAt = createdAt
    }
}

struct Highlight: Identifiable, Codable, Hashable {
    var id: String
    var locatorJSON: String
    var text: String
    var note: String?
    var colorHex: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        locatorJSON: String,
        text: String,
        note: String? = nil,
        colorHex: String = "#FFD54F",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.locatorJSON = locatorJSON
        self.text = text
        self.note = note
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}

struct ReadingGoal: Codable, Hashable {
    var minutes: Int
    var reminderEnabled: Bool
    var reminderHour: Int
    var reminderMinute: Int

    init(
        minutes: Int = 15,
        reminderEnabled: Bool = true,
        reminderHour: Int = 18,
        reminderMinute: Int = 0
    ) {
        self.minutes = minutes
        self.reminderEnabled = reminderEnabled
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
    }

    private enum CodingKeys: String, CodingKey {
        case minutes, reminderEnabled, reminderHour, reminderMinute
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 15
        reminderEnabled = try c.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? true
        reminderHour = try c.decodeIfPresent(Int.self, forKey: .reminderHour) ?? 18
        reminderMinute = try c.decodeIfPresent(Int.self, forKey: .reminderMinute) ?? 0
    }
}

enum ReaderTheme: String, Codable, CaseIterable, Hashable {
    case original, quiet, paper, calm, focus, night
}

enum LayoutMargin: String, Codable, CaseIterable, Hashable {
    case narrow, normal, wide
}

enum ReaderFont: String, Codable, CaseIterable, Hashable {
    case original, georgia, palatino, charter, times, sans
    case system, serif, rounded, mono
}

enum PageAnimation: String, Codable, CaseIterable, Hashable {
    case slide, fade, rigid, curl, none
}

/// How the bottom status bar's "Page X of Y" should be calculated.
/// Lets the user A/B compare Readium's display modes against the new
/// viewport-aware whole-book estimate.
enum PageCountMode: String, Codable, CaseIterable, Hashable {
    /// Readium content positions. ~1024 chars each, stable across devices,
    /// stable across font/spread changes. "Page 142 of 1333"
    case positions
    /// Viewport-aware page count for the current chapter. Changes with
    /// font size, margins, spread. "Page 5 of 12 in chapter"
    case viewportChapter
    /// Apple Books–style whole-book total estimated from the current
    /// chapter's word density × visible page span. Dynamically recomputes
    /// when font size / spread / device changes. "Page 42 of 287"
    case viewportBook
    /// Stable whole-book page count derived once from a viewport chapter
    /// measurement, then held until real pagination settings change.
    case paginatedBook
}

enum WordsPerPageMode: String, Codable, CaseIterable, Hashable {
    case manual
    case automatic
}

struct ReaderSettings: Codable, Hashable {
    static let defaultPhoneWordsPerPage = 300
    static let defaultPadWordsPerPage = 450

    var theme: ReaderTheme = .paper
    var font: ReaderFont = .original
    var fontSize: Int = 100
    var bold: Bool = false
    var lineHeight: Double = 1.6
    var margins: LayoutMargin = .normal
    var justify: Bool = false
    var pageAnim: PageAnimation = .slide
    var swipe: Bool = true
    var keepAwake: Bool = true
    var brightness: Int = 100
    var pageCountMode: PageCountMode = .paginatedBook
    var wordsPerPageMode: WordsPerPageMode = .manual
    var phoneWordsPerPage: Int = Self.defaultPhoneWordsPerPage
    var padWordsPerPage: Int = Self.defaultPadWordsPerPage

    var wordsPerPageForCurrentDevice: Int {
        UIDevice.current.userInterfaceIdiom == .pad ? padWordsPerPage : phoneWordsPerPage
    }

    static var defaultWordsPerPageForCurrentDevice: Int {
        UIDevice.current.userInterfaceIdiom == .pad ? defaultPadWordsPerPage : defaultPhoneWordsPerPage
    }

    static var currentDeviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    init() {}

    mutating func setWordsPerPageForCurrentDevice(_ value: Int) {
        let clamped = Self.clampedWordsPerPage(value)
        if UIDevice.current.userInterfaceIdiom == .pad {
            padWordsPerPage = clamped
        } else {
            phoneWordsPerPage = clamped
        }
    }

    static func clampedWordsPerPage(_ value: Int) -> Int {
        max(50, min(2_000, value))
    }

    private enum CodingKeys: String, CodingKey {
        case theme, font, fontSize, bold, lineHeight, margins, justify, pageAnim, swipe, keepAwake, brightness, pageCountMode, wordsPerPageMode, phoneWordsPerPage, padWordsPerPage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? .paper
        font = try c.decodeIfPresent(ReaderFont.self, forKey: .font) ?? .original
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 100
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.6
        margins = try c.decodeIfPresent(LayoutMargin.self, forKey: .margins) ?? .normal
        justify = try c.decodeIfPresent(Bool.self, forKey: .justify) ?? false
        pageAnim = try c.decodeIfPresent(PageAnimation.self, forKey: .pageAnim) ?? .slide
        swipe = try c.decodeIfPresent(Bool.self, forKey: .swipe) ?? true
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? true
        pageCountMode = .paginatedBook
        wordsPerPageMode = try c.decodeIfPresent(WordsPerPageMode.self, forKey: .wordsPerPageMode) ?? .manual
        brightness = try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 100
        phoneWordsPerPage = Self.clampedWordsPerPage(try c.decodeIfPresent(Int.self, forKey: .phoneWordsPerPage) ?? Self.defaultPhoneWordsPerPage)
        padWordsPerPage = Self.clampedWordsPerPage(try c.decodeIfPresent(Int.self, forKey: .padWordsPerPage) ?? Self.defaultPadWordsPerPage)
    }
}

struct SharedSnapshot: Codable, Hashable {
    // Daily
    var todayMinutes: Int
    var goalMinutes: Int
    var currentStreak: Int
    var bestStreak: Int

    // Continue reading
    var continueTitle: String?
    var continueAuthor: String?
    var continueProgressPct: Int?
    var continueBookSeconds: Int?
    var continueCoverFile: String?     // file name in App Group container (PNG); widget reads this directly
    var continueSmallCoverFile: String?

    // Stats grid
    var totalBooks: Int
    var finishedBooks: Int
    var totalSeconds: Int
    var avgSessionSeconds: Int
    var weekSeconds: Int
    var totalPages: Int
    var avgPages: Int
    var weekPages: Int
    var avgPace: Double

    // 7-day series (oldest -> newest)
    var last7DayLabels: [String]
    var last7DaySeconds: [Int]
    var last7DayPace: [Double]

    var updatedAt: Date

    static let empty = SharedSnapshot(
        todayMinutes: 0,
        goalMinutes: 15,
        currentStreak: 0,
        bestStreak: 0,
        continueTitle: nil,
        continueAuthor: nil,
        continueProgressPct: nil,
        continueBookSeconds: nil,
        continueCoverFile: nil,
        continueSmallCoverFile: nil,
        totalBooks: 0,
        finishedBooks: 0,
        totalSeconds: 0,
        avgSessionSeconds: 0,
        weekSeconds: 0,
        totalPages: 0,
        avgPages: 0,
        weekPages: 0,
        avgPace: 0,
        last7DayLabels: [],
        last7DaySeconds: [],
        last7DayPace: [],
        updatedAt: Date()
    )
}
