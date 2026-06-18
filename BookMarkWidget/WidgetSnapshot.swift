import Foundation
import UIKit

/// Mirrors `SharedSnapshot` in the main app so the widget can decode the JSON
/// the main app writes to the App Group container. Field names + types must
/// stay in sync with `SharedSnapshot` in `BookMark/App/Models.swift`.
struct WidgetSnapshot: Codable, Hashable {
    var todayMinutes: Int
    var goalMinutes: Int
    var currentStreak: Int
    var bestStreak: Int

    var continueTitle: String?
    var continueAuthor: String?
    var continueProgressPct: Int?
    var continueBookSeconds: Int?
    var continueCoverFile: String?
    var continueSmallCoverFile: String?

    var totalBooks: Int
    var finishedBooks: Int
    var totalSeconds: Int
    var avgSessionSeconds: Int
    var weekSeconds: Int
    var totalPages: Int
    var avgPages: Int
    var weekPages: Int
    var avgPace: Double

    var last7DayLabels: [String]
    var last7DaySeconds: [Int]
    var last7DayPace: [Double]

    var updatedAt: Date

    init(
        todayMinutes: Int,
        goalMinutes: Int,
        currentStreak: Int,
        bestStreak: Int,
        continueTitle: String?,
        continueAuthor: String?,
        continueProgressPct: Int?,
        continueBookSeconds: Int?,
        continueCoverFile: String?,
        continueSmallCoverFile: String?,
        totalBooks: Int,
        finishedBooks: Int,
        totalSeconds: Int,
        avgSessionSeconds: Int,
        weekSeconds: Int,
        totalPages: Int,
        avgPages: Int,
        weekPages: Int,
        avgPace: Double,
        last7DayLabels: [String],
        last7DaySeconds: [Int],
        last7DayPace: [Double],
        updatedAt: Date
    ) {
        self.todayMinutes = todayMinutes
        self.goalMinutes = goalMinutes
        self.currentStreak = currentStreak
        self.bestStreak = bestStreak
        self.continueTitle = continueTitle
        self.continueAuthor = continueAuthor
        self.continueProgressPct = continueProgressPct
        self.continueBookSeconds = continueBookSeconds
        self.continueCoverFile = continueCoverFile
        self.continueSmallCoverFile = continueSmallCoverFile
        self.totalBooks = totalBooks
        self.finishedBooks = finishedBooks
        self.totalSeconds = totalSeconds
        self.avgSessionSeconds = avgSessionSeconds
        self.weekSeconds = weekSeconds
        self.totalPages = totalPages
        self.avgPages = avgPages
        self.weekPages = weekPages
        self.avgPace = avgPace
        self.last7DayLabels = last7DayLabels
        self.last7DaySeconds = last7DaySeconds
        self.last7DayPace = last7DayPace
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case todayMinutes, goalMinutes, currentStreak, bestStreak
        case continueTitle, continueAuthor, continueProgressPct, continueBookSeconds, continueCoverFile, continueSmallCoverFile
        case totalBooks, finishedBooks, totalSeconds, avgSessionSeconds, weekSeconds
        case totalPages, avgPages, weekPages, avgPace
        case last7DayLabels, last7DaySeconds, last7DayPace, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todayMinutes = try c.decodeIfPresent(Int.self, forKey: .todayMinutes) ?? 0
        goalMinutes = try c.decodeIfPresent(Int.self, forKey: .goalMinutes) ?? 15
        currentStreak = try c.decodeIfPresent(Int.self, forKey: .currentStreak) ?? 0
        bestStreak = try c.decodeIfPresent(Int.self, forKey: .bestStreak) ?? 0
        continueTitle = try c.decodeIfPresent(String.self, forKey: .continueTitle)
        continueAuthor = try c.decodeIfPresent(String.self, forKey: .continueAuthor)
        continueProgressPct = try c.decodeIfPresent(Int.self, forKey: .continueProgressPct)
        continueBookSeconds = try c.decodeIfPresent(Int.self, forKey: .continueBookSeconds)
        continueCoverFile = try c.decodeIfPresent(String.self, forKey: .continueCoverFile)
        continueSmallCoverFile = try c.decodeIfPresent(String.self, forKey: .continueSmallCoverFile)
        totalBooks = try c.decodeIfPresent(Int.self, forKey: .totalBooks) ?? 0
        finishedBooks = try c.decodeIfPresent(Int.self, forKey: .finishedBooks) ?? 0
        totalSeconds = try c.decodeIfPresent(Int.self, forKey: .totalSeconds) ?? 0
        avgSessionSeconds = try c.decodeIfPresent(Int.self, forKey: .avgSessionSeconds) ?? 0
        weekSeconds = try c.decodeIfPresent(Int.self, forKey: .weekSeconds) ?? 0
        totalPages = try c.decodeIfPresent(Int.self, forKey: .totalPages) ?? 0
        avgPages = try c.decodeIfPresent(Int.self, forKey: .avgPages) ?? 0
        weekPages = try c.decodeIfPresent(Int.self, forKey: .weekPages) ?? 0
        avgPace = try c.decodeIfPresent(Double.self, forKey: .avgPace) ?? 0
        last7DayLabels = try c.decodeIfPresent([String].self, forKey: .last7DayLabels) ?? WidgetSnapshot.empty.last7DayLabels
        last7DaySeconds = try c.decodeIfPresent([Int].self, forKey: .last7DaySeconds) ?? WidgetSnapshot.empty.last7DaySeconds
        last7DayPace = try c.decodeIfPresent([Double].self, forKey: .last7DayPace) ?? WidgetSnapshot.empty.last7DayPace
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    static let empty = WidgetSnapshot(
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
        last7DayLabels: ["S","M","T","W","T","F","S"],
        last7DaySeconds: [0,0,0,0,0,0,0],
        last7DayPace: [0,0,0,0,0,0,0],
        updatedAt: Date()
    )

    static let preview: WidgetSnapshot = {
        var s = WidgetSnapshot.empty
        s.todayMinutes = 22
        s.goalMinutes = 30
        s.currentStreak = 5
        s.bestStreak = 14
        s.continueTitle = "Oathbringer"
        s.continueAuthor = "Brandon Sanderson"
        s.continueProgressPct = 38
        s.continueBookSeconds = 6 * 3600 + 14 * 60
        s.totalBooks = 12
        s.finishedBooks = 4
        s.totalSeconds = 92 * 3600
        s.avgSessionSeconds = 28 * 60
        s.weekSeconds = 5 * 3600 + 12 * 60
        s.totalPages = 4_280
        s.avgPages = 18
        s.weekPages = 240
        s.avgPace = 1.32
        s.last7DaySeconds = [22 * 60, 0, 35 * 60, 12 * 60, 48 * 60, 14 * 60, 22 * 60]
        s.last7DayPace = [1.2, 0, 1.4, 0.9, 1.7, 1.1, 1.3]
        return s
    }()
}

/// Loads the latest `WidgetSnapshot` written by the main app, plus the saved
/// cover image (if any), from the shared App Group container.
enum WidgetSnapshotStore {
    static let appGroupID = "group.com.bdeavilla.bookmark"

    static func load() -> WidgetSnapshot {
        if let url = snapshotURL(),
           let data = try? Data(contentsOf: url),
           let decoded = decodeSnapshot(data) {
            return decoded
        }

        if let defaults = UserDefaults(suiteName: appGroupID),
           let data = defaults.data(forKey: "widget-snapshot-data"),
           let decoded = decodeSnapshot(data) {
            return decoded
        }

        return .empty
    }

    private static func decodeSnapshot(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func loadCover(filename: String?) -> UIImage? {
        guard let filename, !filename.isEmpty else { return nil }
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let url = group
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private static func snapshotURL() -> URL? {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        return group
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
    }
}

enum WidgetFmt {
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let h = m / 60
        return h > 0 ? "\(h)h \(m % 60)m" : "\(m)m"
    }

    static func compactPace(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
