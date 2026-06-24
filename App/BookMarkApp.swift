import SwiftUI

@main
struct BookMarkApp: App {
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(nil)
                .task {
                    await store.hydrate()
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
                            await scanWatchedFolder()
                            await ReadingReminderScheduler.reschedule(for: store, requestAuthorizationIfNeeded: store.hasCompletedOnboarding)
                        case .background:
                            await store.refreshSharedWidgetSnapshot()
                        default:
                            break
                        }
                    }
                }
        }
    }

    @MainActor
    private func scanWatchedFolder() async {
        guard store.didHydrate, let url = store.resolveWatchedFolder() else { return }
        _ = await EPUBImporter.rescanFolder(url, into: store)
    }
}
