import Foundation

struct ICloudSyncPayload: Codable {
    var version: String
    var deviceID: String
    var updatedAt: Date
    var backup: Store.Backup
    var sessionModifiedAt: [String: Date]?
    var deletedSessionIDs: [String: Date]?
}


actor ICloudSync {
    static let shared = ICloudSync()

    private let syncFolderName = "BookSmarts Sync"

    nonisolated var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    func readPayloads() async -> [ICloudSyncPayload] {
        guard let directory = await syncDirectoryURL(createDirectory: false) else { return [] }
        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return urls
                .filter { $0.pathExtension.lowercased() == "json" }
                .compactMap { url -> ICloudSyncPayload? in
                    try? fileManager.startDownloadingUbiquitousItem(at: url)
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decoder.decode(ICloudSyncPayload.self, from: data)
                }
        }.value
    }

    func writePayload(_ payload: ICloudSyncPayload) async throws {
        guard let directory = await syncDirectoryURL(createDirectory: true) else {
            throw ICloudSyncError.iCloudUnavailable
        }
        let url = directory.appendingPathComponent(syncFileName(for: payload.deviceID))
        try await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        }.value
    }


    private func syncFileName(for deviceID: String) -> String {
        "bookmark-sync-\(deviceID).json"
    }

    private func syncDirectoryURL(createDirectory: Bool) async -> URL? {
        guard let container = await ubiquityContainerURL() else { return nil }
        let directory = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(syncFolderName, isDirectory: true)
        if createDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func ubiquityContainerURL() async -> URL? {
        await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }.value
    }
}

enum ICloudSyncError: Error {
    case iCloudUnavailable
}
