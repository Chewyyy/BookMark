import Foundation
import SwiftSoup

/// Walks an EPUB's spine and returns a word count per resource plus a total.
/// Used at import time to give every Book a stable, device-independent
/// content size that downstream stats (WPM, standardized pages, words/day)
/// can be computed from regardless of which device the user reads on.
enum EPUBWordCounter {
    /// Default page size used by `standardizedPages(forWords:wordsPerPage:)`.
    static let wordsPerStandardPage = 300

    struct Result {
        /// One entry per spine item, in spine order. Same length as `package.spine`.
        var perSpine: [Int]
        /// Sum of `perSpine`.
        var total: Int
    }

    /// Synchronously counts words in every spine item of the given package.
    /// Caller should run this off the main actor — a long textbook can take
    /// a few hundred milliseconds.
    static func count(in package: EPUBPackage) -> Result {
        var perSpine: [Int] = []
        perSpine.reserveCapacity(package.spine.count)
        var total = 0
        for entry in package.spine {
            let n = wordsFor(spineHref: entry.href, archive: package.archive)
            perSpine.append(n)
            total += n
        }
        return Result(perSpine: perSpine, total: total)
    }

    /// Number of pages a word count corresponds to. Rounds up so partial
    /// pages count — matches user intuition that "I read part of a page"
    /// should register as 1.
    static func standardizedPages(forWords words: Int, wordsPerPage: Int = wordsPerStandardPage) -> Int {
        guard words > 0 else { return 0 }
        return Int(ceil(Double(words) / Double(max(1, wordsPerPage))))
    }

    // MARK: - Internal

    /// Extracts a single spine item's HTML, strips non-content tags, and
    /// counts whitespace-separated word tokens in the remaining visible text.
    /// Returns 0 on any parse failure rather than blowing up — a malformed
    /// chapter just won't contribute to the total. Better to under-count
    /// than to fail an import outright.
    private static func wordsFor(spineHref: String, archive: MiniZip.Archive) -> Int {
        guard let data = archive.extract(name: spineHref),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            return 0
        }
        do {
            let doc = try SwiftSoup.parse(html)
            // Remove non-content sections before extracting text. Anything that's
            // navigation chrome, decoration, or invisible-to-the-reader gets
            // stripped so WPM reflects only the actual prose the user reads.
            for selector in nonContentSelectors {
                try doc.select(selector).remove()
            }
            let text = try doc.body()?.text() ?? doc.text()
            return countWords(in: text)
        } catch {
            return 0
        }
    }

    /// CSS selectors for elements that don't contribute to the reading flow.
    /// Order doesn't matter; SwiftSoup removes each match independently.
    private static let nonContentSelectors: [String] = [
        "script",
        "style",
        "noscript",
        "nav",            // EPUB 3 navigation documents and inline nav menus
        "aside[epub|type=footnote]",
        "aside[epub|type=endnote]",
        "[epub|type=pagebreak]",
        "[hidden]",
    ]

    /// Counts whitespace-separated tokens that contain at least one letter or
    /// digit. Stand-alone punctuation, ornaments, and similar visual chrome
    /// are skipped — the user didn't really "read" a § or ✦.
    private static func countWords(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        let scalars = text.unicodeScalars
        var inWord = false
        for scalar in scalars {
            let isWordChar = CharacterSet.alphanumerics.contains(scalar)
            if isWordChar {
                if !inWord {
                    inWord = true
                    count += 1
                }
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            }
            // Other characters (punctuation) don't start or end a word — they
            // just stay attached to the current word run. So "don't" or
            // "well-formed" each count as one.
        }
        return count
    }
}
