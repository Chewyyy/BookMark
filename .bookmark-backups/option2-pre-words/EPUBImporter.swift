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
                print("EPUB import failed: \(error)")
            }
        }
        return summary
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
                print("EPUB folder rescan failed for \(url.lastPathComponent): \(error)")
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
            return .success
        } catch {
            print("EPUB relink failed: \(error)")
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
        return store.addBook(book) ? .added : .relinked
    }
}
