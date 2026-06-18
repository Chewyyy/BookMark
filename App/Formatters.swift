import Foundation

enum Fmt {
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let h = m / 60
        return h > 0 ? "\(h)h \(m % 60)m" : "\(m)m"
    }

    static func minutes(_ seconds: Int) -> Int { max(0, seconds) / 60 }

    static func timer(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func compactDate(_ date: Date, includeYear: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate(includeYear ? "MMM d, yyyy" : "MMM d")
        return f.string(from: date)
    }

    static func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateStyle = .long
        return f.string(from: date)
    }

    static func dateAndTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d · h:mm a"
        return f.string(from: date)
    }

    static func dayKey(_ date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    static func dateRange(_ first: Date, _ last: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(first, inSameDayAs: last) {
            return compactDate(first, includeYear: !cal.isDate(first, equalTo: Date(), toGranularity: .year))
        }
        let sameYear = cal.component(.year, from: first) == cal.component(.year, from: last)
        let sameMonth = sameYear && cal.component(.month, from: first) == cal.component(.month, from: last)
        if sameMonth {
            let mf = DateFormatter()
            mf.locale = Locale(identifier: "en_US")
            mf.dateFormat = "MMM"
            return "\(mf.string(from: first)) \(cal.component(.day, from: first))–\(cal.component(.day, from: last))"
        }
        return "\(compactDate(first, includeYear: !sameYear))–\(compactDate(last, includeYear: !sameYear))"
    }
}
