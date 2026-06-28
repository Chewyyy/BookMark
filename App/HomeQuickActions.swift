import SwiftUI
import UIKit

@MainActor
final class HomeQuickActionRouter: ObservableObject {
    static let shared = HomeQuickActionRouter()

    static let continueReadingType = "com.bdeavilla.bookmark.quickAction.continueReading"
    private static let bookIDKey = "bookID"

    @Published private(set) var pendingBookID: String?

    private init() {}

    func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard shortcutItem.type == Self.continueReadingType,
              let bookID = shortcutItem.userInfo?[Self.bookIDKey] as? String,
              !bookID.isEmpty else { return false }
        pendingBookID = bookID
        return true
    }

    func consumePendingBookID() -> String? {
        let bookID = pendingBookID
        pendingBookID = nil
        return bookID
    }

    func updateShortcut(for store: Store) {
        guard store.didHydrate,
              let book = store.continueBook(),
              store.epubFileExists(for: book) else {
            UIApplication.shared.shortcutItems = []
            return
        }

        let item = UIApplicationShortcutItem(
            type: Self.continueReadingType,
            localizedTitle: "Continue Reading",
            localizedSubtitle: book.title,
            icon: UIApplicationShortcutIcon(systemImageName: "book.closed.fill"),
            userInfo: [Self.bookIDKey: book.id as NSString]
        )
        UIApplication.shared.shortcutItems = [item]
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = HomeQuickActionSceneDelegate.self
        return configuration
    }
}

final class HomeQuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let shortcutItem = connectionOptions.shortcutItem else { return }
        Task { @MainActor in
            _ = HomeQuickActionRouter.shared.handle(shortcutItem)
        }
    }

    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            let handled = HomeQuickActionRouter.shared.handle(shortcutItem)
            completionHandler(handled)
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        Task { @MainActor in
            HomeQuickActionRouter.shared.updateShortcut(for: Store.shared)
        }
    }
}
