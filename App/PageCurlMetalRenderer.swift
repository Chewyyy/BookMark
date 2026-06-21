import MetalKit
import UIKit

@MainActor
final class MetalPageCurlView: UIView {
    private let metalView: MTKView
    private let renderer: PageCurlMetalRenderer

    init?(frame: CGRect,
          currentImage: UIImage,
          destinationImage: UIImage,
          direction: Int,
          palette: ReaderThemePalette.Palette) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let renderer = PageCurlMetalRenderer(
            device: device,
            currentImage: currentImage,
            destinationImage: destinationImage,
            direction: direction,
            palette: palette
        ) else { return nil }

        self.metalView = MTKView(frame: frame, device: device)
        self.renderer = renderer
        super.init(frame: frame)

        isUserInteractionEnabled = false
        backgroundColor = palette.uiBackgroundColor
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.backgroundColor = palette.uiBackgroundColor
        metalView.clearColor = palette.clearColor
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 120
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.delegate = renderer
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        renderer.viewportSize = frame.size
        renderer.update(progress: 0.001, verticalPull: 0, touchY: 0.5)
        layoutIfNeeded()
        metalView.draw()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(progress: CGFloat, verticalPull: CGFloat, touchY: CGFloat) {
        renderer.update(progress: progress, verticalPull: verticalPull, touchY: touchY)
        metalView.draw()
    }
}

