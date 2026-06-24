import Foundation

/// Parsed EPUB representation. Holds the underlying `MiniZip.Archive`, the OPF directory,
/// the ordered spine of chapter resources, the manifest by id, and the table of contents.
/// Used by both `EPUBImporter` (metadata) and `ReaderView` (rendering).
struct EPUBPackage {
    var archive: MiniZip.Archive
    var opfPath: String
    var opfDir: String
    var title: String
    var author: String
    var manifest: [String: ManifestItem]
    var spine: [SpineEntry]
    var toc: [TOCEntry]
    var coverHref: String?
    /// Series name embedded in the OPF, if any (e.g. "Mistborn"). Populated by
    /// `parseSeries` from Calibre or EPUB 3 collection metadata.
    var seriesName: String?
    /// Position within the series (e.g. 1.0, or 3.5 for novellas). May be nil
    /// even when `seriesName` is present.
    var seriesIndex: Double?
    /// Where `seriesName` came from: "calibre" or "epub3". Lets later layers
    /// reason about trust and lets a manual edit take precedence.
    var seriesSource: String?
    /// Best-effort ISBN-13/10 pulled from `dc:identifier`. Used to enable
    /// reliable external metadata matching (Tier 2).
    var isbn: String?

    struct ManifestItem {
        var id: String
        var href: String       // resolved path inside the archive
        var mediaType: String
        var properties: String
    }

    struct SpineEntry {
        var id: String
        var href: String       // resolved path inside the archive
        var title: String      // best-effort, from TOC if available
    }

    struct TOCEntry {
        var label: String
        var href: String       // resolved path with optional "#frag"
        var depth: Int
    }

