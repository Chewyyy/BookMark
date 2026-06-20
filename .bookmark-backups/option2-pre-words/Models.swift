import Foundation

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
        totalLocations: Int? = nil
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
        self.progressDelta = progressDelta
        self.manual = manual
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

struct ReaderSettings: Codable, Hashable {
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

    init() {}

    private enum CodingKeys: String, CodingKey {
        case theme, font, fontSize, bold, lineHeight, margins, justify, pageAnim, swipe, keepAwake, brightness
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
        brightness = try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 100
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
