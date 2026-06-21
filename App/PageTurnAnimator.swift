import UIKit
import ReadiumNavigator
import ReadiumShared

// Snapshot-based page-turn animator that sits in a UIKit overlay above the
// Readium navigator. It keeps Readium responsible for pagination and content
// rendering; we only paint the outgoing page on top while the new page renders
// underneath.
//
// Timing contract for every turn:
//   1) Capture an outgoing snapshot of Readium's view BEFORE navigation.
//   2) Cover the navigator with that snapshot so the user never sees a flash.
//   3) Call Readium navigation with animated:false; the new page renders underneath.
//   4) Wait one render pass so the destination page is present underneath.
//   5) Animate the outgoing snapshot away with the selected segmented page turn.
//   6) Remove all overlay layers; Readium's live view is the final visible page.
@MainActor
final class PageTurnAnimator {
    weak var hostView: UIView?
    weak var navigatorController: EPUBNavigatorViewController?
    var palette: ReaderThemePalette.Palette

    private(set) var isAnimating: Bool = false

    // Wait long enough after navigation for WKWebView to paint the new page.
    private static let renderSettleNanoseconds: UInt64 = 90_000_000
    // Frame budget for hand-driven animations (~60fps).
    private static let frameStepNanoseconds: UInt64 = 16_000_000

    private struct InteractiveSession {
        let direction: Int
        let mode: PageAnimation
        let container: UIView
        let stripLayers: [CALayer]
        let foldShadow: CAGradientLayer
        let foldHighlight: CAGradientLayer
        let underShadow: CAGradientLayer
        let image: UIImage
        var navigationCompleted: Bool
        var navigationSucceeded: Bool
        var coverFallback: UIImageView?
        var lastProgress: CGFloat
        var lastVerticalPull: CGFloat
        var lastTouchY: CGFloat
    }
    private var session: InteractiveSession?

    init(palette: ReaderThemePalette.Palette) {
        self.palette = palette
    }

    func attach(hostView: UIView, navigator: EPUBNavigatorViewController) {
        self.hostView = hostView
        self.navigatorController = navigator
    }

    // MARK: - Tap-triggered turns

    @discardableResult
    func performTapTurn(direction: Int, mode: PageAnimation) async -> Bool {
        guard !isAnimating, session == nil else { return false }
        guard let hostView, let nav = navigatorController else { return false }
        guard mode == .curl || mode == .rigid else { return false }

        isAnimating = true
        defer { isAnimating = false }

        // 1) Outgoing snapshot first.
        guard let image = captureImage(of: nav.view) else { return false }

        // 2) Cover Readium with the snapshot so navigation underneath is hidden.
        let cover = UIImageView(image: image)
        cover.frame = hostView.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        cover.contentMode = .scaleToFill
        hostView.addSubview(cover)

        // 3) Tell Readium to move; no visible animation here, we drive it.
        let success: Bool
        if direction > 0 {
            success = await nav.goForward(options: NavigatorGoOptions(animated: false))
        } else {
            success = await nav.goBackward(options: NavigatorGoOptions(animated: false))
        }

        guard success else {
            // At the edge of the book — just fade out the cover.
            await UIView.animateAsync(duration: 0.16) { cover.alpha = 0 }
            cover.removeFromSuperview()
            return false
        }

        // 4) Let the new page render underneath.
        try? await Task.sleep(nanoseconds: Self.renderSettleNanoseconds)

        // 5) Run the chosen animation.
        switch mode {
        case .rigid, .curl:
            cover.removeFromSuperview()
            await runCurlAnimation(image: image, direction: direction, allowsFloppyPull: mode == .curl)
        default:
            break
        }

        // 6) Cleanup any leftover cover.
        cover.removeFromSuperview()
        return true
    }

    // MARK: - Interactive curl (pan-driven)

