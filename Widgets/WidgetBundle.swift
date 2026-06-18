import WidgetKit
import SwiftUI

@main
struct BookMarkWidgetBundle: WidgetBundle {
    var body: some Widget {
        BookMarkHomeWidget()
        BookMarkLockWidget()
    }
}
