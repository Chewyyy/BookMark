//
//  BookMarkTests.swift
//  BookMarkTests
//
//  Created by Brandon DeAvilla on 6/20/26.
//

import Testing
@testable import BookMark

// Tests for the reader chrome's "pages left in part / chapter" logic
// (`ReaderChromeLogic`). This is the part-vs-chapter decision that feeds the
// top chrome line and is the source of the Realistic-mode flicker when the
// reader crosses from a Part divider into the Part's first chapter.
//
// The fixture models a book whose TOC has two Parts, each with chapters:
//
//   offset 0  "Part One"   res 0  depth 0   (part divider page)
//   offset 1  "Chapter 1"  res 1  depth 1
//   offset 2  "Chapter 2"  res 2  depth 1
//   offset 3  "Part Two"   res 3  depth 0   (part divider page)
//   offset 4  "Chapter 3"  res 4  depth 1
//   offset 5  "Chapter 4"  res 5  depth 1
//
//   pagesPerChapter  = [2, 100, 80, 2, 90, 70]
//   chapterPageOffsets = [0, 2, 102, 182, 184, 274]   total = 344
//
//   Part One spans pages 1...182, Part Two spans 183...344.
struct ReaderChromeLogicTests {

    private typealias Row = ReaderChromeLogic.TOCRow
    private typealias Range = ReaderChromeLogic.SectionRange

    private static let rows: [Row] = [
        Row(offset: 0, title: "Part One",  href: "part1.xhtml", chapterIndex: 0, depth: 0),
        Row(offset: 1, title: "Chapter 1", href: "ch1.xhtml",   chapterIndex: 1, depth: 1),
        Row(offset: 2, title: "Chapter 2", href: "ch2.xhtml",   chapterIndex: 2, depth: 1),
        Row(offset: 3, title: "Part Two",  href: "part2.xhtml", chapterIndex: 3, depth: 0),
        Row(offset: 4, title: "Chapter 3", href: "ch3.xhtml",   chapterIndex: 4, depth: 1),
        Row(offset: 5, title: "Chapter 4", href: "ch4.xhtml",   chapterIndex: 5, depth: 1)
    ]
    private static let pages = [2, 100, 80, 2, 90, 70]
    private static let offsets = [0, 2, 102, 182, 184, 274]
    private static let total = 344

    private func range(resource: Int, href: String?, json: String? = nil) -> Range? {
        ReaderChromeLogic.sectionRange(
            rows: Self.rows,
            currentResource: resource,
            chapterPageOffsets: Self.offsets,
            pagesPerChapter: Self.pages,
            totalPages: Self.total,
            locatorHref: href,
            locatorJSON: json
        )
    }

    // MARK: Section range resolution

    @Test func partDividerShowsPartRange() {
        let r = range(resource: 0, href: "part1.xhtml")
        #expect(r == Range(kind: "part", startPage: 1, endPage: 182))
    }

    @Test func secondPartResolvesToEndOfBook() {
        // Last part has no following peer, so it must run to the final page.
        let r = range(resource: 3, href: "part2.xhtml")
        #expect(r == Range(kind: "part", startPage: 183, endPage: 344))
    }

    // The settled, correct behavior: once the locator points at the Part's
    // first chapter, there is no section to report and the chrome falls back
    // to "pages left in chapter". This is what swipe mode reliably shows.
    @Test func firstChapterInsidePartFallsBackToChapter() {
        #expect(range(resource: 1, href: "ch1.xhtml") == nil)
        #expect(range(resource: 2, href: "ch2.xhtml") == nil)
    }

    // Root-cause characterization of the reported bug. During a Realistic
    // page turn the resource index and the locator href update at different
    // times. While the resource has advanced into the first chapter (res 1)
    // but the locator href still lags on the part divider, the range must be
    // nil — i.e. the part text must NOT stick. The `chapterIndex == resource`
    // guard is what enforces this.
    @Test func staleLocatorWithAdvancedResourceDropsPartText() {
        #expect(range(resource: 1, href: "part1.xhtml") == nil)
    }

    // The mirror image: while the resource index still lags on the divider
    // (res 0), the part text legitimately persists. Combined with the test
    // above, this shows the rendered chrome flips part -> chapter purely as a
    // function of which `currentResource` the model reports. Any fix must
    // keep that input stable across the turn rather than letting it oscillate.
    @Test func staleResourceOnDividerKeepsPartText() {
        #expect(range(resource: 0, href: "part1.xhtml") == Range(kind: "part", startPage: 1, endPage: 182))
    }