    static func open(data: Data) -> EPUBPackage? {
        guard let archive = MiniZip.readCentralDirectory(data: data) else { return nil }
        guard let containerData = archive.extract(name: "META-INF/container.xml") else { return nil }
        let containerStr = String(data: containerData, encoding: .utf8) ?? ""
        guard let opfPath = extractAttr(containerStr, fromTag: "rootfile", named: "full-path") else { return nil }
        guard let opfData = archive.extract(name: opfPath) else { return nil }
        let opfStr = String(data: opfData, encoding: .utf8) ?? ""
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        let title = innerText(opfStr, tag: "dc:title") ?? innerText(opfStr, tag: "title") ?? "Untitled"
        let author = innerText(opfStr, tag: "dc:creator") ?? innerText(opfStr, tag: "creator") ?? "Unknown Author"

        let series = parseSeries(opfStr)
        let isbn = parseISBN(opfStr)

        let manifest = parseManifest(opfStr, opfDir: opfDir)
        let coverId = findCoverId(opfStr)
        let coverHref: String? = {
            if let id = coverId, let item = manifest[id] { return item.href }
            return manifest.values.first { $0.properties.contains("cover-image") }?.href
        }()

        let spine = parseSpine(opfStr, manifest: manifest)

        // TOC: prefer EPUB3 nav, fall back to NCX
        var toc: [TOCEntry] = []
        if let nav = manifest.values.first(where: { $0.properties.contains("nav") }),
           let navData = archive.extract(name: nav.href),
           let navStr = String(data: navData, encoding: .utf8) {
            toc = parseNavToc(navStr, baseDir: (nav.href as NSString).deletingLastPathComponent)
        } else if let ncx = manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }),
                  let ncxData = archive.extract(name: ncx.href),
                  let ncxStr = String(data: ncxData, encoding: .utf8) {
            toc = parseNcx(ncxStr, baseDir: (ncx.href as NSString).deletingLastPathComponent)
        }

        // Spine titles: try to match by href to TOC labels
        let labeledSpine: [SpineEntry] = spine.map { entry in
            var copy = entry
            if let match = toc.first(where: { $0.href.hasPrefix(entry.href) || entry.href.hasSuffix(stripFragment($0.href)) }) {
                copy.title = match.label
            }
            return copy
        }

        return EPUBPackage(
            archive: archive,
            opfPath: opfPath,
            opfDir: opfDir,
            title: cleanText(title),
            author: cleanText(author),
            manifest: manifest,
            spine: labeledSpine,
            toc: toc,
            coverHref: coverHref,
            seriesName: series.name,
            seriesIndex: series.index,
            seriesSource: series.source,
            isbn: isbn
        )
    }

    func coverData() -> Data? {
        guard let h = coverHref else { return nil }
        return archive.extract(name: h)
    }

    /// HTML of one chapter, preserving EPUB styles while removing document wrappers.
    func chapterBody(at index: Int) -> String? {
        guard spine.indices.contains(index) else { return nil }
        guard let raw = archive.extract(name: spine[index].href) else { return nil }
        guard let s = String(data: raw, encoding: .utf8) else { return nil }
        return rewriteResourceURLs(EPUBPackage.readerFragment(s), chapterDir: (spine[index].href as NSString).deletingLastPathComponent)
    }

    /// Rewrite relative resource paths inside chapter HTML so they resolve to
    /// `epubres://<full-archive-path>` URLs that the WebView's scheme handler
    /// can fetch from the archive.
    private func rewriteResourceURLs(_ html: String, chapterDir: String) -> String {
        var out = html
        let pattern = #"(src|href)=["']([^"'#]+)(#[^"']*)?["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let range = NSRange(out.startIndex..., in: out)
        let matches = regex.matches(in: out, range: range).reversed()
        for m in matches {
            guard m.numberOfRanges >= 3,
                  let attrR = Range(m.range(at: 1), in: out),
                  let pathR = Range(m.range(at: 2), in: out) else { continue }
            let attr = String(out[attrR])
            let path = String(out[pathR])
            let frag: String = {
                if m.numberOfRanges == 4, let r = Range(m.range(at: 3), in: out) { return String(out[r]) }
                return ""
            }()
            // Skip absolute URLs and inline data:
            if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("data:") || path.hasPrefix("mailto:") || path.hasPrefix("epubres:") {
                continue
            }
            let resolved = EPUBPackage.resolvePath(path, against: chapterDir)
            if let mRange = Range(m.range, in: out) {
                out.replaceSubrange(mRange, with: "\(attr)=\"epubres:///\(resolved)\(frag)\"")
            }
        }
        return out
    }

    // MARK: - Path & static helpers

    static func resolvePath(_ path: String, against base: String) -> String {
        if path.hasPrefix("/") { return path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let full = base.isEmpty ? path : "\(base)/\(path)"
        var components = full.split(separator: "/").map(String.init)
        var out: [String] = []
        for c in components {
            if c == ".." { _ = out.popLast() }
            else if c != "." && !c.isEmpty { out.append(c) }
        }
        components = out
        return components.joined(separator: "/")
    }

    private static func stripFragment(_ href: String) -> String {
        if let i = href.firstIndex(of: "#") { return String(href[..<i]) }
        return href
    }

    private static func parseManifest(_ opf: String, opfDir: String) -> [String: ManifestItem] {
        var out: [String: ManifestItem] = [:]
        forEachTag(in: opf, named: "item") { attrs in
            guard let id = attrs["id"], let href = attrs["href"] else { return }
            let resolved = resolvePath(href, against: opfDir)
            out[id] = ManifestItem(
                id: id,
                href: resolved,
                mediaType: attrs["media-type"] ?? "",
                properties: attrs["properties"] ?? ""
            )
        }
        return out
    }

    private static func parseSpine(_ opf: String, manifest: [String: ManifestItem]) -> [SpineEntry] {
        var out: [SpineEntry] = []
        forEachTag(in: opf, named: "itemref") { attrs in
            guard let idref = attrs["idref"], let item = manifest[idref] else { return }
            // Only HTML/XHTML content in the spine
            let mt = item.mediaType.lowercased()
            if !(mt.contains("xhtml") || mt == "text/html") && !mt.isEmpty {
                // Skip non-HTML spine entries (rare but possible)
                return
            }
            out.append(SpineEntry(id: idref, href: item.href, title: ""))
        }
        return out
    }

    private static func findCoverId(_ opf: String) -> String? {
        var coverId: String?
        forEachTag(in: opf, named: "meta") { attrs in
            if attrs["name"] == "cover", let c = attrs["content"] {
                coverId = c
            }
        }
        return coverId
    }

    // MARK: - Series & identifier metadata

    /// Extract a series name + position from the OPF. Prefers Calibre's
    /// `calibre:series` / `calibre:series_index` meta tags (ubiquitous in
    /// sideloaded EPUBs), falling back to the EPUB 3 `belongs-to-collection`
    /// vocabulary. Returns a nil name when neither is present.
    private static func parseSeries(_ opf: String) -> (name: String?, index: Double?, source: String?) {
        // Calibre legacy <meta name="calibre:series" content="..."/> pair.
        var calibreName: String?
        var calibreIndexRaw: String?
        forEachTag(in: opf, named: "meta") { attrs in
            switch attrs["name"] {
            case "calibre:series": calibreName = attrs["content"]
            case "calibre:series_index": calibreIndexRaw = attrs["content"]
            default: break
            }
        }
        if let raw = calibreName {
            let name = cleanText(raw)
            if !name.isEmpty {
                return (name, calibreIndexRaw.flatMap { Double($0) }, "calibre")
            }
        }

        // EPUB 3 collection refinement.
        if let epub3 = parseEPUB3Collection(opf) {
            return (epub3.name, epub3.index, "epub3")
        }
        return (nil, nil, nil)
    }

    /// Parse `<meta property="belongs-to-collection">Name</meta>` plus its
    /// `collection-type` / `group-position` refinements. Prefers a collection
    /// explicitly typed as a series; ignores ones typed as a "set" (box set).
    private static func parseEPUB3Collection(_ opf: String) -> (name: String, index: Double?)? {
        let pattern = #"<meta\b([^>]*\bproperty\s*=\s*["']belongs-to-collection["'][^>]*)>([\s\S]*?)</meta>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(opf.startIndex..., in: opf)

        struct Candidate { var name: String; var typedSeries: Bool; var isSeries: Bool; var index: Double? }
        var candidates: [Candidate] = []

        regex.enumerateMatches(in: opf, range: range) { m, _, _ in
            guard let m,
                  let attrR = Range(m.range(at: 1), in: opf),
                  let innerR = Range(m.range(at: 2), in: opf) else { return }
            let attrs = parseAttributes("<meta \(String(opf[attrR]))>")
            let name = cleanText(String(opf[innerR]))
            guard !name.isEmpty else { return }

            var isSeries = true     // untyped collections are treated as series
            var typedSeries = false
            var index: Double?
            if let id = attrs["id"] {
                if let type = refinesValue(opf, refines: id, property: "collection-type") {
                    isSeries = type.lowercased() == "series"
                    typedSeries = isSeries
                }
                if let position = refinesValue(opf, refines: id, property: "group-position") {
                    index = Double(position)
                }
            }
            candidates.append(Candidate(name: name, typedSeries: typedSeries, isSeries: isSeries, index: index))
        }

        if let best = candidates.first(where: { $0.typedSeries }) ?? candidates.first(where: { $0.isSeries }) {
            return (best.name, best.index)
        }
        return nil
    }

    /// Inner text of the first `<meta refines="#id" property="...">` element
    /// (attribute order varies, so both orderings are tried).
    private static func refinesValue(_ opf: String, refines id: String, property: String) -> String? {
        let escId = NSRegularExpression.escapedPattern(for: id)
        let escProp = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta\\b[^>]*\\brefines\\s*=\\s*[\"']#\(escId)[\"'][^>]*\\bproperty\\s*=\\s*[\"']\(escProp)[\"'][^>]*>([\\s\\S]*?)</meta>",
            "<meta\\b[^>]*\\bproperty\\s*=\\s*[\"']\(escProp)[\"'][^>]*\\brefines\\s*=\\s*[\"']#\(escId)[\"'][^>]*>([\\s\\S]*?)</meta>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(opf.startIndex..., in: opf)
            if let m = regex.firstMatch(in: opf, range: range), m.numberOfRanges == 2,
               let r = Range(m.range(at: 1), in: opf) {
                return cleanText(String(opf[r]))
            }
        }
        return nil
    }

    /// Best-effort ISBN-13/10 from the OPF's `dc:identifier` records. Trusts a
    /// value when its scheme says ISBN or it carries an isbn URN; otherwise only
    /// accepts a bare 13-digit string (to avoid mistaking a UUID/UUID-like id).
    private static func parseISBN(_ opf: String) -> String? {
        var tagged: [String] = []
        var untagged: [String] = []
        for tag in ["dc:identifier", "identifier"] {
            let pattern = "<\(tag)\\b([^>]*)>([\\s\\S]*?)</\(tag)>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(opf.startIndex..., in: opf)
            regex.enumerateMatches(in: opf, range: range) { m, _, _ in
                guard let m,
                      let attrR = Range(m.range(at: 1), in: opf),
                      let valR = Range(m.range(at: 2), in: opf) else { return }
                let attrs = parseAttributes("<x \(String(opf[attrR]))>")
                let scheme = (attrs["opf:scheme"] ?? attrs["scheme"] ?? "").lowercased()
                let raw = cleanText(String(opf[valR]))
                guard let normalized = normalizedISBN(raw) else { return }
                if scheme == "isbn" || raw.lowercased().contains("isbn") {
                    tagged.append(normalized)
                } else if normalized.count == 13 {
                    untagged.append(normalized)
                }
            }
        }
        // Prefer an explicitly ISBN-tagged value; fall back to a bare ISBN-13.
        return tagged.first ?? untagged.first
    }

    /// Strip URN/`ISBN:` prefixes and separators; return a clean 13- or 10-char
    /// ISBN (10 may end in "X"), or nil if it doesn't look like one.
    private static func normalizedISBN(_ s: String) -> String? {
        let stripped = s.lowercased()
            .replacingOccurrences(of: "urn:isbn:", with: "")
            .replacingOccurrences(of: "isbn:", with: "")
        let chars = stripped.uppercased().filter { $0.isNumber || $0 == "X" }
        if chars.count == 13, chars.allSatisfy({ $0.isNumber }) { return chars }
        if chars.count == 10 { return chars }
        return nil
    }

    private static func parseNavToc(_ html: String, baseDir: String) -> [TOCEntry] {
        // Find <nav epub:type="toc">...<ol>...</ol>
        var entries: [TOCEntry] = []
        let navStart = html.range(of: #"<nav[^>]+epub:type=["'][^"']*toc[^"']*["'][^>]*>"#, options: .regularExpression)
            ?? html.range(of: #"<nav[^>]*>"#, options: .regularExpression)
        guard let s = navStart else { return [] }
        let after = html[s.upperBound...]
        guard let end = after.range(of: "</nav>") else { return [] }
        let navInner = String(after[..<end.lowerBound])

        // Walk <a href="..."> elements, treating nested <ol> as deeper levels
        let depthByPos = computeOlDepths(in: navInner)
        let aPattern = #"<a[^>]+href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#
        let regex = try? NSRegularExpression(pattern: aPattern)
        let range = NSRange(navInner.startIndex..., in: navInner)
        regex?.enumerateMatches(in: navInner, range: range) { m, _, _ in
            guard let m, m.numberOfRanges == 3,
                  let hR = Range(m.range(at: 1), in: navInner),
                  let lR = Range(m.range(at: 2), in: navInner)
            else { return }
            let label = stripTags(String(navInner[lR])).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawHref = String(navInner[hR])
            let resolved = resolvePath(rawHref, against: baseDir)
            let position = navInner.distance(from: navInner.startIndex, to: hR.lowerBound)
            entries.append(TOCEntry(label: label, href: resolved, depth: depthByPos[position] ?? 0))
        }
        return entries
    }

    private static func computeOlDepths(in s: String) -> [Int: Int] {
        // Map of character offset → depth based on <ol> nesting up to that point.
        var depthAt: [Int: Int] = [:]
        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("<ol") { depth += 1; i = s.index(i, offsetBy: 3) }
            else if s[i...].hasPrefix("</ol>") { depth = max(0, depth - 1); i = s.index(i, offsetBy: 5) }
            else if s[i...].hasPrefix("<a") {
                let pos = s.distance(from: s.startIndex, to: i)
                let after = s.index(i, offsetBy: 2)
                if let hrefRange = s[after...].range(of: #"href=["'][^"']+["']"#, options: .regularExpression) {
                    let absPos = s.distance(from: s.startIndex, to: hrefRange.lowerBound)
                    depthAt[absPos + 6] = max(0, depth - 1)
                    _ = pos
                }
                i = s.index(after: i)
            } else {
                i = s.index(after: i)
            }
        }
        return depthAt
    }

    private static func parseNcx(_ ncx: String, baseDir: String) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        // Each <navPoint> contains <navLabel><text>...</text></navLabel><content src="..."/>
        let pattern = #"<navPoint[^>]*>([\s\S]*?)</navPoint>"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(ncx.startIndex..., in: ncx)
        regex?.enumerateMatches(in: ncx, range: range) { m, _, _ in
            guard let m, m.numberOfRanges == 2, let r = Range(m.range(at: 1), in: ncx) else { return }
            let inner = String(ncx[r])
            let label = innerText(inner, tag: "text") ?? ""
            if let srcAttr = extractAttr(inner, fromTag: "content", named: "src"), !label.isEmpty {
                entries.append(TOCEntry(
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                    href: resolvePath(srcAttr, against: baseDir),
                    depth: 0
                ))
            }
        }
        return entries
    }

    private static func forEachTag(in s: String, named tag: String, body: ([String: String]) -> Void) {
        // Match both self-closing <tag .../> and <tag ...></tag>
        let pattern = "<\(tag)\\b[^>]*/?>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
        let range = NSRange(s.startIndex..., in: s)
        regex.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, let r = Range(m.range, in: s) else { return }
            let chunk = String(s[r])
            body(parseAttributes(chunk))
        }
    }

    private static func parseAttributes(_ tag: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let pattern = #"([A-Za-z_:][\w:.-]*)\s*=\s*["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attrs }
        let range = NSRange(tag.startIndex..., in: tag)
        regex.enumerateMatches(in: tag, range: range) { m, _, _ in
            guard let m, m.numberOfRanges == 3,
                  let kR = Range(m.range(at: 1), in: tag),
                  let vR = Range(m.range(at: 2), in: tag)
            else { return }
            attrs[String(tag[kR]).lowercased()] = String(tag[vR])
        }
        return attrs
    }

    private static func extractAttr(_ s: String, fromTag tag: String, named attr: String) -> String? {
        let pattern = "<\(tag)\\b[^>]*\\b\(attr)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func innerText(_ s: String, tag: String) -> String? {
        let pattern = "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range), m.numberOfRanges == 2,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return stripTags(String(s[r])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // Decode common HTML entities
        out = out.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&ldquo;", with: "“")
            .replacingOccurrences(of: "&rdquo;", with: "”")
            .replacingOccurrences(of: "&lsquo;", with: "‘")
            .replacingOccurrences(of: "&rsquo;", with: "’")
        // Decode any leftover &#NN; or &#xNN; numeric entities.
        out = decodeNumericEntities(out)
        // Collapse whitespace runs (incl. newlines/tabs that EPUB nav often inlines).
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";") {
                let entity = s[s.index(after: i)..<semi]
                if entity.hasPrefix("#") {
                    let body = entity.dropFirst()
                    let value: Int? = body.hasPrefix("x") || body.hasPrefix("X")
                        ? Int(body.dropFirst(), radix: 16)
                        : Int(body)
                    if let v = value, let scalar = Unicode.Scalar(v) {
                        result.append(Character(scalar))
                        i = s.index(after: semi)
                        continue
                    }
                }
            }
            result.append(s[i])
            i = s.index(after: i)
        }
        return result
    }

    private static func cleanText(_ s: String) -> String {
        stripTags(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readerFragment(_ s: String) -> String {
        let withoutScripts = s.replacingOccurrences(
            of: #"<script[\s\S]*?</script>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        let styles = preservedStyleTags(from: withoutScripts)
        let body: String
        if let bodyOpen = withoutScripts.range(of: #"<body[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
           let bodyClose = withoutScripts.range(of: "</body>", options: [.backwards, .caseInsensitive]) {
            body = String(withoutScripts[bodyOpen.upperBound..<bodyClose.lowerBound])
        } else {
            body = withoutScripts
        }
        return styles + body
    }

    private static func preservedStyleTags(from html: String) -> String {
        var tags: [String] = []
        let patterns = [
            #"<link\b(?=[^>]*\brel\s*=\s*[\"'][^\"']*stylesheet[^\"']*[\"'])[^>]*>"#,
            #"<style\b[^>]*>[\s\S]*?</style>"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, let r = Range(match.range, in: html) else { return }
                tags.append(String(html[r]))
            }
        }
        return tags.isEmpty ? "" : tags.joined(separator: "\n") + "\n"
    }
}
