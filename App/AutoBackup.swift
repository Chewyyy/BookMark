import Foundation
import UIKit

/// Saves the current reading database to the app's Documents folder so it shows
/// up in the iOS Files app (BookMark folder), and optionally rolls dated copies
/// into `Documents/Backups/` — mirrors the webapp's
/// `saveBackupToThisIPhone(includeDatedCopy: true)` flow.
///
/// File layout in the Files app:
///   On My iPhone / BookMark /
///     bookmark-database.json              ← latest snapshot (overwritten each save)
///     Backups/
///       bookmark-backup-YYYY-MM-DD.json   ← one per calendar day
///
/// EPUB binaries are intentionally NOT included (same as the webapp).
@MainActor
enum AutoBackup {
    /// UserDefaults key for the last successful backup time (used by Stats).
    static let lastBackupKey = "BookMark.AutoBackup.lastSucceededAt"
    /// UserDefaults key for the last backup location label (used by Stats).
    static let lastBackupLocationKey = "BookMark.AutoBackup.lastLocationLabel"

    /// Debounce window — matches the webapp's 1200 ms timer so we don't write
    /// the database every keystroke when the user is editing a session.
    private static let debounceNanos: UInt64 = 1_200_000_000

    private static var debounceTask: Task<Void, Never>?

    /// Schedule a debounced background write. Each call cancels the previous
    /// pending write. Safe to call from `Store.scheduleSave`.
    static func scheduleAutomatic(store: Store) {
        debounceTask?.cancel()
        debounceTask = Task { [weak store] in
            try? await Task.sleep(nanoseconds: debounceNanos)
            guard !Task.isCancelled, let store else { return }
            _ = await Self.write(store: store, includeDatedCopy: true, silently: true)
        }
    }

    /// Write the backup immediately. Used by the "Save to This iPhone" button.
    /// Returns a user-facing message on success, or nil on failure.
    @discardableResult
    static func writeNow(store: Store) async -> String? {
        await write(store: store, includeDatedCopy: true, silently: false)
    }

    @discardableResult
    private static func write(store: Store, includeDatedCopy: Bool, silently: Bool) async -> String? {
        let backup = store.makeBackup()
        guard let payload = try? await StorePersistence.shared.backupData(backup, prettyPrinted: !silently) else { return nil }

        // Prefer a user-chosen folder (persists when the app is deleted, e.g. iCloud
        // Drive). Fall back to the app's Documents folder so the existing behavior
        // is unchanged when no custom folder is set.
        let customFolder = store.resolveBackupFolder()
        let needsStop = customFolder?.startAccessingSecurityScopedResource() ?? false
        defer {
            if needsStop, let customFolder {
                customFolder.stopAccessingSecurityScopedResource()
            }
        }

        let target: URL
        let locationLabel: String
        if let customFolder {
            target = customFolder
            locationLabel = store.backupFolderName ?? customFolder.lastPathComponent
        } else {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
            target = docs
            locationLabel = "On My iPhone / BookSmarts"
        }

        let datePart = isoDayFormatter.string(from: Date())
        do {
            try await StorePersistence.shared.writeBackup(
                payload,
                to: target,
                includeDatedCopy: includeDatedCopy,
                datePart: datePart
            )
        } catch {
            return nil
        }

        UserDefaults.standard.set(Date(), forKey: lastBackupKey)
        UserDefaults.standard.set(locationLabel, forKey: lastBackupLocationKey)
        guard !silently else { return nil }
        return "Saved \(byteCountFormatter.string(fromByteCount: Int64(payload.count))) to \(locationLabel)"
    }

    /// Returns the user-visible "last backed up …" string for the Stats card.
    static func lastBackupStatus() -> String? {
        guard let date = UserDefaults.standard.object(forKey: lastBackupKey) as? Date else {
            return "Never backed up yet."
        }
        let location = (UserDefaults.standard.string(forKey: lastBackupLocationKey)) ?? "Files"
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "Last saved to \(location) just now" }
        let formatter = relativeFormatter
        return "Last saved to \(location) \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let byteCountFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
