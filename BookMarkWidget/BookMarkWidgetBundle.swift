import WidgetKit
import SwiftUI

@main
struct BookMarkWidgetBundle: WidgetBundle {
    var body: some Widget {
        BookMarkSmallContinueWidget()
        BookMarkWidget()
        BookMarkStatsWidget()
        BookMarkGraphsWidget()
    }
}