    /// Returns true if a session was started. Caller should subsequently feed
    /// `updateInteractiveCurl(progress:)` and `endInteractiveCurl(commit:)`.
    @discardableResult
    func beginInteractiveCurl(direction: Int) -> Bool {
        guard !isAnimating, session == nil else { return false }
        guard let hostView, let nav = navigatorController else { return false }
        guard let image = captureImage(of: nav.view) else { return false }

        let container = UIView(frame: hostView.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.isUserInteractionEnabled = false
        container.backgroundColor = .clear
        hostView.addSubview(container)

        let strips = createStripLayers(image: image, direction: direction, in: container)
        let overlays = createCurlOverlays(in: container, direction: direction)

        // Keep the outgoing snapshot above the strips until Readium has rendered
        // the destination page underneath; then the animated strips can reveal it.
        let cover = UIImageView(image: image)
        cover.frame = container.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.contentMode = .scaleToFill
        cover.layer.zPosition = 10_000
        container.addSubview(cover)

        isAnimating = true
        session = InteractiveSession(
            direction: direction,
            mode: .curl,
            container: container,
            stripLayers: strips,
            foldShadow: overlays.shadow,
            foldHighlight: overlays.highlight,
            underShadow: overlays.under,
            image: image,
            navigationCompleted: false,
            navigationSucceeded: false,
            coverFallback: cover,
            lastProgress: 0,
            lastVerticalPull: 0,
            lastTouchY: 0.5
        )

        // Initial state so transforms are set even before first drag delta.
        applyCurlProgress(0.001, direction: direction, verticalPull: 0, touchY: 0.5)

        // Navigate in the background so the new page is ready underneath.
        Task { [weak self] in
            let success: Bool
            if direction > 0 {
                success = await nav.goForward(options: NavigatorGoOptions(animated: false))
            } else {
                success = await nav.goBackward(options: NavigatorGoOptions(animated: false))
            }
            try? await Task.sleep(nanoseconds: Self.renderSettleNanoseconds)
            await MainActor.run {
                guard let self else { return }
                guard var current = self.session, current.direction == direction else { return }
                current.navigationCompleted = true
                current.navigationSucceeded = success
                self.session = current
                if success {
                    // Reveal the strip-based view (drop the static cover so the new page is visible underneath).
                    current.coverFallback?.removeFromSuperview()
                    self.session?.coverFallback = nil
                } else {
                    // No page to turn to — cancel cleanly.
                    self.endInteractiveCurl(commit: false)
                }
            }
        }
        return true
    }

    func updateInteractiveCurl(progress: CGFloat, verticalPull: CGFloat = 0, touchY: CGFloat = 0.5) {
        guard let s = session else { return }
        let clamped = max(0, min(1, progress))
        let clampedVertical = max(-1, min(1, verticalPull))
        let clampedTouchY = max(0, min(1, touchY))
        session?.lastProgress = clamped
        session?.lastVerticalPull = clampedVertical
        session?.lastTouchY = clampedTouchY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCurlProgress(clamped, direction: s.direction, verticalPull: clampedVertical, touchY: clampedTouchY)
        CATransaction.commit()
    }

    func endInteractiveCurl(commit: Bool) {
        guard let current = session else { return }
        let direction = current.direction
        let navigationSucceeded = current.navigationSucceeded
        let navigationCompleted = current.navigationCompleted
        let nav = navigatorController

        // If commit was requested but navigation didn't actually move (e.g. edge of book),
        // treat it as a cancel so we don't strand the user on a snapshot.
        let actuallyCommit = commit && navigationSucceeded

        if actuallyCommit {
            let remaining = max(0, 1 - current.lastProgress)
            let duration = TimeInterval(max(0.18, min(0.38, 0.12 + remaining * 0.34)))
            runManualProgress(from: current.lastProgress, to: 1.0, verticalFrom: current.lastVerticalPull, touchY: current.lastTouchY, duration: duration) { [weak self] in
                self?.teardownInteractive()
            }
        } else {
            // Animate back to flat. If we already moved Readium forward, revert it.
            let duration = TimeInterval(max(0.16, min(0.30, 0.10 + current.lastProgress * 0.24)))
            runManualProgress(from: current.lastProgress, to: 0.0, verticalFrom: current.lastVerticalPull, touchY: current.lastTouchY, duration: duration) { [weak self] in
                guard let self else { return }
                guard let s = self.session else { return }
                if navigationSucceeded {
                    // Cover the strips again so the revert navigation isn't visible underneath.
                    let cover = UIImageView(image: s.image)
                    cover.frame = s.container.bounds
                    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    cover.contentMode = .scaleToFill
                    s.container.addSubview(cover)
                    for layer in s.stripLayers { layer.isHidden = true }
                    Task { @MainActor in
                        if let nav {
                            if direction > 0 {
                                _ = await nav.goBackward(options: NavigatorGoOptions(animated: false))
                            } else {
                                _ = await nav.goForward(options: NavigatorGoOptions(animated: false))
                            }
                            try? await Task.sleep(nanoseconds: Self.renderSettleNanoseconds)
                        }
                        self.teardownInteractive()
                    }
                } else if !navigationCompleted {
                    // Navigation hasn't reported yet; wait a moment then tear down.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        self.teardownInteractive()
                    }
                } else {
                    self.teardownInteractive()
                }
            }
        }
    }

