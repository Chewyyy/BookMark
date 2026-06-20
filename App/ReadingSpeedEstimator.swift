import Foundation

/// Computes the reader's words-per-minute pace and projects time-remaining
/// estimates for chapters and books — the foundation for Kindle-style "X
/// minutes left in chapter / book" indicators. Pure functions; no UI, no
/// stored state. Surfaces that want to render an estimate call into here
/// with the session history they have.
///
/// Pace philosophy (mirrors what Kindle does, roughly):
/// - Prefer a per-book pace when there's enough data, since reading speed
///   varies meaningfully by genre / density (a textbook reads slower than
///   trade fiction).
/// - Fall back to an overall pace across the library when the per-book
///   pool is too small to trust.
/// - Weight toward recent sessions so a one-off marathon doesn't anchor
///   the estimate forever.
enum ReadingSpeedEstimator {
    /// How many word-tracked sessions a single book needs before its own
    /// pace is trusted over the overall library average.
    static let minSessionsForBookEstimate = 3

    /// How many most-recent sessions to include in either aggregation.
    /// Older sessions still contribute via half-weight to keep changes
    /// gradual, but the latest window dominates.
    static let recentWindow = 10

    /// Fallback pace assumed when there isn't a single word-tracked
    /// session anywhere in the library — used only to keep first-launch
    /// "time remaining" surfaces from being blank. 240 WPM is a typical
    /// adult silent-reading speed.
    static let defaultWPM: Double = 240

    // MARK: - Pace

    /// Pace in words/minute, weighted recent-first. Returns nil when there
    /// is no word-tracked session data at all.
    static func overallWPM(from sessions: [ReadingSession]) -> Double? {
        let pool = wordSessionsByRecent(sessions)
        return weightedWPM(from: pool)
    }

    /// Pace for a single book, with the overall library pace as fallback
    /// when the per-book sample is below `minSessionsForBookEstimate`.
    /// Returns nil only when neither pool has any data.
    static func wpm(forBookID bookID: String, sessions: [ReadingSession]) -> Double? {
        let bookPool = wordSessionsByRecent(sessions.filter { $0.bookId == bookID })
        if bookPool.count >= minSessionsForBookEstimate,
           let bookPace = weightedWPM(from: bookPool) {
            return bookPace
        }
        return overallWPM(from: sessions)
    }

    /// The pace surfaces should display when no real data exists yet —
    /// keeps "time remaining" rows readable on a brand-new install.
    static func wpmOrDefault(forBookID bookID: String?, sessions: [ReadingSession]) -> Double {
        if let id = bookID, let pace = wpm(forBookID: id, sessions: sessions) {
            return pace
        }
        return overallWPM(from: sessions) ?? defaultWPM
    }

    // MARK: - Time remaining

    /// Minutes left to finish the book given current position in words.
    /// Returns nil if the book has no parsed word count yet.
    static func minutesRemainingInBook(
        book: Book,
        currentWordOffset: Int,
        wpm: Double
    ) -> Int? {
        guard let total = book.totalWords, total > 0, wpm > 0 else { return nil }
        let remaining = max(0, total - currentWordOffset)
        return Int((Double(remaining) / wpm).rounded())
    }

    /// Minutes left to finish the current chapter. Caller supplies the
    /// chapter's word count (from `book.wordCountsPerSpine[idx]`) and the
    /// progression within that chapter (0...1 from Readium).
    static func minutesRemainingInChapter(
        wordsInChapter: Int,
        progressionInChapter: Double,
        wpm: Double
    ) -> Int? {
        guard wordsInChapter > 0, wpm > 0 else { return nil }
        let bounded = max(0.0, min(1.0, progressionInChapter))
        let remaining = Int(Double(wordsInChapter) * (1.0 - bounded))
        return Int((Double(remaining) / wpm).rounded())
    }

    // MARK: - Internal helpers

    /// Sessions filtered to "has wordsRead + has time" and sorted
    /// newest-first, truncated to the recent window so a single ancient
    /// long-haul session doesn't dominate.
    private static func wordSessionsByRecent(_ sessions: [ReadingSession]) -> [ReadingSession] {
        sessions
            .filter { ($0.wordsRead ?? 0) > 0 && $0.secs > 0 }
            .sorted { $0.start > $1.start }
            .prefix(recentWindow * 2)  // include some older context for weighting
            .map { $0 }
    }

    /// WPM with the most-recent `recentWindow` sessions weighted at 1.0
    /// and the next-older `recentWindow` sessions weighted at 0.5. Gives
    /// the estimate a "settling" feel: a single fast or slow session shifts
    /// the number but doesn't flip it.
    private static func weightedWPM(from pool: [ReadingSession]) -> Double? {
        guard !pool.isEmpty else { return nil }
        var weightedWords = 0.0
        var weightedSecs = 0.0
        for (i, s) in pool.enumerated() {
            let weight: Double = i < recentWindow ? 1.0 : 0.5
            weightedWords += Double(s.wordsRead ?? 0) * weight
            weightedSecs  += Double(s.secs) * weight
        }
        guard weightedSecs > 0 else { return nil }
        return weightedWords / (weightedSecs / 60.0)
    }
}
