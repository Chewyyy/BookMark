import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI
import UIKit

/// Aggregate location info passed up from Readium when the position changes.
struct ReadiumLocation {
    var totalProgress: Double            // 0...1 across the whole book
    var locatorJSON: String?
    var bookPosition: Int?               // absolute position across the whole book
    var bookPositionTotal: Int?          // total positions
    var resourceIndex: Int?              // 0-based index into reading order (chapter)
    var resourceTotal: Int?              // total resources
    var chapterPosition: Int?            // 1-based position within the current resource
    var chapterPositionTotal: Int?       // total positions within the current resource
    var chapterTitle: String?            // best-effort chapter title
    var publisherPage: Int?
    var publisherPageLabel: String?
    var publisherPageTotal: Int?
}

struct ReadiumPublisherPage: Equatable {
    var totalProgress: Double
    var label: String
    var number: Int?
}

struct ReadiumChapterPageState: Equatable {
    var resourceIndex: Int
    var currentPage: Int
    var totalPages: Int
}

struct ReadiumChapterJump: Equatable {
    let id: UUID
    let chapterIndex: Int

    init(chapterIndex: Int) {
        self.id = UUID()
        self.chapterIndex = chapterIndex
    }
}

struct ReadiumDiagnosticPageTurnRequest: Equatable {
    let id: UUID
    let direction: Int

    init(direction: Int) {
        self.id = UUID()
        self.direction = direction < 0 ? -1 : 1
    }
}

struct ReadiumDiagnosticPageTurnResult: Equatable {
    let requestID: UUID
    let moved: Bool
}

struct ReadiumReaderContainer: View {
    let epubURL: URL
    let settings: ReaderSettings
    let initialProgress: Double
    let pendingLocatorJSON: String?
    let pendingChapterJump: ReadiumChapterJump?
    let diagnosticPageTurnRequest: ReadiumDiagnosticPageTurnRequest?
    let highlights: [Highlight]
    let onLocationChange: (ReadiumLocation) -> Void
    let onChapterPageChange: (ReadiumChapterPageState?) -> Void
    let onPageTurn: (Int) -> Void
    let onCenterTap: () -> Void
    let onHighlightSelection: (String, String) -> Void
    let onPublicationReady: (Publication?) -> Void
    let onDiagnosticPageTurnResult: (ReadiumDiagnosticPageTurnResult) -> Void

    @StateObject private var loader = ReadiumReaderLoader()
    @StateObject private var bridge = ReadiumNavigatorBridge()
    @State private var pageTurnVisual: PageTurnVisual?
    @State private var isFadeTurnInFlight = false
    @State private var interactiveCurlDirection: Int?

