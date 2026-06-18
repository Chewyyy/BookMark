import Foundation

/// Read-only access to the snapshot the main app writes into the App Group container.
/// Used by the widget extension. Keep this file in the *widget target only*.
enum SharedSnapshotStore {
    static let appGroupId = "group.com.bdeavilla.bookmark"

    static func load() -> SharedSnapshot {
        guard let url = snapshotURL() else { return .empty }
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SharedSnapshot.self, from: data)) ?? .empty
    }

    private static func snapshotURL() -> URL? {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        return group
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
    }
}

/// Mirror of the snapshot struct the main app writes. Keep in sync with
/// `SharedSnapshot` in the main app's `Models.swift`. The widget target should
/// include a copy of that struct or this duplicate definition.
struct SharedSnapshot: Codable, Hashable {
    var todayMinutes: Int
    var goalMinutes: Int
    var currentStreak: Int
    var continueTitle: String?
    var continueAuthor: String?
    var continueProgressPct: Int?
    var updatedAt: Date

    static let empty = SharedSnapshot(
        todayMinutes: 0,
        goalMinutes: 15,
        currentStreak: 0,
        continueTitle: nil,
        continueAuthor: nil,
        continueProgressPct: nil,
        updatedAt: Date()
    )
}
