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
    @Published var libraryPaginationStatus: LibraryPaginationStatus?
    /// Set while the one-time series/ISBN backfill walks the library, so the
    /// library can show a "Finding series 12/40" line. Nil when idle.
    @Published var librarySeriesStatus: LibrarySeriesStatus?
    /// Drives the first-launch onboarding cover. Stored in `UserDefaults` (a UI
    /// gate, not user content) so it survives independently of the JSON store and
    /// never round-trips through the debounced snapshot machinery.
    @Published var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: Store.onboardingDoneKey)

    static let onboardingDoneKey = "bookmark.hasCompletedOnboarding"
    static let appGroupId = "group.com.bdeavilla.bookmark"
    static let usesAppGroupStorage = false
    private static var cachedStoreDirectory: URL?

    private var saveTask: Task<Void, Never>?
    private var cloudSyncTask: Task<Void, Never>?
    private var isCloudSyncing = false
    private var liveReadingSession: LiveReadingSession?

    private static let cloudDeviceIDKey = "bookmark.icloud.deviceID"
    private static let lastAppliedICloudSyncKey = "bookmark.icloud.lastAppliedSync"
    private static let sessionModifiedAtKey = "bookmark.icloud.sessionModifiedAt"
    private static let deletedSessionIDsKey = "bookmark.icloud.deletedSessionIDs"
    private static let readerSettingsModifiedAtKey = "bookmark.icloud.readerSettingsModifiedAt"

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
        readerSettings.pageCountMode = .paginatedBook
        let watchedFolder = (try? Self.load(WatchedFolder.self, from: dir.appendingPathComponent("watched-folder.json")))
        watchedFolderBookmark = watchedFolder?.bookmarkData
        watchedFolderName = watchedFolder?.name
        let backupFolder = (try? Self.load(BackupFolder.self, from: dir.appendingPathComponent("backup-folder.json")))
        backupFolderBookmark = backupFolder?.bookmarkData
        backupFolderName = backupFolder?.name

        reconcileReadableBookFiles()
        await backfillContentFingerprints()
        reconcileReadableBookFiles()
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
        // Existing installs that already hold a library predate onboarding —
        // mark it done so an app update never drops returning readers back into
        // the first-launch tutorial.
        if !hasCompletedOnboarding, !books.isEmpty || !sessions.isEmpty {
            completeOnboarding()
        }
        didHydrate = true
        scheduleSave()
    }

    /// Flip the first-launch gate once the user finishes (or skips) onboarding.
    func completeOnboarding() {
        guard !hasCompletedOnboarding else { return }
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.onboardingDoneKey)
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
        HomeQuickActionRouter.shared.updateShortcut(for: self)
        Task { await ReadingReminderScheduler.reschedule(for: self) }
        scheduleICloudSync()
    }

    private func scheduleICloudSync() {
        guard didHydrate, !isCloudSyncing else { return }
        cloudSyncTask?.cancel()
        cloudSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            await self.syncWithICloud()
        }
    }

    func refreshSharedWidgetSnapshot() async {
        await writeSharedSnapshot()
    }

    func syncWithICloud() async {
        guard didHydrate, ICloudSync.shared.isAvailable, !isCloudSyncing else { return }
        isCloudSyncing = true
        defer { isCloudSyncing = false }

        let remotes = await ICloudSync.shared.readPayloads()
            .filter(shouldApplyICloudPayload)
            .sorted { $0.updatedAt < $1.updatedAt }
        var mergedRemotePayload = false
        for remote in remotes {
            mergeICloudPayload(remote)
            setLastAppliedICloudSyncDate(remote.updatedAt)
            mergedRemotePayload = true
        }
        if mergedRemotePayload {
            await writeSharedSnapshot()
        }

        let updatedAt = Date()
        let payload = ICloudSyncPayload(
            version: "icloud-1",
            deviceID: Self.cloudDeviceID,
            updatedAt: updatedAt,
            backup: makeICloudBackup(),
            sessionModifiedAt: sessionModifiedAtForSync(),
            deletedSessionIDs: deletedSessionIDsForSync(),
            readerSettingsModifiedAt: readerSettingsModifiedAt()
        )
        do {
            try await ICloudSync.shared.writePayload(payload)
            setLastAppliedICloudSyncDate(updatedAt)
        } catch {
            #if DEBUG
            print("iCloud sync failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func shouldApplyICloudPayload(_ payload: ICloudSyncPayload) -> Bool {
        payload.deviceID != Self.cloudDeviceID
    }

    private func mergeICloudPayload(_ payload: ICloudSyncPayload) {
        let remote = payload.backup
        var remoteToLocalBookID: [String: String] = [:]

        for remoteBook in remote.books {
            if let localIndex = books.firstIndex(where: { $0.id == remoteBook.id }) {
                mergeCloudBook(remoteBook, into: localIndex)
                remoteToLocalBookID[remoteBook.id] = books[localIndex].id
            } else if let fingerprint = remoteBook.contentFingerprint,
                      let localIndex = books.firstIndex(where: { $0.contentFingerprint == fingerprint }) {
                mergeCloudBook(remoteBook, into: localIndex)
                remoteToLocalBookID[remoteBook.id] = books[localIndex].id
            } else if let localIndex = books.firstIndex(where: { normalize($0.title) == normalize(remoteBook.title) && authorsMatch($0.author, remoteBook.author) }) {
                mergeCloudBook(remoteBook, into: localIndex)
                remoteToLocalBookID[remoteBook.id] = books[localIndex].id
            } else {
                books.append(remoteBook)
                remoteToLocalBookID[remoteBook.id] = remoteBook.id
            }
        }

        for remoteProgress in remote.progress {
            let localID = remoteToLocalBookID[remoteProgress.key] ?? remoteProgress.key
            progress[localID] = mergedProgress(progress[localID], remoteProgress.value)
        }

        mergeRemoteSessionDeletions(payload.deletedSessionIDs ?? [:])
        let deletedSessionIDs = deletedSessionIDsForSync()
        var sessionModifiedAt = sessionModifiedAtForSync()

        for remoteSession in remote.sessions {
            let incomingModifiedAt = payload.sessionModifiedAt?[remoteSession.id] ?? remoteSession.end ?? remoteSession.start
            if let deletedAt = deletedSessionIDs[remoteSession.id], deletedAt >= incomingModifiedAt {
                continue
            }

            var session = remoteSession
            if let remoteBookID = session.bookId {
                session.bookId = remoteToLocalBookID[remoteBookID] ?? remoteBookID
            }
            if isLiveSessionID(session.id), hasFinalSessionMatchingLive(session) {
                markSessionDeleted(session.id)
                continue
            }

            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                let localModifiedAt = sessionModifiedAt[session.id] ?? sessions[index].end ?? sessions[index].start
                if incomingModifiedAt > localModifiedAt {
                    sessions[index] = sessionWithCalculatedPace(session)
                    sessionModifiedAt[session.id] = incomingModifiedAt
                    removeMatchingLiveSessions(for: session)
                }
            } else {
                sessions.append(sessionWithCalculatedPace(session))
                sessionModifiedAt[session.id] = incomingModifiedAt
                removeMatchingLiveSessions(for: session)
            }
        }
        for deletedID in deletedSessionIDsForSync().keys {
            sessionModifiedAt.removeValue(forKey: deletedID)
        }
        saveSessionModifiedAt(sessionModifiedAt)

        for remoteItems in remote.bookmarks {
            let localID = remoteToLocalBookID[remoteItems.key] ?? remoteItems.key
            bookmarks[localID] = mergedBookmarks(bookmarks[localID], remoteItems.value)
        }

        for remoteItems in remote.highlights ?? [:] {
            let localID = remoteToLocalBookID[remoteItems.key] ?? remoteItems.key
            highlights[localID] = mergedHighlights(highlights[localID], remoteItems.value)
        }

        goal = remote.goal
        mergeRemoteReaderSettings(remote.readerSettings, modifiedAt: payload.readerSettingsModifiedAt)
        reconcileReadableBookFiles()
        normalizeOrder()
        scheduleSave()
    }

    private func mergeCloudBook(_ remote: Book, into index: Int) {
        if books[index].coverData == nil { books[index].coverData = remote.coverData }
        if books[index].fileName == nil || !epubFileExists(for: books[index]) { books[index].fileName = remote.fileName }
        if books[index].contentFingerprint == nil { books[index].contentFingerprint = remote.contentFingerprint }
        if books[index].totalLocations == nil { books[index].totalLocations = remote.totalLocations }
        if books[index].wordCountsPerSpine == nil { books[index].wordCountsPerSpine = remote.wordCountsPerSpine }
        if books[index].totalWords == nil { books[index].totalWords = remote.totalWords }
        if books[index].isbn == nil { books[index].isbn = remote.isbn }
        if books[index].seriesName == nil, remote.seriesName != nil {
            books[index].seriesName = remote.seriesName
            books[index].seriesIndex = remote.seriesIndex
            books[index].seriesSource = remote.seriesSource
        }
        if isUnknownAuthor(books[index].author), !isUnknownAuthor(remote.author) { books[index].author = remote.author }
        if normalize(books[index].title).isEmpty, !normalize(remote.title).isEmpty { books[index].title = remote.title }
        if remote.finished {
            books[index].finished = true
            if books[index].finishedAt == nil || (remote.finishedAt ?? .distantFuture) < (books[index].finishedAt ?? .distantFuture) {
                books[index].finishedAt = remote.finishedAt
            }
        }
        if let remoteCache = remote.paginationCache {
            var cache = books[index].paginationCache ?? [:]
            for (key, settings) in remoteCache {
                if let existing = cache[key], existing.computedAt >= settings.computedAt { continue }
                cache[key] = settings
            }
            books[index].paginationCache = cache
        }
    }

    private func mergeRemoteSessionDeletions(_ remoteDeleted: [String: Date]) {
        guard !remoteDeleted.isEmpty else { return }
        var localDeleted = deletedSessionIDsForSync()
        var localModified = sessionModifiedAtForSync()

        for (sessionID, deletedAt) in remoteDeleted {
            if (localDeleted[sessionID] ?? .distantPast) < deletedAt {
                localDeleted[sessionID] = deletedAt
            }
            if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                let modifiedAt = localModified[sessionID] ?? sessions[index].end ?? sessions[index].start
                if deletedAt >= modifiedAt {
                    sessions.remove(at: index)
                    localModified.removeValue(forKey: sessionID)
                }
            }
        }

        saveDeletedSessionIDs(localDeleted)
        saveSessionModifiedAt(localModified)
    }

    private func sessionModifiedAtForSync() -> [String: Date] {
        loadDateMap(Self.sessionModifiedAtKey)
    }

    private func deletedSessionIDsForSync() -> [String: Date] {
        loadDateMap(Self.deletedSessionIDsKey)
    }

    private func markSessionModified(_ id: String, at date: Date = Date()) {
        var modified = sessionModifiedAtForSync()
        modified[id] = date
        saveSessionModifiedAt(modified)
        var deleted = deletedSessionIDsForSync()
        if deleted.removeValue(forKey: id) != nil {
            saveDeletedSessionIDs(deleted)
        }
    }

    private func markSessionDeleted(_ id: String, at date: Date = Date()) {
        var deleted = deletedSessionIDsForSync()
        deleted[id] = date
        saveDeletedSessionIDs(deleted)
        var modified = sessionModifiedAtForSync()
        modified.removeValue(forKey: id)
        saveSessionModifiedAt(modified)
    }

    private func saveSessionModifiedAt(_ value: [String: Date]) {
        saveDateMap(value, key: Self.sessionModifiedAtKey)
    }

    private func saveDeletedSessionIDs(_ value: [String: Date]) {
        saveDateMap(value, key: Self.deletedSessionIDsKey)
    }

    private func loadDateMap(_ key: String) -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    private func saveDateMap(_ value: [String: Date], key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func readerSettingsModifiedAt() -> Date {
        if let date = UserDefaults.standard.object(forKey: Self.readerSettingsModifiedAtKey) as? Date {
            return date
        }
        let date = Date()
        UserDefaults.standard.set(date, forKey: Self.readerSettingsModifiedAtKey)
        return date
    }

    private func markReaderSettingsModified(_ date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: Self.readerSettingsModifiedAtKey)
    }

    private func mergeRemoteReaderSettings(_ remote: ReaderSettings, modifiedAt remoteModifiedAt: Date?) {
        let remoteModifiedAt = remoteModifiedAt ?? .distantPast
        guard remoteModifiedAt > readerSettingsModifiedAt() else { return }
        readerSettings = remote
        readerSettings.pageCountMode = .paginatedBook
        markReaderSettingsModified(remoteModifiedAt)
    }

    func updateReaderSettings(_ settings: ReaderSettings) {
        readerSettings = settings
        readerSettings.pageCountMode = .paginatedBook
        markReaderSettingsModified()
        scheduleSave()
    }

    private func liveSessionID(for live: LiveReadingSession) -> String {
        "live-\(Self.cloudDeviceID)-\(live.bookId)-\(Int(live.startedAt.timeIntervalSince1970))"
    }

    private func isLiveSessionID(_ id: String) -> Bool {
        id.hasPrefix("live-")
    }

    private func sessionBookIDsMatch(_ lhs: ReadingSession, _ rhs: ReadingSession) -> Bool {
        if let lhsID = lhs.bookId, let rhsID = rhs.bookId {
            return lhsID == rhsID
        }
        return normalize(lhs.bookTitle) == normalize(rhs.bookTitle)
    }

    private func finalSessionMatchesLive(_ finalSession: ReadingSession, _ liveSession: ReadingSession) -> Bool {
        guard !isLiveSessionID(finalSession.id), isLiveSessionID(liveSession.id), sessionBookIDsMatch(finalSession, liveSession) else {
            return false
        }
        return abs(finalSession.start.timeIntervalSince(liveSession.start)) <= 2
    }

    private func hasFinalSessionMatchingLive(_ liveSession: ReadingSession) -> Bool {
        sessions.contains { finalSessionMatchesLive($0, liveSession) }
    }

    private func removeMatchingLiveSessions(for finalSession: ReadingSession) {
        guard !isLiveSessionID(finalSession.id) else { return }
        let matchingIDs = Set(sessions.filter { finalSessionMatchesLive(finalSession, $0) }.map(\.id))
        guard !matchingIDs.isEmpty else { return }
        for id in matchingIDs {
            markSessionDeleted(id)
        }
        sessions.removeAll { matchingIDs.contains($0.id) }
    }

    private func mergedBookmarks(_ existing: [Bookmark]?, _ incoming: [Bookmark]) -> [Bookmark] {
        var merged = existing ?? []
        var existingIDs = Set(merged.map(\.id))
        for item in incoming where existingIDs.insert(item.id).inserted {
            merged.append(item)
        }
        return merged.sorted { $0.createdAt < $1.createdAt }
    }

    private func mergedHighlights(_ existing: [Highlight]?, _ incoming: [Highlight]) -> [Highlight] {
        var merged = existing ?? []
        var existingIDs = Set(merged.map(\.id))
        for item in incoming where existingIDs.insert(item.id).inserted {
            merged.append(item)
        }
        return merged.sorted { $0.createdAt < $1.createdAt }
    }

    private static var cloudDeviceID: String {
        if let existing = UserDefaults.standard.string(forKey: cloudDeviceIDKey) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: cloudDeviceIDKey)
        return created
    }

    private func lastAppliedICloudSyncDate() -> Date {
        Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.lastAppliedICloudSyncKey))
    }

    private func setLastAppliedICloudSyncDate(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastAppliedICloudSyncKey)
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
        guard let live = liveReadingSession, live.bookId == bookId else { return }
        markSessionDeleted(liveSessionID(for: live))
        liveReadingSession = nil
    }

    fileprivate struct SaveSnapshot {
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
        do {
            try await StorePersistence.shared.writeSnapshot(s, to: Self.storeDirectory())
        } catch {
            return
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
        addOrAttachBook(b).added
    }

    func addOrAttachBook(_ b: Book) -> (added: Bool, bookId: String) {
        var book = b
        if let duplicateBookID = readableDuplicateBookID(for: book) {
            removeUnusedIncomingEPUBFile(for: book, duplicateBookID: duplicateBookID)
            return (false, duplicateBookID)
        }
        if let fileName = book.fileName,
           let attachedBookID = attachEPUBFile(
            title: book.title,
            author: book.author,
            coverData: book.coverData,
            fileName: fileName,
            contentFingerprint: book.contentFingerprint
           ) {
            return (false, attachedBookID)
        }
        book.order = books.count
        books.append(book)
        reconcileReadableBookFiles()
        normalizeOrder()
        scheduleSave()
        return (true, book.id)
    }

    private func readableDuplicateBookID(for book: Book) -> String? {
        guard let contentFingerprint = book.contentFingerprint else { return nil }
        return books.first {
            $0.contentFingerprint == contentFingerprint && epubFileExists(for: $0)
        }?.id
    }

    private func removeUnusedIncomingEPUBFile(for book: Book, duplicateBookID: String) {
        guard let fileName = book.fileName else { return }
        let duplicateFileName = books.first { $0.id == duplicateBookID }?.fileName
        guard duplicateFileName != fileName else { return }
        let url = Self.epubsDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    func attachEPUBFile(title: String, author: String, coverData: Data?, fileName: String, contentFingerprint: String?) -> String? {
        guard let i = books.firstIndex(where: {
            guard !epubFileExists(for: $0) else { return false }
            if let contentFingerprint, $0.contentFingerprint == contentFingerprint {
                return true
            }
            return normalize($0.title) == normalize(title) && authorsMatch($0.author, author)
        }) else {
            return nil
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
        return books[i].id
    }

    func containsBook(contentFingerprint: String) -> Bool {
        books.contains { $0.contentFingerprint == contentFingerprint && epubFileExists(for: $0) }
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
            mergeBookData(from: duplicate.id, into: books[i].id)
            idsToRemove.insert(duplicate.id)
        }

        if !idsToRemove.isEmpty {
            books.removeAll { idsToRemove.contains($0.id) }
            for id in idsToRemove {
                progress.removeValue(forKey: id)
                bookmarks.removeValue(forKey: id)
                highlights.removeValue(forKey: id)
            }
        }

        removeReadableDuplicateBooks()
    }

    private func removeReadableDuplicateBooks() {
        let groups = Dictionary(grouping: books.filter { book in
            guard book.contentFingerprint != nil else { return false }
            return epubFileExists(for: book)
        }) { book in
            book.contentFingerprint ?? ""
        }
        let duplicateGroups = groups.values.filter { $0.count > 1 }
        guard !duplicateGroups.isEmpty else { return }

        var idsToRemove = Set<String>()
        var fileNamesToRemove = Set<String>()

        for group in duplicateGroups {
            guard let keeper = group.sorted(by: shouldPreferDuplicateKeeper).first else { continue }
            for duplicate in group where duplicate.id != keeper.id {
                mergeBookData(from: duplicate.id, into: keeper.id)
                idsToRemove.insert(duplicate.id)
                if let duplicateFileName = duplicate.fileName, duplicateFileName != keeper.fileName {
                    fileNamesToRemove.insert(duplicateFileName)
                }
            }
        }

        guard !idsToRemove.isEmpty else { return }
        books.removeAll { idsToRemove.contains($0.id) }
        for id in idsToRemove {
            progress.removeValue(forKey: id)
            bookmarks.removeValue(forKey: id)
            highlights.removeValue(forKey: id)
        }
        for fileName in fileNamesToRemove {
            try? FileManager.default.removeItem(at: Self.epubsDirectory().appendingPathComponent(fileName))
        }
    }

    private func shouldPreferDuplicateKeeper(_ lhs: Book, _ rhs: Book) -> Bool {
        let lhsProgress = progress[lhs.id]
        let rhsProgress = progress[rhs.id]
        let lhsLastRead = lhsProgress?.lastRead ?? .distantPast
        let rhsLastRead = rhsProgress?.lastRead ?? .distantPast
        if lhsLastRead != rhsLastRead { return lhsLastRead > rhsLastRead }

        let lhsPct = lhsProgress?.pct ?? 0
        let rhsPct = rhsProgress?.pct ?? 0
        if lhsPct != rhsPct { return lhsPct > rhsPct }

        let lhsSeconds = sessions.reduce(0) { $0 + ($1.bookId == lhs.id ? $1.secs : 0) }
        let rhsSeconds = sessions.reduce(0) { $0 + ($1.bookId == rhs.id ? $1.secs : 0) }
        if lhsSeconds != rhsSeconds { return lhsSeconds > rhsSeconds }

        if lhs.finished != rhs.finished { return lhs.finished }
        if lhs.added != rhs.added { return lhs.added < rhs.added }
        return lhs.order < rhs.order
    }

    private func mergeBookData(from duplicateID: String, into keeperID: String) {
        guard duplicateID != keeperID,
              let keeperIndex = books.firstIndex(where: { $0.id == keeperID }),
              let duplicate = books.first(where: { $0.id == duplicateID })
        else { return }

        if books[keeperIndex].coverData == nil {
            books[keeperIndex].coverData = duplicate.coverData
        }
        if books[keeperIndex].totalLocations == nil {
            books[keeperIndex].totalLocations = duplicate.totalLocations
        }
        if books[keeperIndex].wordCountsPerSpine == nil {
            books[keeperIndex].wordCountsPerSpine = duplicate.wordCountsPerSpine
        }
        if books[keeperIndex].totalWords == nil {
            books[keeperIndex].totalWords = duplicate.totalWords
        }
        if books[keeperIndex].isbn == nil {
            books[keeperIndex].isbn = duplicate.isbn
        }
        if books[keeperIndex].seriesName == nil, duplicate.seriesName != nil {
            books[keeperIndex].seriesName = duplicate.seriesName
            books[keeperIndex].seriesIndex = duplicate.seriesIndex
            books[keeperIndex].seriesSource = duplicate.seriesSource
        }
        if isUnknownAuthor(books[keeperIndex].author), !isUnknownAuthor(duplicate.author) {
            books[keeperIndex].author = duplicate.author
        }
        if duplicate.finished {
            books[keeperIndex].finished = true
            if books[keeperIndex].finishedAt == nil || (duplicate.finishedAt ?? .distantFuture) < (books[keeperIndex].finishedAt ?? .distantFuture) {
                books[keeperIndex].finishedAt = duplicate.finishedAt
            }
        }
        if let duplicateCache = duplicate.paginationCache {
            var cache = books[keeperIndex].paginationCache ?? [:]
            for (key, settings) in duplicateCache {
                if let existing = cache[key] {
                    if settings.computedAt > existing.computedAt {
                        cache[key] = settings
                    }
                } else {
                    cache[key] = settings
                }
            }
            books[keeperIndex].paginationCache = cache
        }

        if let duplicateProgress = progress[duplicateID] {
            progress[keeperID] = mergedProgress(progress[keeperID], duplicateProgress)
        }
        for i in sessions.indices where sessions[i].bookId == duplicateID {
            sessions[i].bookId = keeperID
        }
        mergeBookmarks(from: duplicateID, into: keeperID)
        mergeHighlights(from: duplicateID, into: keeperID)
        if liveReadingSession?.bookId == duplicateID {
            liveReadingSession?.bookId = keeperID
        }
    }

    private func mergedProgress(_ existing: ReadingProgress?, _ incoming: ReadingProgress) -> ReadingProgress {
        guard let existing else { return incoming }
        if incoming.lastRead != existing.lastRead {
            return incoming.lastRead > existing.lastRead ? incoming : existing
        }
        return incoming.pct > existing.pct ? incoming : existing
    }

    private func mergeBookmarks(from duplicateID: String, into keeperID: String) {
        guard let incoming = bookmarks[duplicateID], !incoming.isEmpty else { return }
        var merged = bookmarks[keeperID] ?? []
        var existingIDs = Set(merged.map(\.id))
        for item in incoming where existingIDs.insert(item.id).inserted {
            merged.append(item)
        }
        bookmarks[keeperID] = merged.sorted { $0.createdAt < $1.createdAt }
    }

    private func mergeHighlights(from duplicateID: String, into keeperID: String) {
        guard let incoming = highlights[duplicateID], !incoming.isEmpty else { return }
        var merged = highlights[keeperID] ?? []
        var existingIDs = Set(merged.map(\.id))
        for item in incoming where existingIDs.insert(item.id).inserted {
            merged.append(item)
        }
        highlights[keeperID] = merged.sorted { $0.createdAt < $1.createdAt }
    }

    private func backfillContentFingerprints() async {
        let directory = Self.epubsDirectory()
        let work = books.compactMap { book -> (id: String, fileName: String)? in
            guard book.contentFingerprint == nil, let fileName = book.fileName else { return nil }
            return (book.id, fileName)
        }
        guard !work.isEmpty else { return }

        let fingerprints = await Task.detached(priority: .utility) {
            work.compactMap { item -> (id: String, fingerprint: String)? in
                let url = directory.appendingPathComponent(item.fileName)
                guard let data = try? Data(contentsOf: url) else { return nil }
                let fingerprint = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                return (item.id, fingerprint)
            }
        }.value

        var changed = false
        for item in fingerprints {
            guard let index = books.firstIndex(where: { $0.id == item.id }),
                  books[index].contentFingerprint == nil
            else { continue }
            books[index].contentFingerprint = item.fingerprint
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

    /// Persist the parsed word counts for a book. Called asynchronously after
    /// import or backfill so the user-facing import flow isn't blocked by
    /// SwiftSoup parsing on long textbooks.
    func updateWordCounts(bookId: String, perSpine: [Int], total: Int) {
        guard let i = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[i].wordCountsPerSpine = perSpine
        books[i].totalWords = total
        scheduleSave()
    }

    /// Persist series metadata + ISBN parsed from a book's EPUB. Never clobbers
    /// a series the user set by hand (`seriesSource == "manual"`), but always
    /// backfills a missing ISBN. Mirrors `updateWordCounts`' fire-after-parse
    /// pattern so import and backfill share one path.
    func updateSeriesMetadata(bookId: String, name: String?, index: Double?, isbn: String?, source: String?) {
        guard let i = books.firstIndex(where: { $0.id == bookId }) else { return }
        var changed = false

        if books[i].isbn == nil, let isbn, !isbn.isEmpty {
            books[i].isbn = isbn
            changed = true
        }

        if books[i].seriesSource != "manual" {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                if books[i].seriesName != trimmed || books[i].seriesIndex != index || books[i].seriesSource != source {
                    books[i].seriesName = trimmed
                    books[i].seriesIndex = index
                    books[i].seriesSource = source
                    changed = true
                }
            } else if books[i].seriesName == nil, books[i].seriesSource == nil {
                // We parsed the file and it carries no series. Stamp a sentinel so
                // the backfill marks this book "checked" and won't re-scan it every
                // launch. A manual edit or relink can still populate it later.
                books[i].seriesSource = "none"
                changed = true
            }
        }

        if changed { scheduleSave() }
    }

    /// User-entered series metadata. Stamps the source as "manual" so the
    /// re-parse paths (`updateSeriesMetadata`) never overwrite it. An empty name
    /// clears the series entirely (and resets the source so a future relink may
    /// repopulate it from the file).
    func setManualSeries(bookId: String, name: String?, index: Double?) {
        guard let i = books.firstIndex(where: { $0.id == bookId }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            books[i].seriesName = trimmed
            books[i].seriesIndex = index
            books[i].seriesSource = "manual"
        } else {
            books[i].seriesName = nil
            books[i].seriesIndex = nil
            books[i].seriesSource = nil
        }
        scheduleSave()
    }

    struct SeriesGroup: Identifiable, Hashable {
        var id: String      // normalized key for stable identity
        var name: String    // display name, as first seen
        var books: [Book]
    }

    /// Groups the library by series for the "By Series" view. Series are sorted
    /// alphabetically; books within a series by position (nil positions last),
    /// then title. Books with no series come back separately in library order.
    func seriesGroups() -> (series: [SeriesGroup], standalone: [Book]) {
        var grouped: [String: SeriesGroup] = [:]
        var order: [String] = []
        var standalone: [Book] = []

        for book in sortedBooks() {
            guard let raw = book.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                standalone.append(book)
                continue
            }
            let key = normalize(raw)
            if grouped[key] == nil {
                grouped[key] = SeriesGroup(id: key, name: raw, books: [])
                order.append(key)
            }
            grouped[key]?.books.append(book)
        }

        let series = order.compactMap { grouped[$0] }
            .map { group -> SeriesGroup in
                var g = group
                g.books.sort { lhs, rhs in
                    switch (lhs.seriesIndex, rhs.seriesIndex) {
                    case let (l?, r?): return l != r ? l < r : lhs.title < rhs.title
                    case (nil, _?): return false
                    case (_?, nil): return true
                    default: return lhs.title < rhs.title
                    }
                }
                return g
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return (series, standalone)
    }

    /// True when at least one book carries a series — used to decide whether the
    /// library's view-mode toggle is worth showing.
    var hasAnySeries: Bool {
        books.contains { ($0.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
    }

    /// Distinct series names already in the library, case-insensitively
    /// de-duplicated and alphabetized. Powers the "add to existing series"
    /// picker in the series editor.
    var allSeriesNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for book in books {
            guard let name = book.seriesName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            if seen.insert(name.lowercased()).inserted {
                result.append(name)
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func updatePaginationCache(bookId: String, key: PaginationKey, settings: PaginatedSettings) {
        guard let i = books.firstIndex(where: { $0.id == bookId }) else { return }
        var cache = books[i].paginationCache ?? [:]
        guard cache[key] != settings else { return }
        cache[key] = settings
        books[i].paginationCache = cache
        scheduleSave()
    }

    var currentPaginationKey: PaginationKey {
        PaginationKey(
            font: readerSettings.font,
            fontSize: readerSettings.fontSize,
            bold: readerSettings.bold,
            lineHeight: readerSettings.lineHeight,
            margins: readerSettings.margins,
            justify: readerSettings.justify,
            deviceClass: UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        )
    }

    func resolvedWordsPerPageForCurrentDevice() -> Int {
        if readerSettings.wordsPerPageMode == .automatic,
           let estimate = automaticWordsPerPageEstimate() {
            return estimate
        }
        return readerSettings.wordsPerPageForCurrentDevice
    }

    func automaticWordsPerPageEstimate() -> Int? {
        automaticWordsPerPageEstimate(for: currentPaginationKey)
            ?? automaticWordsPerPageEstimate(for: .defaultLibraryKey)
    }

    private func automaticWordsPerPageEstimate(for key: PaginationKey) -> Int? {
        if let paired = automaticWordsPerPageEstimate(for: key, requirePairedWords: true) {
            return paired
        }
        return automaticWordsPerPageEstimate(for: key, requirePairedWords: false)
    }

    private func automaticWordsPerPageEstimate(for key: PaginationKey, requirePairedWords: Bool) -> Int? {
        var chapterSamples: [Double] = []
        var sampledWords = 0
        var sampledPages = 0

        for book in books {
            guard let settings = book.paginationCache?[key] else { continue }
            let legacyCounts = requirePairedWords ? nil : book.wordCountsPerSpine

            var indexes = Set(settings.measuredChapterIndexes ?? [])
            if indexes.isEmpty, settings.measuredChapterIndex >= 0 {
                indexes.insert(settings.measuredChapterIndex)
            }

            for index in indexes where settings.pagesPerChapter.indices.contains(index) {
                let words: Int? = {
                    if let measuredWords = settings.measuredWordsPerChapter,
                       measuredWords.indices.contains(index),
                       measuredWords[index] > 0 {
                        return measuredWords[index]
                    }
                    if let legacyCounts,
                       legacyCounts.indices.contains(index),
                       legacyCounts[index] > 0 {
                        return legacyCounts[index]
                    }
                    return nil
                }()
                guard let words else { continue }
                let pages = settings.pagesPerChapter[index]
                guard pages > 0 else { continue }
                sampledWords += words
                sampledPages += pages
                chapterSamples.append(Double(words) / Double(pages))
            }
        }

        guard sampledWords >= 1_000, sampledPages >= 5, !chapterSamples.isEmpty else { return nil }
        let raw = chapterSamples.reduce(0, +) / Double(chapterSamples.count)
        let roundedToFive = Int((raw / 5.0).rounded() * 5.0)
        return ReaderSettings.clampedWordsPerPage(roundedToFive)
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
        let session = sessionWithCalculatedPace(s)
        sessions.append(session)
        markSessionModified(session.id)
        removeMatchingLiveSessions(for: session)
        scheduleSave()
    }

    func updateSession(_ s: ReadingSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[i] = sessionWithCalculatedPace(s)
            markSessionModified(s.id)
            scheduleSave()
        }
    }

    private func sessionWithCalculatedPace(_ session: ReadingSession) -> ReadingSession {
        var session = session
        let effectiveWordsPerPage = session.wordsPerPage ?? resolvedWordsPerPageForCurrentDevice()
        if session.wordsPerPage == nil, (session.pages ?? 0) > 0 {
            session.wordsPerPage = effectiveWordsPerPage
        }
        if session.wordsPerMinute == nil,
           let calculated = ReadingSession.calculatedWordsPerMinute(
            wordsRead: session.wordsRead,
            pages: session.pages,
            seconds: session.secs,
            wordsPerPage: effectiveWordsPerPage
        ) {
            session.wordsPerMinute = calculated
        }
        return session
    }

    func deleteSession(id: String) {
        sessions.removeAll { $0.id == id }
        markSessionDeleted(id)
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

    private func makeICloudBackup() -> Backup {
        var backup = makeBackup()
        guard let live = liveReadingSession,
              live.elapsedSeconds >= 60,
              let book = books.first(where: { $0.id == live.bookId })
        else {
            return backup
        }

        let sessionID = liveSessionID(for: live)
        markSessionModified(sessionID, at: live.startedAt)
        let session = ReadingSession(
            id: sessionID,
            bookId: live.bookId,
            bookTitle: book.title,
            start: live.startedAt,
            end: Date(),
            secs: live.elapsedSeconds,
            progressDelta: max(0, live.progressPct - (progress[live.bookId]?.pct ?? live.progressPct)),
            manual: false
        )
        if let index = backup.sessions.firstIndex(where: { $0.id == sessionID }) {
            backup.sessions[index] = sessionWithCalculatedPace(session)
        } else {
            backup.sessions.append(sessionWithCalculatedPace(session))
        }
        backup.progress[live.bookId] = ReadingProgress(pct: live.progressPct, cfi: live.cfi, lastRead: Date())
        return backup
    }

    func restoreBackup(_ b: Backup) {
        books = b.books
        sessions = b.sessions
        progress = b.progress
        bookmarks = b.bookmarks
        highlights = b.highlights ?? [:]
        goal = b.goal
        readerSettings = b.readerSettings
        readerSettings.pageCountMode = .paginatedBook
        markReaderSettingsModified()
        reconcileReadableBookFiles()
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
        var rows: [String] = ["start,end,book,seconds,minutes,pages,publisherPages,wordsRead,wordsPerMinute,manual"]
        let isoFormatter = ISO8601DateFormatter()
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            let start = isoFormatter.string(from: s.start)
            let end = s.end.map { isoFormatter.string(from: $0) } ?? ""
            let title = "\"\(s.bookTitle.replacingOccurrences(of: "\"", with: "\"\""))\""
            rows.append("\(start),\(end),\(title),\(s.secs),\(s.secs / 60),\(s.pages.map(String.init) ?? ""),\(s.publisherPages.map(String.init) ?? ""),\(s.wordsRead.map(String.init) ?? ""),\(s.wordsPerMinute.map { String(format: "%.2f", $0) } ?? ""),\(s.manual ? "1" : "0")")
        }
        return rows.joined(separator: "\n")
    }

    static func contentFingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

actor StorePersistence {
    static let shared = StorePersistence()

    fileprivate func writeSnapshot(_ snapshot: Store.SaveSnapshot, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try save(snapshot.books, to: directory.appendingPathComponent("books.json"))
        try save(snapshot.sessions, to: directory.appendingPathComponent("sessions.json"))
        try save(snapshot.progress, to: directory.appendingPathComponent("progress.json"))
        try save(snapshot.bookmarks, to: directory.appendingPathComponent("bookmarks.json"))
        try save(snapshot.highlights, to: directory.appendingPathComponent("highlights.json"))
        try save(snapshot.goal, to: directory.appendingPathComponent("goal.json"))
        try save(snapshot.readerSettings, to: directory.appendingPathComponent("reader.json"))

        let watchedURL = directory.appendingPathComponent("watched-folder.json")
        if let watchedFolder = snapshot.watchedFolder {
            try save(watchedFolder, to: watchedURL)
        } else {
            try? FileManager.default.removeItem(at: watchedURL)
        }

        let backupURL = directory.appendingPathComponent("backup-folder.json")
        if let backupFolder = snapshot.backupFolder {
            try save(backupFolder, to: backupURL)
        } else {
            try? FileManager.default.removeItem(at: backupURL)
        }
    }

    func backupData(_ backup: Store.Backup, prettyPrinted: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(backup)
    }

    func writeBackup(_ payload: Data, to target: URL, includeDatedCopy: Bool, datePart: String) throws {
        let primary = target.appendingPathComponent("bookmark-database.json")
        try payload.write(to: primary, options: .atomic)

        if includeDatedCopy {
            let backups = target.appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let dated = backups.appendingPathComponent("bookmark-backup-\(datePart).json")
            try payload.write(to: dated, options: .atomic)
        }
    }

    func writeTemporaryFile(data: Data, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try encodedData(value).write(to: url, options: .atomic)
    }

    private func encodedData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