    var body: some View {
        ZStack {
            if let publication = loader.publication {
                ReadiumEPUBNavigatorView(
                    publication: publication,
                    initialLocation: loader.initialLocation,
                    settings: settings,
                    bridge: bridge,
                    pendingLocatorJSON: pendingLocatorJSON,
                    pendingChapterJump: pendingChapterJump,
                    highlights: highlights,
                    positionsByResource: loader.positionsByResource,
                    publisherPages: loader.publisherPages,
                    onLocationChange: onLocationChange,
                    onChapterPageChange: onChapterPageChange,
                    onHighlightSelection: onHighlightSelection,
                    onInitFailure: { msg in loader.error = msg; loader.publication = nil }
                )
            } else if let error = loader.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Could not open this book")
                        .font(.system(size: 16, weight: .heavy))
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading book...")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            if let pageTurnVisual {
                PageTurnOverlay(visual: pageTurnVisual, palette: ReaderThemePalette.resolve(settings.theme))
                    .id(pageTurnVisual.id)
                    .allowsHitTesting(false)
            }

            // Tap zones overlay — driven by the bridge so we can call Readium's
            // async navigator methods without holding the controller in SwiftUI.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    tapZone(width: geo.size.width * 0.30) {
                        turnPage(direction: -1)
                    }
                    tapZone(width: geo.size.width * 0.40) { onCenterTap() }
                    tapZone(width: geo.size.width * 0.30) {
                        turnPage(direction: 1)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .local)
                        .onChanged { value in
                            guard settings.swipe else { return }
                            updateInteractiveSwipe(value, size: geo.size)
                        }
                        .onEnded { value in
                            guard settings.swipe else { return }
                            finishInteractiveSwipe(value, width: geo.size.width)
                        }
                )
            }
            .ignoresSafeArea()
        }
        .task(id: epubURL) {
            onPublicationReady(nil)
            await loader.open(epubURL: epubURL, initialProgress: initialProgress)
            onPublicationReady(loader.publication)
        }
        .onChange(of: diagnosticPageTurnRequest) { _, request in
            guard let request else { return }
            performDiagnosticPageTurn(direction: request.direction)
        }
    }

    @ViewBuilder
    private func tapZone(width: CGFloat, onTap: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
    }

    private func turnPage(direction: Int) {
        let animation = settings.pageAnim
        if animation == .fade {
            performFadePageTurn(direction: direction)
            return
        }
        if animation == .curl || animation == .rigid {
            guard !bridge.isAnimatingPageTurn else { return }
            onPageTurn(direction)
            Task { @MainActor in
                _ = await bridge.performAnimatedTurn(direction: direction, mode: animation)
            }
            return
        }
        performReadiumPageTurn(direction: direction, animation: animation)
    }

    private func performFadePageTurn(direction: Int) {
        guard !isFadeTurnInFlight else { return }
        isFadeTurnInFlight = true

        let visual = PageTurnVisual(animation: .fade, direction: direction, progress: 0.001)
        pageTurnVisual = visual

        let fadeOutDuration = PageAnimation.fade.fadeOutDuration
        let fadeInDuration = PageAnimation.fade.fadeInDuration

        withAnimation(.easeInOut(duration: fadeOutDuration)) {
            pageTurnVisual = visual.withProgress(1)
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(fadeOutDuration * 1_000_000_000))
            await MainActor.run {
                guard pageTurnVisual?.id == visual.id else {
                    isFadeTurnInFlight = false
                    return
                }
                performReadiumPageTurn(direction: direction, animation: .fade)
            }

            try? await Task.sleep(nanoseconds: 80_000_000)
            await MainActor.run {
                guard pageTurnVisual?.id == visual.id else {
                    isFadeTurnInFlight = false
                    return
                }
                withAnimation(.easeInOut(duration: fadeInDuration)) {
                    pageTurnVisual = visual.withProgress(0.001)
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(fadeInDuration * 1_000_000_000))
            await MainActor.run {
                guard pageTurnVisual?.id == visual.id else {
                    isFadeTurnInFlight = false
                    return
                }
                pageTurnVisual = nil
                isFadeTurnInFlight = false
            }
        }
    }

    private func updateInteractiveSwipe(_ value: DragGesture.Value, size: CGSize) {
        let dx = value.translation.width
        let dy = value.translation.height
        guard abs(dx) > 6 else { return }

        let animation = settings.pageAnim
        guard animation == .curl else { return }

        let direction = dx < 0 ? 1 : -1
        let rawProgress = abs(dx) / max(size.width * 0.72, 1)
        let progress = min(0.98, max(0.02, rawProgress))
        let verticalPull = max(-1, min(1, dy / max(size.height * 0.24, 1)))
        let touchY = max(0, min(1, value.startLocation.y / max(size.height, 1)))

        if interactiveCurlDirection == nil {
            guard abs(dx) > abs(dy) * 0.42 else { return }
            guard !bridge.isAnimatingPageTurn else { return }
            if bridge.beginInteractiveCurl(direction: direction) {
                interactiveCurlDirection = direction
            } else {
                return
            }
        } else if interactiveCurlDirection != direction {
            // User reversed direction mid-drag — clamp progress back to 0.
            bridge.updateInteractiveCurl(progress: 0)
            return
        }
        bridge.updateInteractiveCurl(progress: progress, verticalPull: verticalPull, touchY: touchY)
    }

    private func finishInteractiveSwipe(_ value: DragGesture.Value, width: CGFloat) {
        let dx = value.translation.width
        let dy = value.translation.height
        let predictedDx = value.predictedEndTranslation.width
        let threshold = max(58, width * 0.18)
        let isHorizontal = abs(dx) > abs(dy) * 1.20 || abs(predictedDx) > threshold

        let animation = settings.pageAnim

        if animation == .curl {
            // Resolve interactive curl session if one is open.
            if let dragDir = interactiveCurlDirection {
                interactiveCurlDirection = nil
                let commit: Bool = {
                    if dragDir > 0 {
                        return dx < -threshold || predictedDx < -threshold
                    } else {
                        return dx > threshold || predictedDx > threshold
                    }
                }()
                if commit { onPageTurn(dragDir) }
                bridge.endInteractiveCurl(commit: commit)
                return
            }
            // Drag was too short for a session — fall through to tap turn if it crossed the threshold.
        }

        guard isHorizontal else { return }
        let direction: Int
        if dx < -threshold || predictedDx < -threshold {
            direction = 1
        } else if dx > threshold || predictedDx > threshold {
            direction = -1
        } else {
            return
        }
        turnPage(direction: direction)
    }

    private func performReadiumPageTurn(direction: Int, animation: PageAnimation) {
        onPageTurn(direction)

        let useReadiumAnimation = animation == .slide
        if direction < 0 {
            bridge.goBackward(animated: useReadiumAnimation)
        } else {
            bridge.goForward(animated: useReadiumAnimation)
        }
    }

    private func performDiagnosticPageTurn(direction: Int) {
        onPageTurn(direction)
        guard let request = diagnosticPageTurnRequest else { return }
        Task { @MainActor in
            let moved: Bool
            if direction < 0 {
                moved = await bridge.goBackwardAsync(animated: false)
            } else {
                moved = await bridge.goForwardAsync(animated: false)
            }
            if !moved {
                onPageTurn(0)
            }
            onDiagnosticPageTurnResult(ReadiumDiagnosticPageTurnResult(requestID: request.id, moved: moved))
        }
    }

}

