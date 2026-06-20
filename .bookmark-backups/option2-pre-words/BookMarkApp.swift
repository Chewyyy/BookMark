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
                    await ReadingReminderScheduler.reschedule(for: store, requestAuthorizationIfNeeded: true)
                }
                .onChange(of: scenePhase) { _, phase in
                    Task {
                        switch phase {
                        case .active:
                            await scanWatchedFolder()
                            await ReadingReminderScheduler.reschedule(for: store, requestAuthorizationIfNeeded: true)
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
