import Foundation

/// Accepts backup JSON from both the new native app and the old Capacitor/web app.
///
/// Old web backups can take several shapes:
/// - Top-level keys like `f_books`, `f_sessions`, `f_progress`, `f_bookmarks`, `f_goal`,
///   `f_reader_settings` (matches the localStorage/IndexedDB persistence payload).
/// - Top-level `books`, `sessions`, `progress` etc. (a wrapped export).
/// - Books with `cover` as a data URL string (`data:image/...;base64,...`) instead of raw Data.
/// - Sessions with `start`/`end` as ISO strings or epoch milliseconds.
/// - Progress entries with `lastRead` as epoch ms (Date.now()).
enum BackupMigration {
    static func decode(_ data: Data) -> Store.Backup? {
        // First try the native shape exactly as we export it.
        let nativeDecoder = JSONDecoder()
        nativeDecoder.dateDecodingStrategy = .iso8601
        if let b = try? nativeDecoder.decode(Store.Backup.self, from: data) {
            return b
        }

        // Fall back to the flexible legacy decoder
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decodeFlexible(json)
    }

    private static func decodeFlexible(_ root: [String: Any]) -> Store.Backup? {
        let booksRaw    = unwrapArray(root["books"]    ?? root["f_books"]    ?? [])
        let sessionsRaw = unwrapArray(root["sessions"] ?? root["f_sessions"] ?? [])
        let progressRaw = unwrapDict(root["progress"]  ?? root["f_progress"] ?? [:])
        let bookmarksRaw = unwrapDict(root["bookmarks"] ?? root["f_bookmarks"] ?? [:])
        let goalRaw     = unwrapDict(root["goal"]      ?? root["f_goal"]     ?? [:])
        let settingsRaw = unwrapDict(root["readerSettings"] ?? root["reader_settings"] ?? root["f_reader_settings"] ?? [:])

        let books    = decodeBooks(booksRaw)
        let sessions = decodeSessions(sessionsRaw)
        let progress = decodeProgress(progressRaw)
        let bookmarks = decodeBookmarks(bookmarksRaw)
        let goal     = decodeGoal(goalRaw)
        let settings = decodeReaderSettings(settingsRaw)

        return Store.Backup(
            version: (root["version"] as? String) ?? "legacy",
            exportedAt: parseDate(root["exportedAt"]) ?? Date(),
            books: books,
            sessions: sessions,
            progress: progress,
            bookmarks: bookmarks,
            goal: goal,
            readerSettings: settings
        )
    }