@MainActor
final class ReadiumNavigatorBridge: ObservableObject {
    weak var navigator: EPUBNavigatorViewController?
    weak var animator: PageTurnAnimator?

    var isAnimatingPageTurn: Bool { animator?.isAnimating ?? false }

    func goForward(animated: Bool) {
        guard let navigator else { return }
        Task { _ = await navigator.goForward(options: NavigatorGoOptions(animated: animated)) }
    }

    func goBackward(animated: Bool) {
        guard let navigator else { return }
        Task { _ = await navigator.goBackward(options: NavigatorGoOptions(animated: animated)) }
    }

    func goForwardAsync(animated: Bool) async -> Bool {
        guard let navigator else { return false }
        return await navigator.goForward(options: NavigatorGoOptions(animated: animated))
    }

    func goBackwardAsync(animated: Bool) async -> Bool {
        guard let navigator else { return false }
        return await navigator.goBackward(options: NavigatorGoOptions(animated: animated))
    }

    @discardableResult
    func performAnimatedTurn(direction: Int, mode: PageAnimation) async -> Bool {
        guard let animator else { return false }
        return await animator.performTapTurn(direction: direction, mode: mode)
    }

    @discardableResult
    func beginInteractiveCurl(direction: Int) -> Bool {
        animator?.beginInteractiveCurl(direction: direction) ?? false
    }

    func updateInteractiveCurl(progress: CGFloat, verticalPull: CGFloat = 0, touchY: CGFloat = 0.5) {
        animator?.updateInteractiveCurl(progress: progress, verticalPull: verticalPull, touchY: touchY)
    }

    func endInteractiveCurl(commit: Bool) {
        animator?.endInteractiveCurl(commit: commit)
    }
}

private struct PageTurnVisual: Identifiable, Equatable {
    let id: UUID
    let animation: PageAnimation
    let direction: Int
    let progress: CGFloat

    init(id: UUID = UUID(), animation: PageAnimation, direction: Int, progress: CGFloat) {
        self.id = id
        self.animation = animation
        self.direction = direction
        self.progress = max(0, min(1, progress))
    }

    func withProgress(_ progress: CGFloat) -> PageTurnVisual {
        PageTurnVisual(id: id, animation: animation, direction: direction, progress: progress)
    }
}

private extension PageAnimation {
    // SwiftUI overlay is only used for fade now; curl and rigid run in the
    // UIKit PageTurnAnimator so they can use real Readium snapshots.
    var fadeOutDuration: Double { self == .fade ? 0.36 : 0 }
    var fadeInDuration: Double { self == .fade ? 0.42 : 0 }
}

private struct PageTurnOverlay: View {
    let visual: PageTurnVisual
    let palette: ReaderThemePalette.Palette

    var body: some View {
        Group {
            switch visual.animation {
            case .fade:
                palette.backgroundColor
                    .opacity(0.88 * visual.progress)
                    .transition(.opacity)
            case .rigid, .curl, .slide, .none:
                EmptyView()
            }
        }
        .ignoresSafeArea()
    }
}

