import Foundation
import XCTest
@testable import BookSmarts

final class BookMarkPerformanceTests: XCTestCase {
    private let performanceMetrics: [XCTMetric] = [
        XCTClockMetric(),
        XCTCPUMetric(),
        XCTMemoryMetric()
    ]

    func testReadingSpeedEstimatorPerformance() {
        let sessions = Self.makeSessions(count: 20_000)

        measure(metrics: performanceMetrics) {
            _ = ReadingSpeedEstimator.overallWPM(from: sessions)
            _ = ReadingSpeedEstimator.wpm(forBookID: "book-17", sessions: sessions)
        }
    }

    func testStatsAggregationPerformance() {
        let sessions = Self.makeSessions(count: 30_000)
        let calendar = Calendar(identifier: .gregorian)
        let wordsPerPage = ReaderSettings.defaultPhoneWordsPerPage

        measure(metrics: performanceMetrics) {
            var totalSeconds = 0
            var totalPages = 0
            var totalWords = 0
            var secondsByDay: [String: Int] = [:]
            var wordsByDay: [String: Int] = [:]

            for session in sessions {
                totalSeconds += session.secs
                totalPages += session.pages ?? 0
                let estimatedWords = session.wordsRead ?? ((session.pages ?? 0) * wordsPerPage)
                totalWords += estimatedWords

                let components = calendar.dateComponents([.year, .month, .day], from: session.start)
                let key = "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
                secondsByDay[key, default: 0] += session.secs
                wordsByDay[key, default: 0] += estimatedWords
            }

            XCTAssertGreaterThan(totalSeconds, 0)
            XCTAssertGreaterThan(totalPages, 0)
            XCTAssertGreaterThan(totalWords, 0)
            XCTAssertFalse(secondsByDay.isEmpty)
            XCTAssertFalse(wordsByDay.isEmpty)
        }
    }

    func testBackupEncodingPerformance() throws {
        let backup = Store.Backup(
            version: "native-1",
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            books: Self.makeBooks(count: 2_000),
            sessions: Self.makeSessions(count: 30_000),
            progress: Self.makeProgress(count: 2_000),
            bookmarks: Self.makeBookmarks(bookCount: 2_000, bookmarksPerBook: 2),
            highlights: [:],
            goal: ReadingGoal(),
            readerSettings: ReaderSettings()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        measure(metrics: performanceMetrics) {
            let data = try? encoder.encode(backup)
            XCTAssertNotNil(data)
            XCTAssertGreaterThan(data?.count ?? 0, 0)
        }
    }

    private static func makeBooks(count: Int) -> [Book] {
        (0..<count).map { index in
            Book(
                id: "book-\(index)",
                title: "Performance Book \(index)",
                author: "Author \(index % 37)",
                added: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                order: index,
                totalWords: 60_000 + (index % 90_000)
            )
        }
    }

    private static func makeSessions(count: Int) -> [ReadingSession] {
        (0..<count).map { index in
            let bookIndex = index % 2_000
            let seconds = 300 + (index % 2_700)
            let pages = 1 + (index % 14)
            let wordsRead = index.isMultiple(of: 4) ? nil : 220 + (index % 4_000)
            let start = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + (index * 3_600)))
            return ReadingSession(
                id: "session-\(index)",
                bookId: "book-\(bookIndex)",
                bookTitle: "Performance Book \(bookIndex)",
                start: start,
                end: Date(timeInterval: TimeInterval(seconds), since: start),
                secs: seconds,
                pages: pages,
                wordsRead: wordsRead,
                progressDelta: Double(pages) / 350.0,
                manual: index.isMultiple(of: 11)
            )
        }
    }

    private static func makeProgress(count: Int) -> [String: ReadingProgress] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { index in
            (
                "book-\(index)",
                ReadingProgress(
                    pct: Double(index % 100) / 100.0,
                    cfi: nil,
                    lastRead: Date(timeIntervalSince1970: TimeInterval(1_710_000_000 + index))
                )
            )
        })
    }

    private static func makeBookmarks(bookCount: Int, bookmarksPerBook: Int) -> [String: [Bookmark]] {
        Dictionary(uniqueKeysWithValues: (0..<bookCount).map { bookIndex in
            let bookmarks = (0..<bookmarksPerBook).map { bookmarkIndex in
                Bookmark(
                    id: "bookmark-\(bookIndex)-\(bookmarkIndex)",
                    cfi: "/6/\(bookmarkIndex * 2)[chapter-\(bookmarkIndex)]",
                    label: "Bookmark \(bookmarkIndex)",
                    pct: Double(bookmarkIndex + 1) / Double(bookmarksPerBook + 1),
                    page: 10 + bookmarkIndex,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(1_720_000_000 + bookIndex + bookmarkIndex))
                )
            }
            return ("book-\(bookIndex)", bookmarks)
        })
    }
}
