import UIKit
import OSLog

struct TestCurlPageLabels: Equatable {
    static let empty = TestCurlPageLabels(currentPage: nil, totalPages: nil)

    var currentPage: Int?
    var totalPages: Int?

    var current: String? { pageText(offset: 0) }
    var previous: String? { pageText(offset: -1) }
    var next: String? { pageText(offset: 1) }

    func advanced(by direction: Int) -> TestCurlPageLabels {
        guard let currentPage else { return self }
        return TestCurlPageLabels(
            currentPage: clampedPage(currentPage + direction),
            totalPages: totalPages
        )
    }

    private func pageText(offset: Int) -> String? {
        guard let currentPage else { return nil }
        return "Page \(clampedPage(currentPage + offset))"
    }

    private func clampedPage(_ page: Int) -> Int {
        max(1, min(totalPages ?? page, page))
    }
}

@MainActor
final class TestCurlPageViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private static let logger = Logger(subsystem: "BookMark", category: "TestCurl")
    enum State: String {
        case idle
        case preparingTurn
        case curlingForward
        case curlingBackward
        case completingTurn
        case cancellingTurn
        case syncingReadium
    }

    private final class EdgePassthroughView: UIView {
        var shouldOwnFullSurface: () -> Bool = { false }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard bounds.contains(point) else { return false }
            guard !shouldOwnFullSurface() else { return true }
            let gutterWidth = max(44, bounds.width * 0.18)
            return point.x <= gutterWidth || point.x >= bounds.width - gutterWidth
        }
    }

    private final class SnapshotPageController: UIViewController {
        let role: Int
        private let image: UIImage?
        private var backgroundColor: UIColor

        init(role: Int, image: UIImage?, backgroundColor: UIColor) {
            self.role = role
            self.image = image
            self.backgroundColor = backgroundColor
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func loadView() {
            let container = UIView()
            container.backgroundColor = backgroundColor
            container.isOpaque = true
            container.clipsToBounds = true
            container.layer.backgroundColor = backgroundColor.cgColor

            let imageView = UIImageView(image: image)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleToFill
            imageView.backgroundColor = backgroundColor
            imageView.isOpaque = true
            imageView.clipsToBounds = true
            imageView.layer.backgroundColor = backgroundColor.cgColor
            container.addSubview(imageView)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            view = container
        }

        func updateBackgroundColor(_ color: UIColor) {
            backgroundColor = color
            view.backgroundColor = color
            view.layer.backgroundColor = color.cgColor
        }
    }

    private let pageViewController: UIPageViewController
    private var backgroundColor: UIColor
    private var labelColor: UIColor
    private var pageLabels: TestCurlPageLabels
    private var currentImage: UIImage
    private var currentPage: SnapshotPageController
    private var previousPage: SnapshotPageController?
    private var nextPage: SnapshotPageController?
    private var previousBackingPage: SnapshotPageController
    private var nextBackingPage: SnapshotPageController
    private var isProgrammaticTurn = false
    private let onCenterTap: () -> Void
    private let onTextInteractionRequest: () -> Void
    private let onTurnCompleted: (Int, Bool) -> Void
    private(set) var state: State = .idle
    /// True once the page-curl controller has completed at least one layout pass.
    /// An animated `.pageCurl` transition requested before this is set makes UIKit
    /// expect a two-controller mid-spine spread and throws, so turns wait for it.
    private var hasCompletedInitialLayout = false

    init(currentImage: UIImage,
         previousImage: UIImage?,
         nextImage: UIImage?,
         backgroundColor: UIColor,
         labelColor: UIColor,
         pageLabels: TestCurlPageLabels,
         onCenterTap: @escaping () -> Void,
         onTextInteractionRequest: @escaping () -> Void,
         onTurnCompleted: @escaping (Int, Bool) -> Void) {
        let backingImage = Self.makeBackingImage(from: currentImage, backgroundColor: backgroundColor)
        self.backgroundColor = backgroundColor
        self.labelColor = labelColor
        self.pageLabels = pageLabels
        self.currentImage = currentImage
        self.currentPage = SnapshotPageController(role: 0, image: Self.makePageImage(from: currentImage, pageLabel: pageLabels.current, labelColor: labelColor), backgroundColor: backgroundColor)
        self.previousPage = previousImage.map { SnapshotPageController(role: -1, image: Self.makePageImage(from: $0, pageLabel: pageLabels.previous, labelColor: labelColor), backgroundColor: backgroundColor) }
        self.nextPage = nextImage.map { SnapshotPageController(role: 1, image: Self.makePageImage(from: $0, pageLabel: pageLabels.next, labelColor: labelColor), backgroundColor: backgroundColor) }
        self.previousBackingPage = SnapshotPageController(role: -2, image: backingImage, backgroundColor: backgroundColor)
        self.nextBackingPage = SnapshotPageController(role: 2, image: backingImage, backgroundColor: backgroundColor)
        self.onCenterTap = onCenterTap
        self.onTextInteractionRequest = onTextInteractionRequest
        self.onTurnCompleted = onTurnCompleted
        self.pageViewController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [UIPageViewController.OptionsKey.spineLocation: UIPageViewController.SpineLocation.min.rawValue]
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let passthroughView = EdgePassthroughView()
        passthroughView.shouldOwnFullSurface = { [weak self] in
            guard let self else { return false }
            return self.state != .idle
        }
        view = passthroughView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = backgroundColor
        addChild(pageViewController)
        view.addSubview(pageViewController.view)
        pageViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pageViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pageViewController.didMove(toParent: self)
        pageViewController.dataSource = self
        pageViewController.delegate = self
        pageViewController.isDoubleSided = true
        pageViewController.view.backgroundColor = backgroundColor
        pageViewController.view.isOpaque = true
        tintPageCurlBacking(in: pageViewController.view)
        installCenterTapRecognizer()
        installCenterLongPressRecognizer()
        pageViewController.setViewControllers([currentPage], direction: .forward, animated: false)
        log("interactiveSurfaceReady previous=\(previousPage != nil) next=\(nextPage != nil)")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Once the page-curl controller has a non-zero bounds it has resolved its
        // spine and a single-controller animated turn is safe.
        if !hasCompletedInitialLayout, view.window != nil, !view.bounds.isEmpty {
            hasCompletedInitialLayout = true
        }
    }

    func updateColors(backgroundColor color: UIColor, labelColor: UIColor) {
        backgroundColor = color
        self.labelColor = labelColor
        view.backgroundColor = color
        pageViewController.view.backgroundColor = color
        rebuildBackingPages()
        tintPageCurlBacking(in: pageViewController.view)
    }

    func updateSnapshots(currentImage: UIImage, previousImage: UIImage?, nextImage: UIImage?, pageLabels: TestCurlPageLabels) {
        state = .idle
        self.currentImage = currentImage
        self.pageLabels = pageLabels
        currentPage = SnapshotPageController(role: 0, image: Self.makePageImage(from: currentImage, pageLabel: pageLabels.current, labelColor: labelColor), backgroundColor: backgroundColor)
        previousPage = previousImage.map { SnapshotPageController(role: -1, image: Self.makePageImage(from: $0, pageLabel: pageLabels.previous, labelColor: labelColor), backgroundColor: backgroundColor) }
        nextPage = nextImage.map { SnapshotPageController(role: 1, image: Self.makePageImage(from: $0, pageLabel: pageLabels.next, labelColor: labelColor), backgroundColor: backgroundColor) }
        rebuildBackingPages()
        pageViewController.setViewControllers([currentPage], direction: .forward, animated: false)
        log("snapshotsUpdated previous=\(previousPage != nil) next=\(nextPage != nil)")
    }

    func startProgrammaticTurn(direction: Int) {
        guard state == .idle else { return }
        let destination = direction > 0 ? nextPage : previousPage
        guard let destination else {
            onTurnCompleted(direction, false)
            return
        }

        // The page-curl UIPageViewController must finish its initial layout before an
        // animated transition. If it hasn't (e.g. the user taps the instant the overlay
        // becomes ready, right at launch), force a layout pass; if it still isn't on a
        // window, decline the turn rather than crash with an NSInvalidArgumentException
        // ("number of view controllers provided (1) doesn't match the number required (2)").
        if !hasCompletedInitialLayout {
            view.layoutIfNeeded()
        }
        guard hasCompletedInitialLayout, pageViewController.viewControllers?.count == 1 else {
            log("programmaticTurn declined notReady direction=\(direction)")
            onTurnCompleted(direction, false)
            return
        }

        isProgrammaticTurn = true
        pageViewController.isDoubleSided = false
        state = direction > 0 ? .curlingForward : .curlingBackward
        let navigationDirection: UIPageViewController.NavigationDirection = direction > 0 ? .forward : .reverse
        pageViewController.setViewControllers([destination], direction: navigationDirection, animated: true) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                self.isProgrammaticTurn = false
                self.pageViewController.isDoubleSided = true
                self.state = finished ? .completingTurn : .cancellingTurn
                self.log("programmaticTransitionFinished=\(finished) direction=\(direction)")
                self.onTurnCompleted(direction, finished)
            }
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard !isProgrammaticTurn, let page = viewController as? SnapshotPageController else { return nil }
        switch page.role {
        case 0:
            return previousBackingPage
        case 2:
            return currentPage
        case -2:
            return previousPage
        case 1:
            return nextBackingPage
        default:
            return nil
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard !isProgrammaticTurn, let page = viewController as? SnapshotPageController else { return nil }
        switch page.role {
        case 0:
            return nextBackingPage
        case -2:
            return currentPage
        case 2:
            return nextPage
        case -1:
            return previousBackingPage
        default:
            return nil
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
        pageViewController.isDoubleSided = !isProgrammaticTurn
        return .min
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        let role = (pendingViewControllers.first as? SnapshotPageController)?.role ?? 0
        state = role > 0 ? .curlingForward : .curlingBackward
        retintCurlBackingDuringTransition()
        log("interactiveTransitionWillStart direction=\(role)")
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        guard !isProgrammaticTurn else { return }
        let role = (pageViewController.viewControllers?.first as? SnapshotPageController)?.role ?? 0
        let direction = completed ? normalizedDirection(for: role) : 0
        state = completed ? .completingTurn : .cancellingTurn
        tintPageCurlBacking(in: pageViewController.view)
        log("interactiveTransitionFinished=\(finished) completed=\(completed) direction=\(direction)")
        onTurnCompleted(direction, completed)
    }

    private func installCenterTapRecognizer() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCenterTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        pageViewController.view.addGestureRecognizer(tap)
    }

    private func installCenterLongPressRecognizer() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCenterLongPress(_:)))
        longPress.minimumPressDuration = 0.32
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        pageViewController.view.addGestureRecognizer(longPress)
    }

    @objc private func handleCenterTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let location = recognizer.location(in: view)
        guard isCenterTapLocation(location) else { return }
        onCenterTap()
    }

    @objc private func handleCenterLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let location = recognizer.location(in: view)
        guard isCenterTapLocation(location) else { return }
        onTextInteractionRequest()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        isCenterTapLocation(touch.location(in: view))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private func isCenterTapLocation(_ location: CGPoint) -> Bool {
        guard view.bounds.width > 0 else { return false }
        let centerMinX = view.bounds.width * 0.30
        let centerMaxX = view.bounds.width * 0.70
        return location.x >= centerMinX && location.x <= centerMaxX
    }

    private func normalizedDirection(for role: Int) -> Int {
        if role > 0 { return 1 }
        if role < 0 { return -1 }
        return 0
    }

    private func retintCurlBackingDuringTransition() {
        tintPageCurlBacking(in: pageViewController.view)
        for delay in [0.016, 0.05, 0.10] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.tintPageCurlBacking(in: self.pageViewController.view)
            }
        }
    }

    private func rebuildBackingPages() {
        let backingImage = Self.makeBackingImage(from: currentImage, backgroundColor: backgroundColor)
        previousBackingPage = SnapshotPageController(role: -2, image: backingImage, backgroundColor: backgroundColor)
        nextBackingPage = SnapshotPageController(role: 2, image: backingImage, backgroundColor: backgroundColor)
    }

    static func makePageImage(from image: UIImage, pageLabel: String?, labelColor: UIColor) -> UIImage {
        guard let pageLabel, !pageLabel.isEmpty else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true

        let size = image.size
        let rect = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { _ in
            image.draw(in: rect)

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: labelColor.withAlphaComponent(0.72),
                .paragraphStyle: paragraph,
            ]
            let labelHeight: CGFloat = 18
            let bottomInset: CGFloat = 38
            let labelRect = CGRect(
                x: 24,
                y: max(0, size.height - bottomInset - labelHeight),
                width: max(0, size.width - 48),
                height: labelHeight
            )
            pageLabel.draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
        }
    }

    private static func makeBackingImage(from image: UIImage, backgroundColor: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true

        let size = image.size
        let rect = CGRect(origin: .zero, size: size)
        let alpha = backingTextAlpha(for: backgroundColor)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            backgroundColor.setFill()
            context.fill(rect)

            context.cgContext.saveGState()
            context.cgContext.translateBy(x: size.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            image.draw(in: rect, blendMode: .normal, alpha: alpha)
            context.cgContext.restoreGState()
        }
    }

    private static func backingTextAlpha(for color: UIColor) -> CGFloat {
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            return white < 0.35 ? 0.38 : 0.24
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            return luminance < 0.35 ? 0.38 : 0.24
        }

        return 0.30
    }

    private func tintPageCurlBacking(in view: UIView) {
        view.backgroundColor = backgroundColor
        view.isOpaque = true
        view.layer.backgroundColor = backgroundColor.cgColor
        for subview in view.subviews {
            tintPageCurlBacking(in: subview)
        }
    }

    private func log(_ message: String) {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "BookMark.TestCurlLogging") else { return }
        Self.logger.debug("\(message, privacy: .public)")
        #endif
    }
}