    private static func unwrapArray(_ v: Any) -> [[String: Any]] {
        // Some old backups stash the value as a JSON string (because the persistence
        // layer called JSON.stringify before storing in localStorage). Handle both.
        if let arr = v as? [[String: Any]] { return arr }
        if let s = v as? String, let data = s.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr
        }
        return []
    }

    private static func unwrapDict(_ v: Any) -> [String: Any] {
        if let d = v as? [String: Any] { return d }
        if let s = v as? String, let data = s.data(using: .utf8),
           let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return d
        }
        return [:]
    }

    private static func decodeBooks(_ raw: [[String: Any]]) -> [Book] {
        raw.compactMap { dict in
            guard let id = dict["id"] as? String ?? (dict["id"] as? Int).map(String.init),
                  let title = dict["title"] as? String
            else { return nil }
            return Book(
                id: id,
                title: title,
                author: (dict["author"] as? String) ?? "Unknown Author",
                added: parseDate(dict["added"]) ?? Date(),
                order: (dict["order"] as? Int) ?? 0,
                finished: (dict["finished"] as? Bool) ?? false,
                finishedAt: parseDate(dict["finishedAt"]),
                coverData: decodeCover(dict["cover"] ?? dict["coverData"]),
                fileBookmark: nil,
                fileName: nil,
                totalLocations: dict["totalLocations"] as? Int
            )
        }
    }

    private static func decodeCover(_ raw: Any?) -> Data? {
        if let s = raw as? String {
            // Possible forms: "data:image/png;base64,AAA...", or plain base64
            if s.hasPrefix("data:"),
               let comma = s.firstIndex(of: ",") {
                let base64 = String(s[s.index(after: comma)...])
                return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
            }
            return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
        }
        return nil
    }

    private static func decodeSessions(_ raw: [[String: Any]]) -> [ReadingSession] {
        raw.compactMap { dict in
            guard let start = parseDate(dict["start"]) else { return nil }
            let secs: Int = {
                if let v = dict["secs"] as? Int { return v }
                if let v = dict["secs"] as? Double { return Int(v) }
                return 0
            }()
            return ReadingSession(
                id: (dict["id"] as? String) ?? UUID().uuidString,
                bookId: dict["bookId"] as? String,
                bookTitle: (dict["bookTitle"] as? String) ?? "Untitled",
                start: start,
                end: parseDate(dict["end"]),
                secs: secs,
                pages: dict["pages"] as? Int,
                posPages: dict["posPages"] as? Int,
                progressDelta: (dict["progressDelta"] as? Double) ?? (dict["dPct"] as? Double),
                manual: (dict["manual"] as? Bool) ?? false
            )
        }
    }

    private static func decodeProgress(_ raw: [String: Any]) -> [String: ReadingProgress] {
        var out: [String: ReadingProgress] = [:]
        for (k, v) in raw {
            guard let dict = v as? [String: Any] else { continue }
            let pct = (dict["pct"] as? Double) ?? 0
            let cfi = dict["cfi"] as? String
            let lastRead = parseDate(dict["lastRead"]) ?? Date()
            let ratio = dict["swipesPerPosition"] as? Double
            out[k] = ReadingProgress(pct: pct, cfi: cfi, lastRead: lastRead, swipesPerPosition: ratio)
        }
        return out
    }

    private static func decodeBookmarks(_ raw: [String: Any]) -> [String: [Bookmark]] {
        var out: [String: [Bookmark]] = [:]
        for (bookId, value) in raw {
            let entries = unwrapArray(value)
            let list: [Bookmark] = entries.compactMap { dict in
                guard let cfi = dict["cfi"] as? String else { return nil }
                return Bookmark(
                    id: (dict["id"] as? String) ?? UUID().uuidString,
                    cfi: cfi,
                    label: (dict["label"] as? String) ?? "Bookmark",
                    pct: (dict["pct"] as? Double) ?? 0,
                    page: bookmarkPage(from: dict["page"]),
                    createdAt: parseDate(dict["createdAt"]) ?? Date()
                )
            }
            if !list.isEmpty { out[bookId] = list }
        }
        return out
    }

    private static func decodeGoal(_ raw: [String: Any]) -> ReadingGoal {
        let minutes = (raw["minutes"] as? Int)
            ?? Int((raw["minutes"] as? Double) ?? 15)
        return ReadingGoal(minutes: max(1, minutes))
    }

    private static func decodeReaderSettings(_ raw: [String: Any]) -> ReaderSettings {
        var s = ReaderSettings()
        if let v = raw["theme"] as? String {
            switch v {
            case "original": s.theme = .original
            case "quiet", "sepia": s.theme = .quiet
            case "paper", "light": s.theme = .paper
            case "calm": s.theme = .calm
            case "focus", "dark": s.theme = .focus
            case "night": s.theme = .night
            default: break
            }
        }
        if let v = raw["fontSize"] as? Int { s.fontSize = v }
        if let v = raw["fontSize"] as? Double { s.fontSize = Int(v) }
        if let v = raw["bold"] as? Bool { s.bold = v }
        if let v = raw["lineHeight"] as? Double { s.lineHeight = v }
        if let v = raw["margins"] as? String {
            switch v {
            case "narrow": s.margins = .narrow
            case "wide": s.margins = .wide
            default: s.margins = .normal
            }
        }
        if let v = raw["justify"] as? Bool { s.justify = v }
        if let v = raw["pageAnim"] as? String {
            switch v {
            case "fade": s.pageAnim = .fade
            case "rigid": s.pageAnim = .rigid
            case "curl": s.pageAnim = .curl
            case "none": s.pageAnim = .none
            default: s.pageAnim = .slide
            }
        }
        if let v = raw["swipe"] as? Bool { s.swipe = v }
        if let v = raw["keepAwake"] as? Bool { s.keepAwake = v }
        if let v = raw["brightness"] as? Int { s.brightness = v }
        if let v = raw["brightness"] as? Double { s.brightness = Int(v) }
        return s
    }

    private static func bookmarkPage(from raw: Any?) -> Int? {
        if let page = raw as? Int, page > 0 { return page }
        if let page = raw as? Double, page > 0 { return Int(page) }
        return nil
    }

    /// Parses a date from a String (ISO8601 or RFC3339-ish) or a Number (epoch seconds or ms).
    private static func parseDate(_ raw: Any?) -> Date? {
        if let d = raw as? Date { return d }
        if let s = raw as? String {
            if let date = isoFormatter.date(from: s) { return date }
            if let date = isoFormatterFractional.date(from: s) { return date }
            // Bare YYYY-MM-DD
            if let date = ymdFormatter.date(from: s) { return date }
        }
        if let n = raw as? Double {
            // Heuristic: anything past 10^12 is milliseconds, otherwise seconds.
            return n > 1_000_000_000_000 ? Date(timeIntervalSince1970: n / 1000.0) : Date(timeIntervalSince1970: n)
        }
        if let n = raw as? Int {
            return parseDate(Double(n))
        }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let ymdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
