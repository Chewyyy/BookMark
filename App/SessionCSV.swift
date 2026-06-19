import Foundation

/// Ports the webapp's `importCsvSessions` / `buildSessionsCsv` so users can move
/// session history in/out as CSV.
enum SessionCSV {
    struct ImportResult {
        var added: Int
        var updated: Int
        var skipped: Int
    }

    @MainActor
    static func importCSV(data: Data, into store: Store) -> ImportResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return ImportResult(added: 0, updated: 0, skipped: 0)
        }
        let rows = parseCSV(text)
        guard rows.count > 1 else { return ImportResult(added: 0, updated: 0, skipped: 0) }

        let headers = rows[0]
        var added = 0, updated = 0, skipped = 0

        for row in rows.dropFirst() {
            let get = makeGetter(headers: headers, row: row)
            let title = first(get, ["Title", "Book", "Book Title"]) ?? "CSV Import"
            let dateStr = first(get, ["Date", "Session Date", "Day"]) ?? first(get, ["Month"]) ?? ""
            let startTime = first(get, ["Start Time", "Start"]) ?? "00:00"
            let endTime = first(get, ["End Time", "End"])
            var mins = Int((parseLoose(first(get, ["Session Minutes", "Minutes", "Mins"]) ?? "")).rounded())
            let pages = max(0, Int(parseLoose(first(get, ["Session Pages", "Pages", "Pages Read"]) ?? "").rounded()))
            let publisherPages = max(0, Int(parseLoose(first(get, ["Publisher Pages", "Publisher Pages Read", "publisherPages"]) ?? "").rounded()))

            let start = makeDate(dateStr: dateStr, timeStr: startTime)
            var end: Date? = endTime.flatMap { makeDate(dateStr: dateStr, timeStr: $0) }
            if let e = end, e < start { end = e.addingTimeInterval(86_400) }
            if mins < 1, let e = end {
                mins = Int(round(e.timeIntervalSince(start) / 60.0))
            }
            if mins < 1 { skipped += 1; continue }
            if end == nil { end = start.addingTimeInterval(Double(mins) * 60.0) }

            let book = store.books.first {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }

            let candidate = ReadingSession(
                bookId: book?.id,
                bookTitle: title,
                start: start,
                end: end,
                secs: min(720 * 60, mins * 60),
                pages: pages > 0 ? pages : nil,
                publisherPages: publisherPages > 0 ? publisherPages : nil,
                manual: true
            )

            if let existing = duplicate(of: candidate, in: store.sessions) {
                if dataScore(candidate) > dataScore(existing) {
                    // CSV row carries fields the stored session is missing
                    // (e.g. pages, linked book, progress delta) — keep the
                    // existing id so references remain valid, otherwise take
                    // the richer CSV row wholesale.
                    var replacement = candidate
                    replacement.id = existing.id
                    store.updateSession(replacement)
                    updated += 1
                } else {
                    skipped += 1
                }
                continue
            }
            store.addSession(candidate)
            added += 1
        }

        return ImportResult(added: added, updated: updated, skipped: skipped)
    }

    // MARK: - CSV parser (handles quoted commas + escaped quotes)

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
            if inQuotes {
                if ch == "\"" && next == "\"" { cell.append("\""); i += 2; continue }
                if ch == "\"" { inQuotes = false; i += 1; continue }
                cell.append(ch); i += 1
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",": row.append(cell); cell = ""
                case "\n":
                    row.append(cell); rows.append(row); row = []; cell = ""
                case "\r": break
                default: cell.append(ch)
                }
                i += 1
            }
        }
        row.append(cell); rows.append(row)
        return rows.filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    private static func makeGetter(headers: [String], row: [String]) -> (String) -> String? {
        var map: [String: Int] = [:]
        for (i, h) in headers.enumerated() { map[normalize(h)] = i }
        return { name in
            guard let idx = map[normalize(name)], idx < row.count else { return nil }
            let trimmed = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func first(_ get: (String) -> String?, _ names: [String]) -> String? {
        for n in names { if let v = get(n) { return v } }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    private static func parseLoose(_ s: String) -> Double {
        let cleaned = s.filter { "0123456789.-".contains($0) }
        return Double(cleaned) ?? 0
    }

    /// Two sessions are the same if they reference the same book and cover the
    /// exact same start/end instant — i.e. book + date + start time + end time
    /// all match. Pages/secs are deliberately excluded so editing one of those
    /// fields on a re-import doesn't create a duplicate.
    private static func duplicate(of s: ReadingSession, in existing: [ReadingSession]) -> ReadingSession? {
        let iso = ISO8601DateFormatter()
        let key: (ReadingSession) -> String = { sess in
            let title = sess.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let start = iso.string(from: sess.start)
            let end = sess.end.map { iso.string(from: $0) } ?? ""
            return [title, start, end].joined(separator: "|")
        }
        let target = key(s)
        return existing.first { key($0) == target }
    }

    /// Counts how many "extra" fields a session has populated beyond the dedup
    /// key (start/end/title). When a CSV row scores higher than the stored
    /// session, the stored one gets overwritten with the richer CSV data.
    private static func dataScore(_ s: ReadingSession) -> Int {
        var n = 0
        if let p = s.pages, p > 0 { n += 1 }
        if let p = s.publisherPages, p > 0 { n += 1 }
        if let d = s.progressDelta, d > 0 { n += 1 }
        if let bid = s.bookId, !bid.isEmpty { n += 1 }
        return n
    }

    // MARK: - Date parsing (mirrors webapp parseDateParts + applyTimeParts)

    private static func makeDate(dateStr: String, timeStr: String) -> Date {
        let comps = parseDateParts(dateStr)
        let cal = Calendar(identifier: .gregorian)
        var date = cal.date(from: comps) ?? Date()
        date = applyTimeParts(date, timeStr: timeStr)
        return date
    }

    private static func parseDateParts(_ s: String) -> DateComponents {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let nowComps = cal.dateComponents([.year, .month, .day], from: now)
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nowComps }

        // YYYY-M[-D] or YYYY/M[/D]
        if let m = matchInts(trimmed, pattern: #"^(\d{4})[-/](\d{1,2})(?:[-/](\d{1,2}))?"#) {
            return DateComponents(year: m[0], month: m[1], day: m.count > 2 ? m[2] : 1)
        }
        // M/D/YY[YY]
        if let m = matchInts(trimmed, pattern: #"^(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})"#) {
            var year = m[2]
            if year < 100 { year += 2000 }
            return DateComponents(year: year, month: m[0], day: m[1])
        }
        // Fallback: try ISO8601
        if let date = ISO8601DateFormatter().date(from: trimmed) {
            return cal.dateComponents([.year, .month, .day], from: date)
        }
        return nowComps
    }

    private static func applyTimeParts(_ date: Date, timeStr: String) -> Date {
        let s = timeStr.trimmingCharacters(in: .whitespaces)
        var hour = 0, minute = 0
        if let regex = try? NSRegularExpression(pattern: #"(\d{1,2})(?::(\d{2}))?\s*(AM|PM)?"#, options: .caseInsensitive),
           let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let r = Range(m.range(at: 1), in: s) { hour = Int(s[r]) ?? 0 }
            if m.numberOfRanges > 2, let r = Range(m.range(at: 2), in: s) { minute = Int(s[r]) ?? 0 }
            if m.numberOfRanges > 3, let r = Range(m.range(at: 3), in: s) {
                let ap = s[r].uppercased()
                if ap == "PM" && hour < 12 { hour += 12 }
                if ap == "AM" && hour == 12 { hour = 0 }
            }
        }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    private static func matchInts(_ s: String, pattern: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1 else { return nil }
        var result: [Int] = []
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: s), let n = Int(s[r]) {
                result.append(n)
            }
        }
        return result.isEmpty ? nil : result
    }
}
