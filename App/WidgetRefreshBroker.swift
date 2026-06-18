#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
enum WidgetRefreshBroker {
    static func reloadContinueReading() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "BookMarkSmallContinueWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "BookMarkWidget")
        #endif
    }
}
