import Foundation
import CryptoKit
import SwiftUI
import UIKit

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var books: [Book] = []
    @Published var sessions: [ReadingSession] = []
    @Published var progress: [String: ReadingProgress] = [:]
    @Published var bookmarks: [String: [Bookmark]] = [:]
    @Published var highlights: [String: [Highlight]] = [:]
    @Published var goal = ReadingGoal()
    @Published var readerSettings = ReaderSettings()
    @Published var watchedFolderBookmark: Data?
    @Published var watchedFolderName: String?
    @Published var backupFolderBookmark: Data?
    @Published var backupFolderName: String?
    @Published var didHydrate = false

    static let appGroupId = "group.com.bdeavilla.bookmark"
    static let usesAppGroupStorage = false
    private static var cachedStoreDirectory: URL?

    private var saveTask: Task<Void, Never>?
    private var liveReadingSession: LiveReadingSession?

    struct WatchedFolder: Codable, Hashable {
        var name: String
        var bookmarkData: Data
    }

    struct BackupFolder: Codable, Hashable {
        var name: String
        var bookmarkData: Data
    }

    private struct LiveReadingSession {
        var bookId: String
        var startedAt: Date
        var elapsedSeconds: Int
        var progressPct: Double
        var cfi: String?

        var visibleProgressPct: Int {
            Int((max(0, min(1, progressPct)) * 100).rounded())
        }

        var visibleElapsedMinutes: Int {
            max(0, elapsedSeconds) / 60
        }
    }

    func hydrate() async {
        if didHydrate { return }
        let dir = Self.storeDirectory()
        books          = (try? Self.load([Book].self,                 from: dir.appendingPathComponent("books.json"))) ?? []
        sessions       = (try? Self.load([ReadingSession].self,       from: dir.appendingPathComponent("sessions.json"))) ?? []
        progress       = (try? Self.load([String: ReadingProgress].self, from: dir.appendingPathComponent("progress.json"))) ?? [:]
        bookmarks      = (try? Self.load([String: [Bookmark]].self,   from: dir.appendingPathComponent("bookmarks.json"))) ?? [:]
        highlights     = (try? Self.load([String: [Highlight]].self,  from: dir.appendingPathComponent("highlights.json"))) ?? [:]
        goal           = (try? Self.load(ReadingGoal.self,            from: dir.appendingPathComponent("goal.json"))) ?? ReadingGoal()
        readerSettings = (try? Self.load(ReaderSettings.self,         from: dir.appendingPathComponent("reader.json"))) ?? ReaderSettings()
        let watchedFolder = (try? Self.load(WatchedFolder.self, from: dir.appendingPathComponent("watched-folder.json")))
        watchedFolderBookmark = watchedFolder?.bookmarkData
        watchedFolderName = watchedFolder?.name
        let backupFolder = (try? Self.load(BackupFolder.self, from: dir.appendingPathComponent("backup-folder.json")))
        backupFolderBookmark = backupFolder?.bookmarkData
        backupFolderName = backupFolder?.name

        reconcileReadableBookFiles()
        backfillContentFingerprints()
        normalizeOrder()
        // Mark books finished by progress
        for i in books.indices {
            let p = progress[books[i].id]?.pct ?? 0
            if !books[i].finished, p >= 0.99 {
                books[i].finished = true
                if books[i].finishedAt == nil {
                    books[i].finishedAt = progress[books[i].id]?.lastRead ?? Date()
                }
            }
        }
        didHydrate = true
        scheduleSave()
    }

    func scheduleSave() {
        saveTask?.cancel()
        let snapshot = snapshotForSave()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            await self.writeSnapshot(snapshot)
        }
        // Mirror the webapp's `scheduleNativeBackup`: every persist also rolls
        // the user-visible Files-app copy on its own debounce timer.
        AutoBackup.scheduleAutomatic(store: self)
        Task { await ReadingReminderScheduler.reschedule(for: self) }
    }

    func refreshSharedWidgetSnapshot() async {
        await writeSharedSnapshot()
    }

    func beginLiveReadingSession(bookId: String, progressPct: Double, cfi: String? = nil) {
        liveReadingSession = LiveReadingSession(
            bookId: bookId,
            startedAt: Date(),
            elapsedSeconds: 0,
            progressPct: progressPct,
            cfi: cfi
        )
    }

    func updateLiveReadingSession(bookId: String, elapsedSeconds: Int, progressPct: Double, cfi: String? = nil) {
        if liveReadingSession?.bookId != bookId {
            beginLiveReadingSession(bookId: bookId, progressPct: progressPct, cfi: cfi)
        }

        guard var live = liveReadingSession else { return }
        live.elapsedSeconds = max(0, elapsedSeconds)
        live.progressPct = max(0, min(1, progressPct))
        if let cfi { live.cfi = cfi }
        liveReadingSession = live
    }

    func endLiveReadingSession(bookId: String) {
        guard liveReadingSession?.bookId == bookId else { return }
        liveReadingSession = nil
    }

    private struct SaveSnapshot {
        var books: [Book]
        var sessions: [ReadingSession]
        var progress: [String: ReadingProgress]
        var bookmarks: [String: [Bookmark]]
        var highlights: [String: [Highlight]]
        var goal: ReadingGoal
        var readerSettings: ReaderSettings
        var watchedFolder: WatchedFolder?
        var backupFolder: BackupFolder?
    }

    private func snapshotForSave() -> SaveSnapshot {
        SaveSnapshot(
            books: books, sessions: sessions, progress: progress,
            bookmarks: bookmarks, highlights: highlights, goal: goal, readerSettings: readerSettings,
            watchedFolder: watchedFolderBookmark.map {
                WatchedFolder(name: watchedFolderName ?? "Watched Folder", bookmarkData: $0)
            },
            backupFolder: backupFolderBookmark.map {
                BackupFolder(name: backupFolderName ?? "Backup Folder", bookmarkData: $0)
            }
        )
    }

    private func writeSnapshot(_ s: SaveSnapshot) async {
        let dir = Self.storeDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Self.save(s.books,          to: dir.appendingPathComponent("books.json"))
        try? Self.save(s.sessions,       to: dir.appendingPathComponent("sessions.json"))
        try? Self.save(s.progress,       to: dir.appendingPathComponent("progress.json"))
        try? Self.save(s.bookmarks,      to: dir.appendingPathComponent("bookmarks.json"))
        try? Self.save(s.highlights,     to: dir.appendingPathComponent("highlights.json"))
        try? Self.save(s.goal,           to: dir.appendingPathComponent("goal.json"))
        try? Self.save(s.readerSettings, to: dir.appendingPathComponent("reader.json"))
        let watchedURL = dir.appendingPathComponent("watched-folder.json")
        if let watchedFolder = s.watchedFolder {
            try? Self.save(watchedFolder, to: watchedURL)
        } else {
            try? FileManager.default.removeItem(at: watchedURL)
        }
        let backupURL = dir.appendingPathComponent("backup-folder.json")
        if let backupFolder = s.backupFolder {
            try? Self.save(backupFolder, to: backupURL)
        } else {
            try? FileManager.default.removeItem(at: backupURL)
        }
    }

    private func writeSharedSnapshot() async {
        let dir = Self.sharedSnapshotDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let live = liveReadingSession
        let liveBook = live.flatMap { active in books.first { $0.id == active.bookId } }
        let liveSecondsToday = live.map { active in
            Calendar.current.isDate(active.startedAt, inSameDayAs: Date()) ? active.elapsedSeconds : 0
        } ?? 0

        // Continue Reading + its accumulated reading time and cover.
        let cont = liveBook ?? continueBook()
        let contSecs: Int? = cont.map { b in
            let savedSeconds = sessionsForBook(b).reduce(0) { $0 + $1.secs }
            let activeSeconds = live?.bookId == b.id ? max(0, live?.elapsedSeconds ?? 0) : 0
            return savedSeconds + activeSeconds
        }
        let contPct: Int? = cont.map { b in
            if live?.bookId == b.id, let live {
                return live.visibleProgressPct
            }
            return progress[b.id].map { Int(($0.pct * 100).rounded()) }
        } ?? nil

        // Write cover to a fixed file in the App Group so widgets can read it
        // without inflating the JSON snapshot via base64.
        var coverFile: String?
        var smallCoverFile: String?
        let coverURL = dir.appendingPathComponent("widget-cover.png")
        let smallCoverURL = dir.appendingPathComponent("widget-cover-small.png")
        if let c = cont, let data = c.coverData {
            if let widgetCoverData = Self.widgetCoverData(from: data) {
                try? widgetCoverData.write(to: coverURL, options: .atomic)
                coverFile = coverURL.lastPathComponent
            } else {
                try? FileManager.default.removeItem(at: coverURL)
            }

            if let smallWidgetCoverData = Self.widgetCoverData(from: data, maxPixelWidth: 126, maxPixelHeight: 168) {
                try? smallWidgetCoverData.write(to: smallCoverURL, options: .atomic)
                smallCoverFile = smallCoverURL.lastPathComponent
            } else {
                try? FileManager.default.removeItem(at: smallCoverURL)
            }
        } else {
            try? FileManager.default.removeItem(at: coverURL)
            try? FileManager.default.removeItem(at: smallCoverURL)
        }

        // Stats grid
        let totalSecs = sessions.reduce(0) { $0 + $1.secs } + liveSecondsToday
        let finished = books.filter(\.finished).count
        let avgSession = sessions.isEmpty ? 0 : sessions.reduce(0) { $0 + $1.secs } / sessions.count

        let cal = Calendar.current
        var map = secondsByDay()
        if liveSecondsToday > 0 {
            map[Fmt.dayKey(Date()), default: 0] += liveSecondsToday
        }
        var weekSecs = 0
        for i in 0..<7 {
            if let d = cal.date(byAdding: .day, value: -i, to: Date()) {
                weekSecs += map[Fmt.dayKey(d)] ?? 0
            }
        }

        let totalPages = sessions.reduce(0) { $0 + ($1.pages ?? 0) }
        let pageSessions = sessions.filter { ($0.pages ?? 0) > 0 }
        let avgPages = pageSessions.isEmpty ? 0 : totalPages / pageSessions.count

        var pageByDay: [String: Int] = [:]
        for s in sessions { pageByDay[Fmt.dayKey(s.start), default: 0] += s.pages ?? 0 }
        var weekPages = 0
        for i in 0..<7 {
            if let d = cal.date(byAdding: .day, value: -i, to: Date()) {
                weekPages += pageByDay[Fmt.dayKey(d)] ?? 0
            }
        }
        let pacePool = pageSessions
        let paceTotalMins = max(1, pacePool.reduce(0) { $0 + $1.secs }) / 60
        let avgPace = pacePool.isEmpty ? 0.0 : Double(pacePool.reduce(0) { $0 + ($1.pages ?? 0) }) / Double(paceTotalMins)

        // 7-day series, oldest -> newest
        var labels: [String] = []
        var dailySecs: [Int] = []
        var dailyPace: [Double] = []
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEEEE"
        var paceByDay: [String: (pages: Int, secs: Int)] = [:]
        for s in sessions where (s.pages ?? 0) > 0 && s.secs > 0 {
            let k = Fmt.dayKey(s.start)
            var v = paceByDay[k] ?? (0, 0)
            v.pages += s.pages ?? 0
            v.secs += s.secs
            paceByDay[k] = v
        }
        for i in (0..<7).reversed() {
            guard let d = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
            labels.append(dayFmt.string(from: d))
            dailySecs.append(map[Fmt.dayKey(d)] ?? 0)
            let v = paceByDay[Fmt.dayKey(d)] ?? (0, 0)
            let mins = max(1, v.secs / 60)
            dailyPace.append(v.pages == 0 ? 0 : Double(v.pages) / Double(mins))
        }

        let snap = SharedSnapshot(
            todayMinutes: Fmt.minutes(map[Fmt.dayKey(Date())] ?? 0),
            goalMinutes: max(1, goal.minutes),
            currentStreak: currentStreak(),
            bestStreak: bestStreak(),
            continueTitle: cont?.title,
            continueAuthor: cont?.author,
            continueProgressPct: contPct,
            continueBookSeconds: contSecs,
            continueCoverFile: coverFile,
            continueSmallCoverFile: smallCoverFile,
            totalBooks: books.count,
            finishedBooks: finished,
            totalSeconds: totalSecs,
            avgSessionSeconds: avgSession,
            weekSeconds: weekSecs,
            totalPages: totalPages,
            avgPages: avgPages,
            weekPages: weekPages,
            avgPace: avgPace,
            last7DayLabels: labels,
            last7DaySeconds: dailySecs,
            last7DayPace: dailyPace,
            updatedAt: Date()
        )

        guard let url = Self.sharedSnapshotURL(),
              let snapshotData = try? Self.encodedData(snap) else { return }

        do {
            try snapshotData.write(to: url, options: .atomic)
            Self.writeSharedSnapshotDefaults(data: snapshotData)
            WidgetRefreshBroker.reloadContinueReading()
        } catch {
            return
        }
    }

    // MARK: - Storage paths

    static func storeDirectory() -> URL {
        if let cachedStoreDirectory {
            return cachedStoreDirectory
        }

        let resolved: URL
        if usesAppGroupStorage,
           let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            resolved = group.appendingPathComponent("Library", isDirectory: true)
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            resolved = docs.appendingPathComponent("BookMarkStore", isDirectory: true)
        }
        cachedStoreDirectory = resolved
        return resolved
    }

    static func epubsDirectory() -> URL {
        let url = storeDirectory().appendingPathComponent("Epubs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sharedSnapshotURL() -> URL? {
        let dir = sharedSnapshotDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    static func sharedSnapshotDirectory() -> URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            return group.appendingPathComponent("Library", isDirectory: true)
        }
        return storeDirectory()
    }

    private static func widgetCoverData(
        from data: Data,
        maxPixelWidth: CGFloat = 400,
        maxPixelHeight: CGFloat = 600
    ) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        let scale = min(1, maxPixelWidth / image.size.width, maxPixelHeight / image.size.height)
        let outputSize = CGSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )

        let renderer = UIGraphicsImageRenderer(size: outputSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: outputSize))
        }
        return resized.pngData()
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try encodedData(value).write(to: url, options: .atomic)
    }

    private static func encodedData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func writeSharedSnapshotDefaults(data: Data) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        defaults.set(data, forKey: "widget-snapshot-data")
        defaults.set(Date(), forKey: "widget-snapshot-defaults-updated-at")
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Library helpers

    func normalizeOrder() {
        books.sort { ($0.order, $0.added) < ($1.order, $1.added) }
        for i in books.indices { books[i].order = i }
    }

    func moveBooks(from source: IndexSet, to destination: Int) {
        var sorted = books.sorted { $0.order < $1.order }
        sorted.move(fromOffsets: source, toOffset: destination)
        for i in sorted.indices { sorted[i].order = i }
        books = sorted
        scheduleSave()
    }

    func moveBookIDs(_ ids: [String], before targetID: String) {
        let movingIDs = Set(ids)
        guard !movingIDs.isEmpty, !movingIDs.contains(targetID) else { return }

        var sorted = books.sorted { $0.order < $1.order }
        let moving = sorted.filter { movingIDs.contains($0.id) }
        guard !moving.isEmpty else { return }

        sorted.removeAll { movingIDs.contains($0.id) }
        let destination = sorted.firstIndex { $0.id == targetID } ?? sorted.count
        sorted.insert(contentsOf: moving, at: destination)
        for i in sorted.indices { sorted[i].order = i }
        books = sorted
        scheduleSave()
    }

    func moveBookIDsToEnd(_ ids: [String]) {
        let movingIDs = Set(ids)
        guard !movingIDs.isEmpty else { return }

        var sorted = books.sorted { $0.order < $1.order }
        let moving = sorted.filter { movingIDs.contains($0.id) }
        guard !moving.isEmpty else { return }

        sorted.removeAll { movingIDs.contains($0.id) }
        sorted.append(contentsOf: moving)
        for i in sorted.indices { sorted[i].order = i }
        books = sorted
        scheduleSave()
    }

    func setWatchedFolder(_ url: URL) throws {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        watchedFolderBookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        watchedFolderName = url.lastPathComponent.isEmpty ? "Watched Folder" : url.lastPathComponent
        scheduleSave()
    }

    func clearWatchedFolder() {
        watchedFolderBookmark = nil
        watchedFolderName = nil
        scheduleSave()
    }

    func resolveWatchedFolder() -> URL? {
        guard let watchedFolderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: watchedFolderBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            clearWatchedFolder()
            return nil
        }
        if stale {
            try? setWatchedFolder(url)
        }
        return url
    }

    func setBackupFolder(_ url: URL) throws {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        backupFolderBookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        backupFolderName = url.lastPathComponent.isEmpty ? "Backup Folder" : url.lastPathComponent
        scheduleSave()
    }

    func clearBackupFolder() {
        backupFolderBookmark = nil
        backupFolderName = nil
        scheduleSave()
    }

    func resolveBackupFolder() -> URL? {
        guard let backupFolderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: backupFolderBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            clearBackupFolder()
            return nil
        }
        if stale {
            try? setBackupFolder(url)
        }
        return url
    }

    func sortedBooks() -> [Book] {
        books.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            let lastA = progress[$0.id]?.lastRead ?? .distantPast
            let lastB = progress[$1.id]?.lastRead ?? .distantPast
            return lastA > lastB
        }
    }

    func continueBook() -> Book? {
        books
            .filter { !$0.finished && (((progress[$0.id]?.pct ?? 0) > 0) || progress[$0.id]?.lastRead != nil) }
            .sorted { (progress[$0.id]?.lastRead ?? .distantPast) > (progress[$1.id]?.lastRead ?? .distantPast) }
            .first
    }

    @discardableResult
    func addBook(_ b: Book) -> Bool {
        var book = b
        if let fileName = book.fileName,
           attachEPUBFile(
            title: book.title,
            author: book.author,
            coverData: book.coverData,
            fileName: fileName,
            contentFingerprint: book.contentFingerprint
           ) {
            return false
        }
        book.order = books.count
        books.append(book)
        reconcileReadableBookFiles()
        normalizeOrder()
        scheduleSave()
        return true
    }

    func attachEPUBFile(title: String, author: String, coverData: Data?, fileName: String, contentFingerprint: String?) -> Bool {
        guard let i = books.firstIndex(where: {
            !epubFileExists(for: $0) && normalize($0.title) == normalize(title) && authorsMatch($0.author, author)
        }) else {
            return false
        }

        books[i].fileName = fileName
        books[i].contentFingerprint = contentFingerprint
        if books[i].coverData == nil {
            books[i].coverData = coverData
        }
        if isUnknownAuthor(books[i].author), !isUnknownAuthor(author) {
            books[i].author = author
        }
        scheduleSave()
        return true
    }

    func containsBook(contentFingerprint: String) -> Bool {
        books.contains { $0.contentFingerprint == contentFingerprint }
    }

    private func reconcileReadableBookFiles() {
        var idsToRemove = Set<String>()

        for i in books.indices where books[i].fileName == nil {
            guard let matchIndex = books.indices.first(where: {
                $0 != i && books[$0].fileName != nil && normalize(books[$0].title) == normalize(books[i].title) && authorsMatch(books[$0].author, books[i].author)
            }) else {
                continue
            }

            let duplicate = books[matchIndex]
            books[i].fileName = duplicate.fileName
            books[i].contentFingerprint = duplicate.contentFingerprint
            if books[i].coverData == nil {
                books[i].coverData = duplicate.coverData
            }
            if progress[books[i].id] == nil, let duplicateProgress = progress[duplicate.id] {
                progress[books[i].id] = duplicateProgress
            }
            idsToRemove.insert(duplicate.id)
        }

        guard !idsToRemove.isEmpty else { return }
        books.removeAll { idsToRemove.contains($0.id) }
        for id in idsToRemove {
            progress.removeValue(forKey: id)
            bookmarks.removeValue(forKey: id)
            highlights.removeValue(forKey: id)
        }
    }

    private func backfillContentFingerprints() {
        var changed = false
        for i in books.indices where books[i].contentFingerprint == nil {
            guard let fileName = books[i].fileName else { continue }
            let url = Self.epubsDirectory().appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url) else { continue }
            books[i].contentFingerprint = Self.contentFingerprint(for: data)
            changed = true
        }
        if changed {
            scheduleSave()
        }
    }

    private func authorsMatch(_ a: String, _ b: String) -> Bool {
        isUnknownAuthor(a) || isUnknownAuthor(b) || normalize(a) == normalize(b)
    }

    private func isUnknownAuthor(_ author: String) -> Bool {
        normalize(author).isEmpty || normalize(author) == "unknown author"
    }

    func removeBook(id: String) {
        books.removeAll { $0.id == id }
        progress.removeValue(forKey: id)
        bookmarks.removeValue(forKey: id)
        highlights.removeValue(forKey: id)
        normalizeOrder()
        scheduleSave()
    }

    /// Returns true if the book's EPUB binary is still readable. Used by the
    /// library to decide whether to open the reader vs. show the relink sheet.
    func epubFileExists(for book: Book) -> Bool {
        guard let fileName = book.fileName else { return false }
        let url = Self.epubsDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Replace the EPUB binding for an existing book — preserves sessions,
    /// progress, and bookmarks via the unchanged book id. If parsing pulled a
    /// fresh title/author/cover, those overwrite the old values (matching the
    /// webapp's `findExistingBookForFile` merge behavior on relink).
    func relink(bookId: String, fileName: String, title: String?, author: String?, coverData: Data?) {
        guard let i = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[i].fileName = fileName
        let url = Self.epubsDirectory().appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url) {
            books[i].contentFingerprint = Self.contentFingerprint(for: data)
        }
        if let t = title, !t.isEmpty, t != "Untitled" { books[i].title = t }
        if let a = author, !a.isEmpty, !isUnknownAuthor(a) { books[i].author = a }
        if let c = coverData { books[i].coverData = c }
        scheduleSave()
    }

    func markFinished(id: String, on date: Date = Date()) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].finished = true
        books[i].finishedAt = date
        scheduleSave()
    }

    func markUnfinished(id: String) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].finished = false
        books[i].finishedAt = nil
        scheduleSave()
    }

    func updateProgress(bookId: String, pct: Double, cfi: String? = nil) {
        var p = progress[bookId] ?? ReadingProgress()
        p.pct = max(0, min(1, pct))
        if let cfi { p.cfi = cfi }
        p.lastRead = Date()
        progress[bookId] = p
        scheduleSave()
    }

    // MARK: - Sessions

    func addSession(_ s: ReadingSession) {
        sessions.append(s)
        scheduleSave()
    }

    func updateSession(_ s: ReadingSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[i] = s
            scheduleSave()
        }
    }

    func deleteSession(id: String) {
        sessions.removeAll { $0.id == id }
        scheduleSave()
    }

    func sessionsForBook(_ b: Book) -> [ReadingSession] {
        let bookTitleNorm = normalize(b.title)
        return sessions.filter {
            if let bid = $0.bookId, bid == b.id { return true }
            return !bookTitleNorm.isEmpty && normalize($0.bookTitle) == bookTitleNorm
        }
    }

    private func normalize(_ s: String) -> String {
        let lower = s.lowercased().replacingOccurrences(of: "&", with: " and ")
        let allowed = lower.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(allowed).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Streak engine

    func secondsByDay() -> [String: Int] {
        var map: [String: Int] = [:]
        for s in sessions {
            let k = Fmt.dayKey(s.start)
            map[k, default: 0] += s.secs
        }
        return map
    }

    func todaySeconds() -> Int { secondsByDay()[Fmt.dayKey(Date())] ?? 0 }

    func currentStreak() -> Int {
        let map = secondsByDay()
        let need = max(1, goal.minutes) * 60
        let met: (Date) -> Bool = { (map[Fmt.dayKey($0)] ?? 0) >= need }
        var cursor = Date()
        if !met(cursor) {
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var n = 0
        while met(cursor) {
            n += 1
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return n
    }

    func bestStreak() -> Int {
        let map = secondsByDay()
        let need = max(1, goal.minutes) * 60
        let keys = map.filter { $0.value >= need }.keys.sorted()
        var best = 0, run = 0
        var prev: Date? = nil
        for k in keys {
            let comps = k.split(separator: "-").compactMap { Int($0) }
            guard comps.count == 3,
                  let date = Calendar.current.date(from: DateComponents(year: comps[0], month: comps[1], day: comps[2]))
            else { continue }
            if let p = prev,
               let dayDelta = Calendar.current.dateComponents([.day], from: p, to: date).day,
               dayDelta == 1 {
                run += 1
            } else {
                run = 1
            }
            prev = date
            if run > best { best = run }
        }
        return max(best, currentStreak())
    }

    // MARK: - Backup

    struct Backup: Codable {
        var version: String
        var exportedAt: Date
        var books: [Book]
        var sessions: [ReadingSession]
        var progress: [String: ReadingProgress]
        var bookmarks: [String: [Bookmark]]
        var highlights: [String: [Highlight]]? = nil
        var goal: ReadingGoal
        var readerSettings: ReaderSettings
    }

    func makeBackup() -> Backup {
        Backup(
            version: "native-1",
            exportedAt: Date(),
            books: books,
            sessions: sessions,
            progress: progress,
            bookmarks: bookmarks,
            highlights: highlights,
            goal: goal,
            readerSettings: readerSettings
        )
    }

    func restoreBackup(_ b: Backup) {
        books = b.books
        sessions = b.sessions
        progress = b.progress
        bookmarks = b.bookmarks
        highlights = b.highlights ?? [:]
        goal = b.goal
        readerSettings = b.readerSettings
        normalizeOrder()
        scheduleSave()
    }

    func makeBackupData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(makeBackup())
    }

    func makeSessionsCSV() -> String {
        var rows: [String] = ["start,end,book,seconds,minutes,pages,manual"]
        let isoFormatter = ISO8601DateFormatter()
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            let start = isoFormatter.string(from: s.start)
            let end = s.end.map { isoFormatter.string(from: $0) } ?? ""
            let title = "\"\(s.bookTitle.replacingOccurrences(of: "\"", with: "\"\""))\""
            rows.append("\(start),\(end),\(title),\(s.secs),\(s.secs / 60),\(s.pages.map(String.init) ?? ""),\(s.manual ? "1" : "0")")
        }
        return rows.joined(separator: "\n")
    }

    static func contentFingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