    @Test func oscillatingResourceFlipsPartAndChapter() {
        // Simulate the model reporting an unstable resource index mid-turn
        // while the locator href lags behind on the divider. The section text
        // alternates, which is exactly the "rapid switching back and forth"
        // the user observes in Realistic mode.
        let sequence = [0, 1, 0, 1]
        let texts = sequence.map { res -> String? in
            ReaderChromeLogic.sectionPagesLeftText(
                range: range(resource: res, href: "part1.xhtml"),
                currentPage: 3
            )
        }
        #expect(texts == ["179 pages left in part", nil, "179 pages left in part", nil])
    }

    // MARK: sectionKind

    @Test func sectionKindClassification() {
        #expect(ReaderChromeLogic.sectionKind(for: "Part One") == "part")
        #expect(ReaderChromeLogic.sectionKind(for: "PART III") == "part")
        #expect(ReaderChromeLogic.sectionKind(for: "Interludes") == "interlude")
        #expect(ReaderChromeLogic.sectionKind(for: "Interlude: The Storm") == "interlude")
        #expect(ReaderChromeLogic.sectionKind(for: "Chapter 1") == "section")
        // "Part " prefix needs the trailing space — not just any "part*".
        #expect(ReaderChromeLogic.sectionKind(for: "Particle Physics") == "section")
    }

    // MARK: rowIsSectionStart

    @Test func rowIsSectionStartDetectsParents() {
        #expect(ReaderChromeLogic.rowIsSectionStart(Self.rows[0], rows: Self.rows))  // Part One: has children
        #expect(ReaderChromeLogic.rowIsSectionStart(Self.rows[3], rows: Self.rows))  // Part Two: has children
        #expect(!ReaderChromeLogic.rowIsSectionStart(Self.rows[1], rows: Self.rows)) // Chapter 1: leaf
        #expect(!ReaderChromeLogic.rowIsSectionStart(Self.rows[5], rows: Self.rows)) // Chapter 4: leaf
    }

    @Test func rowIsSectionStartDetectsTitledDividerWithoutChildren() {
        // A flat TOC with a divider entry that has no nested children still
        // counts as a section start via the title heuristic.
        let flat = [
            Row(offset: 0, title: "Interlude", href: "int.xhtml", chapterIndex: 0, depth: 0),
            Row(offset: 1, title: "Chapter 1", href: "ch1.xhtml", chapterIndex: 1, depth: 0)
        ]
        #expect(ReaderChromeLogic.rowIsSectionStart(flat[0], rows: flat))
        #expect(!ReaderChromeLogic.rowIsSectionStart(flat[1], rows: flat))
    }

    // MARK: sectionEndChapterIndex

    @Test func sectionEndChapterIndexStopsAtNextPeer() {
        #expect(ReaderChromeLogic.sectionEndChapterIndex(for: Self.rows[0], rows: Self.rows, chapterCount: 6) == 2)
        // Final part runs to the last chapter.
        #expect(ReaderChromeLogic.sectionEndChapterIndex(for: Self.rows[3], rows: Self.rows, chapterCount: 6) == 5)
    }

    // MARK: sectionPagesLeftText formatting

    @Test func pagesLeftTextFormatting() {
        let r = Range(kind: "part", startPage: 1, endPage: 182)
        #expect(ReaderChromeLogic.sectionPagesLeftText(range: r, currentPage: 100) == "82 pages left in part")
        #expect(ReaderChromeLogic.sectionPagesLeftText(range: r, currentPage: 181) == "1 page left in part")
        #expect(ReaderChromeLogic.sectionPagesLeftText(range: r, currentPage: 182) == "End of part")
        #expect(ReaderChromeLogic.sectionPagesLeftText(range: r, currentPage: 999) == "End of part")
        #expect(ReaderChromeLogic.sectionPagesLeftText(range: nil, currentPage: 100) == nil)
        #expect(ReaderChromeLogic.sectionPagesLeftText(range: r, currentPage: nil) == nil)
    }

    // MARK: normalizedHref + locator matching

    @Test func normalizedHrefDecodesAndCleans() {
        #expect(ReaderChromeLogic.normalizedHref("OEBPS/Text%20One.xhtml") == "OEBPS/Text One.xhtml")
        #expect(ReaderChromeLogic.normalizedHref("a\\b.xhtml") == "a/b.xhtml")
        #expect(ReaderChromeLogic.normalizedHref("  ch1.xhtml  ") == "ch1.xhtml")
    }

    @Test func locatorMatchPrefersDeepestRow() {
        // A locator that matches a chapter href must resolve to that leaf row,
        // not the shallower part divider — even when both share a path stem.
        let row = ReaderChromeLogic.currentLocatorTOCRow(
            in: Self.rows,
            locatorHref: "ch2.xhtml#frag",
            locatorJSON: nil
        )
        #expect(row?.chapterIndex == 2)
    }
}