@MainActor
final class ReadiumReaderLoader: ObservableObject {
    @Published var publication: Publication?
    @Published var initialLocation: Locator?
    @Published var positionsByResource: [[Locator]] = []
    @Published var publisherPages: [ReadiumPublisherPage] = []
    @Published var error: String?

    private let httpClient = DefaultHTTPClient()
    private lazy var assetRetriever = AssetRetriever(httpClient: httpClient)
    private lazy var publicationOpener = PublicationOpener(
        parser: DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        )
    )

    func open(epubURL: URL, initialProgress: Double) async {
        publication = nil
        initialLocation = nil
        positionsByResource = []
        publisherPages = []
        error = nil

        guard let fileURL = FileURL(url: epubURL) else {
            error = "Invalid EPUB file URL."
            return
        }

        do {
            let asset = try await assetRetriever.retrieve(url: fileURL).get()
            let openedPublication = try await publicationOpener.open(asset: asset, allowUserInteraction: true).get()
            let boundedProgress = max(0, min(1, initialProgress))
            let positions = await openedPublication.positionsByReadingOrder().getOrNil() ?? []
            positionsByResource = positions
            publisherPages = await resolvePublisherPages(in: openedPublication)
            initialLocation = await openedPublication.locate(progression: boundedProgress)
            publication = openedPublication
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func resolvePublisherPages(in publication: Publication) async -> [ReadiumPublisherPage] {
        var raw: [(totalProgress: Double, label: String)] = []
        for link in publication.pageList {
            guard let locator = await publication.locate(link),
                  let totalProgress = locator.locations.totalProgression ?? locator.locations.progression else {
                continue
            }
            let label = (link.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let pageLabel = label.isEmpty ? "\(raw.count + 1)" : label
            raw.append((max(0, min(1, totalProgress)), pageLabel))
        }
        // Some EPUBs expose only a "Cover Page" entry (or a couple of nav markers);
        // treat anything below this threshold as no publisher pagination so we fall
        // back to position-based display instead of rendering "Page Cover Page of 1".
        guard raw.count >= 5 else { return [] }
        let sorted = raw.enumerated().sorted { lhs, rhs in
            if lhs.element.totalProgress == rhs.element.totalProgress {
                return lhs.offset < rhs.offset
            }
            return lhs.element.totalProgress < rhs.element.totalProgress
        }
        return sorted.enumerated().map { newIndex, item in
            ReadiumPublisherPage(
                totalProgress: item.element.totalProgress,
                label: item.element.label,
                number: newIndex + 1
            )
        }
    }
}

struct ReadiumEPUBNavigatorView: UIViewControllerRepresentable {
    let publication: Publication
    let initialLocation: Locator?
    let settings: ReaderSettings
    let bridge: ReadiumNavigatorBridge
    let pendingLocatorJSON: String?
    let pendingChapterJump: ReadiumChapterJump?
    let highlights: [Highlight]
    let positionsByResource: [[Locator]]
    let publisherPages: [ReadiumPublisherPage]
    let onLocationChange: (ReadiumLocation) -> Void
    let onChapterPageChange: (ReadiumChapterPageState?) -> Void
    let onHighlightSelection: (String, String) -> Void
    let onInitFailure: (String) -> Void
    @Environment(\.horizontalSizeClass) private var hSizeClass

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLocationChange: onLocationChange,
            onChapterPageChange: onChapterPageChange,
            onHighlightSelection: onHighlightSelection,
            positionsByResource: positionsByResource,
            publisherPages: publisherPages,
            publication: publication
        )
    }

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: EPUBNavigatorViewController.Configuration(
                    preferences: readiumPreferences(for: settings),
                    editingActions: EditingAction.defaultActions + [
                        EditingAction(title: "Highlight", action: #selector(ReaderNavigatorHostViewController.addBookMarkHighlight(_:)))
                    ],
                    contentInset: [
                        .compact: (top: 10, bottom: 70),
                        .regular: (top: 24, bottom: 78),
                    ]
                )
            )
            navigator.delegate = context.coordinator
            context.coordinator.navigator = navigator
            let host = ReaderNavigatorHostViewController(
                navigator: navigator,
                palette: ReaderThemePalette.resolve(settings.theme)
            )
            host.onHighlightSelection = { [weak navigator] selection in
                context.coordinator.addHighlight(selection)
                navigator?.clearSelection()
            }
            context.coordinator.lastPreferences = readiumPreferences(for: settings)
            bridge.navigator = navigator
            bridge.animator = host.pageTurnAnimator
            context.coordinator.applyHighlights(highlights)
            return host
        } catch {
            DispatchQueue.main.async { onInitFailure(error.localizedDescription) }
            // Return a transparent placeholder so SwiftUI has something to mount.
            // The parent will switch to its error state via onInitFailure.
            let placeholder = UIViewController()
            placeholder.view.backgroundColor = .clear
            return placeholder
        }
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let host = controller as? ReaderNavigatorHostViewController else { return }
        let navigator = host.navigator
        let preferences = readiumPreferences(for: settings)
        context.coordinator.positionsByResource = positionsByResource
        context.coordinator.publisherPages = publisherPages
        context.coordinator.publication = publication
        bridge.navigator = navigator
        bridge.animator = host.pageTurnAnimator
        host.pageTurnAnimator.palette = ReaderThemePalette.resolve(settings.theme)
        context.coordinator.applyHighlights(highlights)
        if context.coordinator.lastPreferences != preferences {
            context.coordinator.lastPreferences = preferences
            context.coordinator.resetViewportPageCache()
            navigator.submitPreferences(preferences)
        }
        if let pendingLocatorJSON,
           pendingLocatorJSON != context.coordinator.lastJumpLocatorJSON,
           let locator = try? Locator(json: JSONValue(jsonString: pendingLocatorJSON, warnings: nil), warnings: nil) {
            context.coordinator.lastJumpLocatorJSON = pendingLocatorJSON
            Task {
                _ = await navigator.go(to: locator, options: NavigatorGoOptions(animated: true))
            }
        }
        if let pendingChapterJump,
           pendingChapterJump.id != context.coordinator.lastChapterJumpID,
           positionsByResource.indices.contains(pendingChapterJump.chapterIndex),
           let locator = positionsByResource[pendingChapterJump.chapterIndex].first {
            context.coordinator.lastChapterJumpID = pendingChapterJump.id
            Task {
                _ = await navigator.go(to: locator, options: NavigatorGoOptions(animated: true))
            }
        }
    }

    @MainActor
    private func readiumPreferences(for settings: ReaderSettings) -> EPUBPreferences {
        EPUBPreferences(
            backgroundColor: ReadiumNavigator.Color(hex: ReaderThemePalette.resolve(settings.theme).bgHex),
            columnCount: .one,
            fontFamily: readiumFont(for: settings.font),
            // The displayed "Font Size" slider treats 100% as the comfortable
            // baseline, but Readium's underlying scale starts smaller than the
            // tuned reading experience. Multiply by 1.2 so the slider's 100%
            // matches what used to render as 120% — keeping the displayed
            // percentage stable while shifting the visible baseline up.
            fontSize: Double(settings.fontSize) / 100.0 * 1.2,
            fontWeight: settings.bold ? 1.2 : nil,
            lineHeight: settings.lineHeight,
            pageMargins: readiumMargins(for: settings.margins, sizeClass: hSizeClass),
            publisherStyles: true,
            scroll: false,
            textAlign: settings.justify ? .justify : .start,
            textColor: ReadiumNavigator.Color(hex: ReaderThemePalette.resolve(settings.theme).fgHex),
            theme: readiumTheme(for: settings.theme)
        )
    }

    private func readiumTheme(for theme: ReaderTheme) -> ReadiumNavigator.Theme {
        switch theme {
        case .night, .focus: return .dark
        case .quiet: return .sepia
        case .original, .paper, .calm: return .light
        }
    }

    private func readiumFont(for font: ReaderFont) -> FontFamily? {
        switch font {
        case .original: return nil
        case .georgia: return .georgia
        case .palatino: return .palatino
        case .charter: return "Charter"
        case .times, .serif: return .serif
        case .sans, .system: return .sansSerif
        case .rounded: return "Avenir Next Rounded"
        case .mono: return .monospace
        }
    }

    private func readiumMargins(for margin: LayoutMargin, sizeClass: UserInterfaceSizeClass?) -> Double {
        let base: Double
        switch margin {
        case .narrow: base = 0.7
        case .normal: base = 1.0
        case .wide:   base = 1.35
        }
        // On iPad (regular width), the EPUB margin multiplier produces a
        // text column that leaves a lot of empty horizontal space. Scale
        // the value down aggressively so the text column actually uses the
        // canvas. iPhone (compact) keeps its original behavior so nothing
        // changes for the existing reading experience.
        return sizeClass == .regular ? base * 0.20 : base
    }

    @MainActor
    final class Coordinator: NSObject, EPUBNavigatorDelegate {
        weak var navigator: EPUBNavigatorViewController?
        var lastPreferences: EPUBPreferences?
        var lastJumpLocatorJSON: String?
        var lastChapterJumpID: UUID?
        var positionsByResource: [[Locator]]
        var publisherPages: [ReadiumPublisherPage]
        var publication: Publication
        private var appliedHighlightIDs: [String] = []
        private var lastChapterPageState: ReadiumChapterPageState?
        private var currentResourceIndex: Int?
        private var pageSpanByResource: [Int: Double] = [:]
        private var pageTotalByResource: [Int: Int] = [:]
        private let onLocationChange: (ReadiumLocation) -> Void
        private let onChapterPageChange: (ReadiumChapterPageState?) -> Void
        private let onHighlightSelection: (String, String) -> Void

        init(
            onLocationChange: @escaping (ReadiumLocation) -> Void,
            onChapterPageChange: @escaping (ReadiumChapterPageState?) -> Void,
            onHighlightSelection: @escaping (String, String) -> Void,
            positionsByResource: [[Locator]],
            publisherPages: [ReadiumPublisherPage],
            publication: Publication
        ) {
            self.onLocationChange = onLocationChange
            self.onChapterPageChange = onChapterPageChange
            self.onHighlightSelection = onHighlightSelection
            self.positionsByResource = positionsByResource
            self.publisherPages = publisherPages
            self.publication = publication
        }

        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            let progress = locator.locations.totalProgression ?? locator.locations.progression ?? 0
            let json = try? locator.jsonString()
            let bookPosition = locator.locations.position
            let bookTotal = positionsByResource.isEmpty ? nil : positionsByResource.reduce(0) { $0 + $1.count }

            let resourceIndex = publication.readingOrder.firstIndex { link in
                link.url().isEquivalentTo(locator.href)
            }
            currentResourceIndex = resourceIndex

            var chapterPos: Int?
            var chapterTotal: Int?
            if let idx = resourceIndex, positionsByResource.indices.contains(idx) {
                let positions = positionsByResource[idx]
                chapterTotal = positions.count
                if let firstAbs = positions.first?.locations.position, let abs = bookPosition {
                    chapterPos = max(1, abs - firstAbs + 1)
                } else if let prog = locator.locations.progression, !positions.isEmpty {
                    chapterPos = max(1, Int(round(prog * Double(positions.count))))
                }
            }

            let title: String? = {
                if let idx = resourceIndex, publication.readingOrder.indices.contains(idx) {
                    return publication.readingOrder[idx].title
                }
                return locator.title
            }()

            let publisherPage = publisherPage(for: progress)
            onLocationChange(ReadiumLocation(
                totalProgress: progress,
                locatorJSON: json,
                bookPosition: bookPosition,
                bookPositionTotal: bookTotal,
                resourceIndex: resourceIndex,
                resourceTotal: publication.readingOrder.count,
                chapterPosition: chapterPos,
                chapterPositionTotal: chapterTotal,
                chapterTitle: title,
                publisherPage: publisherPage?.number,
                publisherPageLabel: publisherPage?.label,
                publisherPageTotal: publisherPages.isEmpty ? nil : publisherPages.count
            ))

            if let viewportNavigator = navigator as? any ViewportObservingNavigator {
                publishChapterPageState(from: viewportNavigator.viewport)
            }
        }

        func navigator(_ navigator: any ViewportObservingNavigator, viewportDidChange viewport: NavigatorViewport?) {
            publishChapterPageState(from: viewport)
        }

        private func publishChapterPageState(from viewport: NavigatorViewport?) {
            let state = chapterPageState(from: viewport)
            guard state != lastChapterPageState else { return }
            lastChapterPageState = state
            onChapterPageChange(state)
        }

        func resetViewportPageCache() {
            lastChapterPageState = nil
            pageSpanByResource = [:]
            pageTotalByResource = [:]
            onChapterPageChange(nil)
        }

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}

        func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {}

        func addHighlight(_ selection: Selection) {
            guard let locatorJSON = try? selection.locator.jsonString() else { return }
            let text = selection.locator.text.sanitized().highlight ?? selection.locator.text.highlight ?? ""
            onHighlightSelection(locatorJSON, text)
        }

        func applyHighlights(_ highlights: [Highlight]) {
            guard let navigator else { return }
            let ids = highlights.map(\.id)
            guard ids != appliedHighlightIDs else { return }
            appliedHighlightIDs = ids

            let decorations: [Decoration] = highlights.compactMap { highlight in
                guard let locator = try? Locator(json: JSONValue(jsonString: highlight.locatorJSON, warnings: nil), warnings: nil) else {
                    return nil
                }
                return Decoration(
                    id: highlight.id,
                    locator: locator,
                    style: .highlight(tint: UIColor.bookMarkHighlightTint)
                )
            }
            navigator.apply(decorations: decorations, in: "bookMarkHighlights")
        }

        private func publisherPage(for progress: Double) -> ReadiumPublisherPage? {
            guard !publisherPages.isEmpty else { return nil }
            var low = 0
            var high = publisherPages.count
            while low < high {
                let mid = (low + high) / 2
                if publisherPages[mid].totalProgress <= progress {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return publisherPages[max(0, low - 1)]
        }

        private func chapterPageState(from viewport: NavigatorViewport?) -> ReadiumChapterPageState? {
            guard let viewport else {
                return nil
            }

            let indexedResources = viewport.resources.compactMap { resource -> (index: Int, resource: NavigatorViewport.Resource)? in
                guard let index = publication.readingOrder.firstIndex(where: { link in
                    link.url().isEquivalentTo(resource.href)
                }) else {
                    return nil
                }
                return (index, resource)
            }

            guard let selected = indexedResources.first(where: { $0.index == currentResourceIndex }) ?? indexedResources.first else {
                return nil
            }

            let resourceIndex = selected.index
            let range = selected.resource.progression
            let lower = max(0, min(1, range.lowerBound))
            let upper = max(lower, min(1, range.upperBound))
            let span = upper - lower
            guard span.isFinite, span > 0 else { return nil }

            if span >= 0.999 {
                pageSpanByResource[resourceIndex] = 1
                pageTotalByResource[resourceIndex] = 1
                return ReadiumChapterPageState(
                    resourceIndex: resourceIndex,
                    currentPage: 1,
                    totalPages: 1
                )
            }

            if pageSpanByResource[resourceIndex] == nil || lower < 0.01 {
                pageSpanByResource[resourceIndex] = span
                pageTotalByResource[resourceIndex] = max(1, Int(ceil((1.0 - 0.0001) / span)))
            }

            guard let pageSpan = pageSpanByResource[resourceIndex],
                  let totalPages = pageTotalByResource[resourceIndex] else {
                return nil
            }

            let currentPage: Int
            if upper >= 0.999 {
                currentPage = totalPages
            } else {
                currentPage = max(1, min(totalPages, Int(round(lower / pageSpan)) + 1))
            }

            return ReadiumChapterPageState(
                resourceIndex: resourceIndex,
                currentPage: currentPage,
                totalPages: totalPages
            )
        }
    }
}

final class ReaderNavigatorHostViewController: UIViewController {
    let navigator: EPUBNavigatorViewController
    let pageTurnAnimator: PageTurnAnimator
    var onHighlightSelection: ((Selection) -> Void)?

    init(navigator: EPUBNavigatorViewController, palette: ReaderThemePalette.Palette) {
        self.navigator = navigator
        self.pageTurnAnimator = PageTurnAnimator(palette: palette)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(navigator)
        view.addSubview(navigator.view)
        navigator.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navigator.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigator.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navigator.view.topAnchor.constraint(equalTo: view.topAnchor),
            navigator.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        navigator.didMove(toParent: self)
        // The animator places snapshot overlays into this view ABOVE the navigator.
        pageTurnAnimator.attach(hostView: view, navigator: navigator)
    }

    @objc func addBookMarkHighlight(_ sender: Any?) {
        guard let currentSelection = navigator.currentSelection else { return }
        onHighlightSelection?(currentSelection)
    }
}

private extension UIColor {
    static let bookMarkHighlightTint = UIColor(red: 1.0, green: 0.82, blue: 0.31, alpha: 0.58)
}
