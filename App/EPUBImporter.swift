import Foundation
import UIKit

enum EPUBImporter {
    struct ImportSummary {
        var added = 0
        var relinked = 0
        var skipped = 0
        var failed = 0

        var imported: Int { added + relinked }
    }

    private enum ImportOutcome {
        case added
        case relinked
        case skipped
    }

    enum RelinkResult {
        case success
        case unreadable
    }

    @MainActor
    static func importFiles(_ urls: [URL], into store: Store) async -> ImportSummary {
        var summary = ImportSummary()
        for url in urls {
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

            do {
                let outcome = try importFile(url, into: store)
                switch outcome {
                case .added:
                    summary.added += 1
                case .relinked:
                    summary.relinked += 1
                case .skipped:
                    summary.skipped += 1
                }
            } catch {
                summary.failed += 1
                #if DEBUG
                print("EPUB import failed: \(error)")
                #endif
            }
        }
        return summary
    }

    /// Imports the onboarding sample EPUB shipped in the asset catalog (data
    /// set `OnboardingBook`). Safe to call repeatedly — `importFiles` skips by
    /// content fingerprint, so a reader who already has the sample won't get a
    /// duplicate. Returns the book id of the sample if it is present afterward.
    @MainActor
    @discardableResult
    static func importBundledSample(named assetName: String = "OnboardingBook", into store: Store) async -> String? {
        guard let data = NSDataAsset(name: assetName)?.data else { return nil }
        let fingerprint = Store.contentFingerprint(for: data)
        if let existing = store.books.first(where: { $0.contentFingerprint == fingerprint }) {
            return existing.id
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-sample-\(UUID().uuidString).epub")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = await importFiles([tmp], into: store)
            try? FileManager.default.removeItem(at: tmp)
        } catch {
            return nil
        }
        return store.books.first(where: { $0.contentFingerprint == fingerprint })?.id
    }

    @MainActor
    static func rescanFolder(_ folder: URL, into store: Store) async -> ImportSummary {
        let needsStop = folder.startAccessingSecurityScopedResource()
        defer { if needsStop { folder.stopAccessingSecurityScopedResource() } }

        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return ImportSummary(failed: 1)
        }

        let urls = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension.lowercased() == "epub" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.isRegularFile == true ? url : nil
        }

        var summary = ImportSummary()
        for url in urls {
            do {
                let outcome = try importFile(url, into: store)
                switch outcome {
                case .added:
                    summary.added += 1
                case .relinked:
                    summary.relinked += 1
                case .skipped:
                    summary.skipped += 1
                }
            } catch {
                summary.failed += 1
                #if DEBUG
                print("EPUB folder rescan failed for \(url.lastPathComponent): \(error)")
                #endif
            }
        }
        return summary
    }

    /// Replace the on-disk EPUB for an existing book. Sessions / progress /
    /// bookmarks stay intact because the book id is preserved. Mirrors the
    /// webapp's `promptRelinkBook` → `ingest(file, existId, …)` flow.
    @MainActor
    static func relinkBook(id: String, with url: URL, into store: Store) async -> RelinkResult {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }

        do {
            // Always write into a fresh UUID filename so cached `EPUBPackage`
            // values held by widgets / share extensions don't see stale data.
            let dest = Store.epubsDirectory().appendingPathComponent(UUID().uuidString + ".epub")
            try data.write(to: dest, options: .atomic)

            // Drop the prior file if any, ignoring failure (it may already be gone).
            if let existing = store.books.first(where: { $0.id == id }), let prior = existing.fileName {
                let priorURL = Store.epubsDirectory().appendingPathComponent(prior)
                try? FileManager.default.removeItem(at: priorURL)
            }

            let pkg = EPUBPackage.open(data: data)
            store.relink(
                bookId: id,
                fileName: dest.lastPathComponent,
                title: pkg?.title,
                author: pkg?.author,
                coverData: pkg?.coverData()
            )
            // Relinked EPUB has different content; re-count words so stats stay
            // accurate. Existing sessions stay attached to the same book id.
            if let pkg, !pkg.spine.isEmpty {
                countWordsInBackground(bookId: id, package: pkg, into: store)
            }
            return .success
        } catch {
            #if DEBUG
            print("EPUB relink failed: \(error)")
            #endif
            return .unreadable
        }
    }

    @MainActor
    private static func importFile(_ url: URL, into store: Store) throws -> ImportOutcome {
        let data = try Data(contentsOf: url)
        let fingerprint = Store.contentFingerprint(for: data)
        if store.containsBook(contentFingerprint: fingerprint) {
            return .skipped
        }

        let pkg = EPUBPackage.open(data: data)

        let dest = Store.epubsDirectory().appendingPathComponent(UUID().uuidString + ".epub")
        try data.write(to: dest, options: .atomic)

        let title = pkg?.title ?? url.deletingPathExtension().lastPathComponent
        let author = pkg?.author ?? "Unknown Author"
        let cover = pkg?.coverData()

        let book = Book(
            title: title,
            author: author,
            coverData: cover,
            fileBookmark: nil,
            fileName: dest.lastPathComponent,
            contentFingerprint: fingerprint
        )
        let addResult = store.addOrAttachBook(book)
        let outcome: ImportOutcome = addResult.added ? .added : .relinked

        // Word count parsing can take several hundred ms on textbooks, so we
        // hand the package off to a detached task and update the book once the
        // count is ready. The user sees the book in their library immediately;
        // word count, WPM, etc. fill in seconds later.
        if let pkg, !pkg.spine.isEmpty {
            countWordsInBackground(bookId: addResult.bookId, package: pkg, into: store)
        }
        return outcome
    }

    /// Off-main-actor word count + main-actor store update. Safe to call
    /// from import, rescan, or first-launch backfill.
    @MainActor
    static func countWordsInBackground(bookId: String, package: EPUBPackage, into store: Store) {
        Task.detached(priority: .utility) {
            let result = EPUBWordCounter.count(in: package)
            await MainActor.run {
                store.updateWordCounts(
                    bookId: bookId,
                    perSpine: result.perSpine,
                    total: result.total
                )
            }
        }
    }

    /// One-time backfill for books imported before word counting existed.
    /// Iterates the library, opens each EPUB lacking `totalWords`, kicks off
    /// the same background parse used at import. Cheap to call repeatedly —
    /// books with counts already present are skipped, so it's safe to wire
    /// into app launch even after every book has been counted.
    @MainActor
    static func backfillWordCounts(into store: Store) {
        let needsCount = store.books.filter { $0.totalWords == nil }
        guard !needsCount.isEmpty else { return }
        for book in needsCount {
            guard let fileName = book.fileName else { continue }
            let url = Store.epubsDirectory().appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let pkg = EPUBPackage.open(data: data),
                  !pkg.spine.isEmpty
            else { continue }
            countWordsInBackground(bookId: book.id, package: pkg, into: store)
        }
    }
}