    private func teardownInteractive() {
        session?.container.removeFromSuperview()
        session = nil
        isAnimating = false
    }

    // MARK: - Segmented page animation

    private func runCurlAnimation(image: UIImage, direction: Int, allowsFloppyPull: Bool) async {
        guard let hostView else { return }
        let container = UIView(frame: hostView.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.isUserInteractionEnabled = false
        hostView.addSubview(container)
        defer { container.removeFromSuperview() }

        let strips = createStripLayers(image: image, direction: direction, in: container)
        let overlays = createCurlOverlays(in: container, direction: direction)

        let duration: TimeInterval = 0.72
        let start = CACurrentMediaTime()
        while true {
            let elapsed = CACurrentMediaTime() - start
            let t = min(1.0, elapsed / duration)
            let eased = 1 - pow(1 - CGFloat(t), 2.35)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply(progress: eased,
                  direction: direction,
                  container: container,
                  strips: strips,
                  foldShadow: overlays.shadow,
                  foldHighlight: overlays.highlight,
                  underShadow: overlays.under,
                  verticalPull: allowsFloppyPull ? sin(CGFloat(t) * .pi) * -0.16 : 0,
                  touchY: 0.18)
            CATransaction.commit()
            if t >= 1.0 { break }
            try? await Task.sleep(nanoseconds: Self.frameStepNanoseconds)
        }
    }

    // MARK: - Strip / overlay construction

    private func captureImage(of view: UIView?) -> UIImage? {
        guard let view, view.bounds.width > 1, view.bounds.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        // Pull scale from the view's trait collection (or window screen) to avoid
        // the deprecated UIScreen.main on iOS 26+.
        let scale = view.window?.screen.scale ?? view.traitCollection.displayScale
        format.scale = scale > 0 ? scale : 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        return renderer.image { _ in
            // afterScreenUpdates: true forces WKWebView (used by Readium) to
            // flush its composited layer before we capture, so the snapshot
            // contains the live page contents.
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    private func createStripLayers(image: UIImage, direction: Int, in container: UIView) -> [CALayer] {
        guard let cgImage = image.cgImage else { return [] }
        let containerSize = container.bounds.size
        guard containerSize.width > 0, containerSize.height > 0 else { return [] }

        let forward = direction > 0

        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 1200.0
        container.layer.sublayerTransform = perspective

        let layer = CALayer()
        layer.contents = cgImage
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.allowsEdgeAntialiasing = true
        layer.masksToBounds = true
        layer.isDoubleSided = false
        layer.isOpaque = true
        layer.shouldRasterize = true
        layer.rasterizationScale = image.scale
        layer.contentsScale = image.scale
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 18
        layer.shadowOffset = .zero
        layer.bounds = CGRect(x: 0, y: 0, width: containerSize.width, height: containerSize.height)
        layer.anchorPoint = CGPoint(x: forward ? 0 : 1, y: 0.5)
        layer.position = CGPoint(x: forward ? 0 : containerSize.width, y: containerSize.height / 2)

        container.layer.addSublayer(layer)
        return [layer]
    }

    private func createCurlOverlays(in container: UIView, direction: Int) -> (shadow: CAGradientLayer, highlight: CAGradientLayer, under: CAGradientLayer) {
        let forward = direction > 0

        // Dim band that follows the fold across the curling page.
        let shadow = CAGradientLayer()
        shadow.colors = [
            UIColor.black.withAlphaComponent(0.0).cgColor,
            UIColor.black.withAlphaComponent(palette.isDark ? 0.55 : 0.35).cgColor,
            UIColor.black.withAlphaComponent(0.0).cgColor,
        ]
        shadow.locations = [0.0, 0.5, 1.0]
        shadow.startPoint = CGPoint(x: 0, y: 0.5)
        shadow.endPoint = CGPoint(x: 1, y: 0.5)
        shadow.opacity = 0
        container.layer.addSublayer(shadow)

        // Bright sliver right at the fold.
        let highlight = CAGradientLayer()
        highlight.colors = [
            UIColor.white.withAlphaComponent(0.0).cgColor,
            UIColor.white.withAlphaComponent(palette.isDark ? 0.10 : 0.28).cgColor,
            UIColor.white.withAlphaComponent(0.0).cgColor,
        ]
        highlight.locations = [0.0, 0.5, 1.0]
        highlight.startPoint = CGPoint(x: 0, y: 0.5)
        highlight.endPoint = CGPoint(x: 1, y: 0.5)
        highlight.opacity = 0
        container.layer.addSublayer(highlight)

        // Shadow cast onto the newly revealed page from the curling page.
        let under = CAGradientLayer()
        under.colors = [
            UIColor.black.withAlphaComponent(palette.isDark ? 0.45 : 0.30).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
        ]
        under.locations = [0.0, 1.0]
        under.startPoint = CGPoint(x: forward ? 1.0 : 0.0, y: 0.5)
        under.endPoint = CGPoint(x: forward ? 0.0 : 1.0, y: 0.5)
        under.opacity = 0
        container.layer.insertSublayer(under, at: 0)

        return (shadow, highlight, under)
    }

    // MARK: - Progress mapping

    private func applyCurlProgress(_ progress: CGFloat, direction: Int, verticalPull: CGFloat, touchY: CGFloat) {
        guard let s = session else { return }
        apply(progress: progress,
              direction: direction,
              container: s.container,
              strips: s.stripLayers,
              foldShadow: s.foldShadow,
              foldHighlight: s.foldHighlight,
              underShadow: s.underShadow,
              verticalPull: verticalPull,
              touchY: touchY)
    }

    private func apply(progress: CGFloat,
                       direction: Int,
                       container: UIView,
                       strips: [CALayer],
                       foldShadow: CAGradientLayer,
                       foldHighlight: CAGradientLayer,
                       underShadow: CAGradientLayer,
                       verticalPull: CGFloat,
                       touchY: CGFloat) {
        let containerSize = container.bounds.size
        let count = strips.count
        guard count > 0, containerSize.width > 0 else { return }

        let forward = direction > 0
        let height = containerSize.height
        let width = containerSize.width
        let rawProgress = max(0, min(1, progress))
        let eased = rawProgress * rawProgress * (3 - 2 * rawProgress)
        let edgeSign: CGFloat = forward ? -1 : 1
        let pull = max(-1, min(1, verticalPull))
        let cornerBias = (max(0, min(1, touchY)) - 0.5) * 2

        if count == 1, let sheet = strips.first {
            applySheetProgress(
                progress: rawProgress,
                eased: eased,
                direction: direction,
                sheet: sheet,
                width: width,
                height: height,
                pull: pull,
                cornerBias: cornerBias,
                foldShadow: foldShadow,
                foldHighlight: foldHighlight,
                underShadow: underShadow
            )
            return
        }

        let pageTravel = width * (1.0 * eased)
        let maxIndex = CGFloat(max(count - 1, 1))

        for i in 0..<count {
            // 0 at spine, 1 at the edge being dragged. The curl wave starts at
            // the dragged edge and rolls toward the spine as progress increases.
            let edgeWeight: CGFloat = forward
                ? CGFloat(i) / maxIndex
                : CGFloat(count - 1 - i) / maxIndex
            let wave = max(0, min(1, rawProgress * 1.34 - (1 - edgeWeight) * 0.58))
            let bend = wave * wave * (3 - 2 * wave)
            let curl = sin(.pi * bend)
            let travel = pageTravel * (0.60 + 0.40 * edgeWeight)
            let lag = width * 0.070 * bend * (1 - edgeWeight)
            let xTranslation = edgeSign * (travel - lag)
            let fingerInfluence = bend * pow(edgeWeight, 0.72)
            let verticalWave = pull * height * 0.095 * fingerInfluence
            let cornerLift = pull * cornerBias * height * 0.048 * fingerInfluence
            let yLift = -curl * 8 * (0.28 + edgeWeight * 0.72) + verticalWave + cornerLift
            let zLift = curl * width * 0.055 * (0.22 + edgeWeight * 0.78) + abs(pull) * width * 0.035 * fingerInfluence
            let angle = edgeSign * (.pi * 0.34) * bend * (0.25 + edgeWeight * 0.75)
            let twistAngle = pull * (.pi * 0.055) * fingerInfluence

            var transform = CATransform3DIdentity
            transform = CATransform3DTranslate(transform, xTranslation, yLift, zLift)
            transform = CATransform3DRotate(transform, angle, 0, 1, 0)
            transform = CATransform3DRotate(transform, twistAngle, 1, 0, 0)
            strips[i].transform = transform
            strips[i].zPosition = edgeWeight * 100 + bend * 52
            strips[i].shadowOpacity = Float(0.12 * bend * (0.35 + edgeWeight * 0.65))
        }

        let foldX: CGFloat = forward
            ? width - pageTravel
            : pageTravel
        let foldBandWidth = max(46, width * (0.10 + 0.06 * sin(.pi * rawProgress)))
        let shadowBandWidth = max(130, width * (0.24 + 0.10 * sin(.pi * rawProgress)))
        foldHighlight.frame = CGRect(
            x: foldX - foldBandWidth / 2,
            y: 0,
            width: foldBandWidth,
            height: height
        )
        foldHighlight.opacity = Float(min(1.0, (0.18 + sin(.pi * rawProgress) * 0.72) * min(1.0, rawProgress * 1.4)))

        foldShadow.frame = CGRect(
            x: foldX - shadowBandWidth / 2,
            y: 0,
            width: shadowBandWidth,
            height: height
        )
        foldShadow.opacity = Float(min(0.86, (0.20 + sin(.pi * rawProgress) * 0.52) * min(1.0, rawProgress * 1.5)))

        let underWidth = max(150, width * (0.22 + 0.22 * eased))
        let underX: CGFloat = forward ? foldX - underWidth : foldX
        underShadow.frame = CGRect(x: underX, y: 0, width: underWidth, height: height)
        underShadow.opacity = Float(min(0.78, 0.10 + eased * 0.66))
    }

    private func applySheetProgress(progress rawProgress: CGFloat,
                                    eased: CGFloat,
                                    direction: Int,
                                    sheet: CALayer,
                                    width: CGFloat,
                                    height: CGFloat,
                                    pull: CGFloat,
                                    cornerBias: CGFloat,
                                    foldShadow: CAGradientLayer,
                                    foldHighlight: CAGradientLayer,
                                    underShadow: CAGradientLayer) {
        let forward = direction > 0
        let edgeSign: CGFloat = forward ? -1 : 1
        let lift = sin(.pi * rawProgress)
        let edgeTravel = width * 0.94 * eased
        let yPull = pull * height * 0.052 * lift
        let cornerLift = pull * cornerBias * height * 0.028 * lift
        let zLift = width * 0.13 * lift
        let rotationY = edgeSign * (.pi * 0.46) * eased
        let rotationX = pull * (.pi * 0.035) * lift
        let rotationZ = -edgeSign * pull * (.pi * 0.010) * lift

        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, edgeSign * edgeTravel, yPull + cornerLift, zLift)
        transform = CATransform3DRotate(transform, rotationY, 0, 1, 0)
        transform = CATransform3DRotate(transform, rotationX, 1, 0, 0)
        transform = CATransform3DRotate(transform, rotationZ, 0, 0, 1)
        sheet.transform = transform
        sheet.zPosition = 100 + lift * 60
        sheet.shadowOpacity = Float(0.14 * lift + 0.08 * eased)
        sheet.shadowRadius = 16 + 12 * lift
        sheet.shadowOffset = CGSize(width: edgeSign * -8 * lift, height: 2 + 6 * lift)

        let foldX: CGFloat = forward
            ? width - edgeTravel
            : edgeTravel
        let foldBandWidth = max(44, width * (0.085 + 0.035 * lift))
        let shadowBandWidth = max(120, width * (0.22 + 0.08 * lift))
        foldHighlight.frame = CGRect(
            x: foldX - foldBandWidth / 2,
            y: 0,
            width: foldBandWidth,
            height: height
        )
        foldHighlight.opacity = Float(min(1.0, 0.35 + lift * 0.65) * min(1.0, rawProgress * 1.6))

        foldShadow.frame = CGRect(
            x: foldX - shadowBandWidth / 2,
            y: 0,
            width: shadowBandWidth,
            height: height
        )
        foldShadow.opacity = Float((0.28 + 0.42 * lift) * min(1.0, rawProgress * 1.4))

        let underWidth = max(120, width * (0.18 + 0.18 * eased))
        let underX: CGFloat = forward ? foldX - underWidth : foldX
        underShadow.frame = CGRect(x: underX, y: 0, width: underWidth, height: height)
        underShadow.opacity = Float(min(0.75, 0.18 + eased * 0.58))
    }

    private func runManualProgress(from start: CGFloat,
                                   to end: CGFloat,
                                   verticalFrom: CGFloat = 0,
                                   touchY: CGFloat = 0.5,
                                   duration: TimeInterval,
                                   completion: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { completion(); return }
            let startTime = CACurrentMediaTime()
            while true {
                let elapsed = CACurrentMediaTime() - startTime
                let t = min(1.0, elapsed / duration)
                let eased = t * t * (3 - 2 * t)
                let value = start + (end - start) * CGFloat(eased)
                let verticalValue = verticalFrom * (1 - CGFloat(eased))
                if let s = self.session {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.applyCurlProgress(value, direction: s.direction, verticalPull: verticalValue, touchY: touchY)
                    CATransaction.commit()
                }
                if t >= 1.0 { break }
                try? await Task.sleep(nanoseconds: Self.frameStepNanoseconds)
            }
            completion()
        }
    }
}

private extension UIView {
    static func animateAsync(duration: TimeInterval,
                             options: UIView.AnimationOptions = [],
                             animations: @escaping () -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            UIView.animate(withDuration: duration, delay: 0, options: options, animations: animations) { _ in
                cont.resume()
            }
        }
    }
}
