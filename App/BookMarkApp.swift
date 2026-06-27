import SwiftUI

@main
struct BookMarkApp: App {
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var foregroundSyncTask: Task<Void, Never>?
    @State private var foregroundCatchupTask: Task<Void, Never>?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(nil)
                .task {
                    await store.hydrate()
                    await store.syncWithICloud()
                    startForegroundSyncLoop()
                    startForegroundCatchupSyncs()
                    await scanWatchedFolder()
                    // Books imported before word-count tracking existed don't
                    // have totalWords yet. Walk the library once and parse
                    // anything missing — each parse runs on a utility-priority
                    // background task so launch isn't blocked.
                    EPUBImporter.backfillWordCounts(into: store)
                    // Same idea for series name/number + ISBN: parse it out of
                    // each legacy EPUB's embedded metadata, once.
                    EPUBImporter.backfillSeriesMetadata(into: store)
                    // Defer the notification permission prompt until onboarding
                    // has run — the reminder step asks for it in context instead.
                    await ReadingReminderScheduler.reschedule(for: store, requestAuthorizationIfNeeded: store.hasCompletedOnboarding)
                }
                .onChange(of: scenePhase) { _, phase in
                    Task {
                        switch phase {
                        case .active:
                            await store.syncWithICloud()
                            startForegroundSyncLoop()
                            startForegroundCatchupSyncs()
                            await scanWatchedFolder()
                            await ReadingReminderScheduler.reschedule(for: store, requestAuthorizationIfNeeded: store.hasCompletedOnboarding)
                        case .inactive:
                            stopForegroundSyncLoop()
                            await store.syncWithICloud()
                        case .background:
                            stopForegroundSyncLoop()
                            await store.syncWithICloud()
                            await store.refreshSharedWidgetSnapshot()
                        default:
                            break
                        }
                    }
                }
        }
    }

    @MainActor
    private func startForegroundSyncLoop() {
        guard foregroundSyncTask == nil else { return }
        foregroundSyncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { break }
                await store.syncWithICloud()
            }
        }
    }

    @MainActor
    private func startForegroundCatchupSyncs() {
        foregroundCatchupTask?.cancel()
        foregroundCatchupTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await store.syncWithICloud()
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            await store.syncWithICloud()
        }
    }

    @MainActor
    private func stopForegroundSyncLoop() {
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        foregroundCatchupTask?.cancel()
        foregroundCatchupTask = nil
    }

    @MainActor
    private func scanWatchedFolder() async {
        guard store.didHydrate, let url = store.resolveWatchedFolder() else { return }
        _ = await EPUBImporter.rescanFolder(url, into: store)
    }
}
