#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
enum WidgetRefreshBroker {
    static func reloadContinueReading() {
        reloadAll()
    }

    static func reloadAll() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "BookMarkSmallContinueWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "BookMarkWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "BookMarkStatsWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "BookMarkGraphsWidget")
        #endif
    }
}