private final class PageCurlMetalRenderer: NSObject, MTKViewDelegate {
    private struct Vertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
        var shade: Float
    }

    private struct Uniforms {
        var opacity: Float
    }

    private struct PageNode {
        let rest: SIMD2<Float>
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var shade: Float
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let currentTexture: MTLTexture
    private let destinationTexture: MTLTexture
    private let direction: Int
    private let columns = 88
    private let rows = 34
    private let physicsStepsPerUpdate = 5

    var viewportSize: CGSize = .zero

    private var targetProgress: Float = 0.001
    private var targetVerticalPull: Float = 0
    private var targetTouchY: Float = 0.5
    private var simulatedProgress: Float = 0.001
    private var progressVelocity: Float = 0
    private var pull: Float = 0
    private var pullVelocity: Float = 0
    private var touchY: Float = 0.5
    private var touchVelocity: Float = 0

    private var nodes: [PageNode] = []
    private var pageVertices: [Vertex] = []
    private var pageIndices: [UInt16] = []
    private var destinationVertices: [Vertex] = []
    private var destinationIndices: [UInt16] = [0, 1, 2, 2, 1, 3]

    init?(device: MTLDevice,
          currentImage: UIImage,
          destinationImage: UIImage,
          direction: Int,
          palette: ReaderThemePalette.Palette) {
        self.device = device
        self.direction = direction >= 0 ? 1 : -1
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue

        let textureLoader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
        ]
        guard let currentCGImage = currentImage.cgImage,
              let destinationCGImage = destinationImage.cgImage,
              let currentTexture = try? textureLoader.newTexture(cgImage: currentCGImage, options: options),
              let destinationTexture = try? textureLoader.newTexture(cgImage: destinationCGImage, options: options) else {
            return nil
        }
        self.currentTexture = currentTexture
        self.destinationTexture = destinationTexture

        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "bookmarkPageCurlVertex"),
              let fragmentFunction = library.makeFunction(name: "bookmarkPageCurlFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.pipelineState = pipelineState

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.samplerState = samplerState

        super.init()
        destinationVertices = [
            Vertex(position: SIMD2<Float>(-1, 1), texCoord: SIMD2<Float>(0, 0), shade: 1),
            Vertex(position: SIMD2<Float>(1, 1), texCoord: SIMD2<Float>(1, 0), shade: 1),
            Vertex(position: SIMD2<Float>(-1, -1), texCoord: SIMD2<Float>(0, 1), shade: 1),
            Vertex(position: SIMD2<Float>(1, -1), texCoord: SIMD2<Float>(1, 1), shade: 1),
        ]
        buildRestMesh()
        rebuildIndexBuffer()
        rebuildRenderVertices()
    }

    func update(progress: CGFloat, verticalPull: CGFloat, touchY: CGFloat) {
        targetProgress = max(0.001, min(1, Float(progress)))
        targetVerticalPull = max(-1, min(1, Float(verticalPull)))
        targetTouchY = max(0, min(1, Float(touchY)))
        for _ in 0..<physicsStepsPerUpdate {
            stepPhysics(dt: 1 / 120)
        }
        rebuildRenderVertices()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = size
        rebuildRenderVertices()
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        draw(vertices: destinationVertices, indices: destinationIndices, texture: destinationTexture, opacity: 1, encoder: encoder)
        draw(vertices: pageVertices, indices: pageIndices, texture: currentTexture, opacity: Float(1 - max(0, simulatedProgress - 0.94) / 0.06), encoder: encoder)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func draw(vertices: [Vertex],
                      indices: [UInt16],
                      texture: MTLTexture,
                      opacity: Float,
                      encoder: MTLRenderCommandEncoder) {
        guard !vertices.isEmpty, !indices.isEmpty else { return }
        guard let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: MemoryLayout<UInt16>.stride * indices.count
        ) else { return }
        var uniforms = Uniforms(opacity: opacity)
        encoder.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indices.count,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    private func buildRestMesh() {
        nodes.removeAll(keepingCapacity: true)
        nodes.reserveCapacity((columns + 1) * (rows + 1))
        for row in 0...rows {
            let y = Float(row) / Float(rows)
            for column in 0...columns {
                let x = Float(column) / Float(columns)
                let rest = SIMD2<Float>(x, y)
                nodes.append(PageNode(rest: rest, position: rest, velocity: .zero, shade: 1))
            }
        }
    }

    private func rebuildIndexBuffer() {
        pageIndices.removeAll(keepingCapacity: true)
        pageIndices.reserveCapacity(columns * rows * 6)
        for row in 0..<rows {
            for column in 0..<columns {
                let topLeft = UInt16(row * (columns + 1) + column)
                let topRight = UInt16(row * (columns + 1) + column + 1)
                let bottomLeft = UInt16((row + 1) * (columns + 1) + column)
                let bottomRight = UInt16((row + 1) * (columns + 1) + column + 1)
                pageIndices.append(contentsOf: [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight])
            }
        }
    }

    private func stepPhysics(dt: Float) {
        let progressSpring = springStep(
            value: simulatedProgress,
            velocity: progressVelocity,
            target: targetProgress,
            stiffness: 58,
            damping: 15,
            dt: dt
        )
        simulatedProgress = progressSpring.value
        progressVelocity = progressSpring.velocity

        let pullSpring = springStep(
            value: pull,
            velocity: pullVelocity,
            target: targetVerticalPull,
            stiffness: 42,
            damping: 13,
            dt: dt
        )
        pull = pullSpring.value
        pullVelocity = pullSpring.velocity

        let touchSpring = springStep(
            value: touchY,
            velocity: touchVelocity,
            target: targetTouchY,
            stiffness: 38,
            damping: 12,
            dt: dt
        )
        touchY = touchSpring.value
        touchVelocity = touchSpring.velocity

        var targetPositions = Array(repeating: SIMD2<Float>.zero, count: nodes.count)
        var targetShades = Array(repeating: Float(1), count: nodes.count)
        for index in nodes.indices {
            let solved = targetNode(for: nodes[index].rest)
            targetPositions[index] = solved.position
            targetShades[index] = solved.shade
        }

        for index in nodes.indices {
            var target = targetPositions[index]
            let column = index % (columns + 1)
            let row = index / (columns + 1)
            if column > 0 { target += (targetPositions[index - 1] - target) * 0.045 }
            if column < columns { target += (targetPositions[index + 1] - target) * 0.045 }
            if row > 0 { target += (targetPositions[index - (columns + 1)] - target) * 0.018 }
            if row < rows { target += (targetPositions[index + columns + 1] - target) * 0.018 }

            let displacement = target - nodes[index].position
            nodes[index].velocity += displacement * (dt * 78)
            nodes[index].velocity *= 0.72
            nodes[index].position += nodes[index].velocity * dt
            nodes[index].shade += (targetShades[index] - nodes[index].shade) * 0.45
        }
    }

    private func targetNode(for rest: SIMD2<Float>) -> (position: SIMD2<Float>, shade: Float) {
        let forward = direction > 0
        let canonicalX = forward ? rest.x : 1 - rest.x
        let canonicalY = rest.y
        let p = max(0.001, min(1, simulatedProgress))
        let eased = p * p * (3 - 2 * p)

        let foldX = 1 - eased * 1.04
        let foldDistance = canonicalX - foldX
        let curlWidth = max(0.14, min(0.50, 0.18 + eased * 0.34))
        let curlAmount = max(0, min(1, foldDistance / curlWidth))

        var pageX = canonicalX
        var pageY = canonicalY
        var lift: Float = 0
        var shade: Float = 1

        if foldDistance > 0 {
            let theta = curlAmount * .pi
            let sine = sin(theta)
            let rolled = 1 - cos(theta)
            let sheetBack = curlAmount * curlAmount * (3 - 2 * curlAmount)
            pageX = foldX - rolled * curlWidth * 0.62 - sheetBack * curlWidth * 0.18
            lift = sine * (0.13 + 0.12 * p)
            pageY += pull * sine * 0.11
            pageY += (canonicalY - touchY) * sine * 0.052
            pageY += pull * (touchY - 0.5) * sheetBack * 0.052
            let crease = exp(-pow((canonicalX - foldX) * 30, 2)) * p
            shade = max(0.42, min(1.24, 1 - sheetBack * p * 0.42 + crease * 0.34 + sine * p * 0.14))
        } else {
            let crease = exp(-pow((canonicalX - foldX) * 24, 2)) * p
            shade = max(0.68, min(1.12, 1 - crease * 0.12))
        }

        let perspective = 1 / (1 + lift * 0.78)
        pageX = 0.5 + (pageX - 0.5) * perspective
        pageY = 0.5 + (pageY - 0.5) * perspective
        let actualX = forward ? pageX : 1 - pageX
        return (SIMD2<Float>(actualX, pageY), shade)
    }

    private func rebuildRenderVertices() {
        pageVertices.removeAll(keepingCapacity: true)
        pageVertices.reserveCapacity(nodes.count)
        for node in nodes {
            let ndcX = node.position.x * 2 - 1
            let ndcY = 1 - node.position.y * 2
            pageVertices.append(
                Vertex(
                    position: SIMD2<Float>(ndcX, ndcY),
                    texCoord: node.rest,
                    shade: node.shade
                )
            )
        }
    }

    private func springStep(value: Float,
                            velocity: Float,
                            target: Float,
                            stiffness: Float,
                            damping: Float,
                            dt: Float) -> (value: Float, velocity: Float) {
        var newVelocity = velocity + (target - value) * stiffness * dt
        newVelocity *= exp(-damping * dt)
        return (value + newVelocity * dt, newVelocity)
    }
}

private extension ReaderThemePalette.Palette {
    var clearColor: MTLClearColor {
        MTLClearColor(
            red: Double(channel(bg, 16)),
            green: Double(channel(bg, 8)),
            blue: Double(channel(bg, 0)),
            alpha: 1
        )
    }
}
