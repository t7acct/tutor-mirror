import AppKit
import Metal
import QuartzCore
import CoreVideo
import CoreImage
import os

/// Shows the iPad stream with as little delay as possible.
///
/// - Draws each frame the moment it is decoded (no frame queue, no waiting
///   for the main thread). If frames pile up after a Wi-Fi hiccup, only the
///   newest one is drawn.
/// - Reads the decoder's YUV planes straight from GPU memory (IOSurface →
///   Metal texture, zero copies) and converts to RGB in the shader.
/// - Asks for the screen's full refresh rate (120 Hz on ProMotion / 120 Hz
///   monitors) so a new frame waits at most ~8 ms for the next refresh.
final class MetalVideoView: NSView, FrameSink, @unchecked Sendable {
    private let logger = Logger(subsystem: "local.tutormirror", category: "Render")

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let renderQueue = DispatchQueue(label: "local.tutormirror.render", qos: .userInteractive)

    // Latest-frame mailbox, guarded by `lock`.
    private let lock = NSLock()
    private var pending: (CVPixelBuffer, FrameTiming)?
    private var renderScheduled = false
    private var lastFrame: CVPixelBuffer?
    private var drawableSize = CGSize(width: 1, height: 1)

    // Freeze: while frozen the picture on screen stays put, but decoding keeps
    // running and the newest frame is kept here, so going live again is instant
    // (no waiting for the iPad to send a fresh keyframe).
    private var frozen = false
    private var newestWhileFrozen: CVPixelBuffer?
    private var streamEndedWhileFrozen = false

    // Crop and zoom, guarded by `lock`. Both are expressed as the part of the
    // full picture to show, in texture coordinates (0…1, top-left origin), so
    // the shader just samples a smaller rectangle and costs nothing extra.
    private var crop = CropInsets.none
    private var zoomRect: CGRect?          // nil = not zoomed (whole crop)
    private var videoSize = CGSize.zero    // full stream size in pixels

    /// Called on the main thread when the shown picture's size changes
    /// (stream size after cropping).
    var onVideoSizeChange: ((CGSize) -> Void)?
    /// Called on the main thread after crop or zoom changes.
    var onViewportChange: (() -> Void)?
    private var lastReportedSize = CGSize.zero

    private var displayLink: CADisplayLink?

    init?(videoFrame frame: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vtx")
            desc.fragmentFunction = lib.makeFunction(name: "frag")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            Logger(subsystem: "local.tutormirror", category: "Render").error("Metal setup failed: \(error)")
            return nil
        }
        super.init(frame: frame)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.isOpaque = true
        l.backgroundColor = NSColor.black.cgColor
        l.maximumDrawableCount = 3
        l.allowsNextDrawableTimeout = true
        l.presentsWithTransaction = false
        l.displaySyncEnabled = true
        l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return l
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // MARK: - Size / refresh rate

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        updateDrawableSize()
        // An idle display link that asks for 120 Hz keeps ProMotion panels at
        // their top refresh rate while mirroring, instead of dropping to 60.
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {}

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metalLayer.drawableSize = size
        CATransaction.commit()
        lock.lock()
        let changed = size != drawableSize
        drawableSize = size
        let frame = lastFrame
        lock.unlock()
        // Redraw the last picture at the new size (window resize, freeze).
        if changed, let frame { renderQueue.async { self.render(frame, timing: nil) } }
    }

    // MARK: - FrameSink (decode thread)

    func display(_ pixelBuffer: CVPixelBuffer, timing: FrameTiming) {
        lock.lock()
        if frozen {
            newestWhileFrozen = pixelBuffer
            streamEndedWhileFrozen = false
            lock.unlock()
            return
        }
        if pending != nil { LatencyStats.shared.frameSkipped() }   // replaced before it was drawn
        pending = (pixelBuffer, timing)
        let schedule = !renderScheduled
        renderScheduled = true
        lock.unlock()
        if schedule { renderQueue.async { self.drainMailbox() } }
    }

    func streamReset() {
        lock.lock()
        pending = nil
        newestWhileFrozen = nil
        let isFrozen = frozen
        if isFrozen {
            // Keep showing the frozen picture even if the iPad disconnects,
            // rotates or locks — you can tidy up on the iPad freely.
            streamEndedWhileFrozen = true
        } else {
            lastFrame = nil
        }
        lock.unlock()
        if !isFrozen { renderQueue.async { self.clear() } }
    }

    var isFrozen: Bool {
        lock.lock(); defer { lock.unlock() }
        return frozen
    }

    func setFrozen(_ freeze: Bool) {
        lock.lock()
        guard freeze != frozen else { lock.unlock(); return }
        frozen = freeze
        var resume: CVPixelBuffer?
        var clearScreen = false
        if !freeze {
            resume = newestWhileFrozen
            clearScreen = resume == nil && streamEndedWhileFrozen
            if clearScreen { lastFrame = nil }
            newestWhileFrozen = nil
            streamEndedWhileFrozen = false
        }
        lock.unlock()
        if let resume {
            renderQueue.async { self.render(resume, timing: nil) }
        } else if clearScreen {
            renderQueue.async { self.clear() }
        }
    }

    // MARK: - Crop / zoom (main thread)

    private var cropRect: CGRect {
        CGRect(x: crop.left, y: crop.top, width: 1 - crop.left - crop.right, height: 1 - crop.top - crop.bottom)
    }

    /// The part of the full picture currently shown, in texture coordinates.
    private var visibleRectLocked: CGRect { zoomRect ?? cropRect }

    func setCrop(_ insets: CropInsets) {
        lock.lock()
        crop = insets.clamped
        zoomRect = nil
        lock.unlock()
        redrawLast(resetSize: true)
    }

    var zoomScale: Double {
        lock.lock(); defer { lock.unlock() }
        guard let z = zoomRect else { return 1 }
        return cropRect.width / z.width
    }

    /// The shown picture's size in pixels after cropping.
    var croppedVideoSize: CGSize {
        lock.lock(); defer { lock.unlock() }
        return CGSize(width: videoSize.width * cropRect.width, height: videoSize.height * cropRect.height)
    }

    /// Where the picture sits inside this view, in view points.
    var contentRect: CGRect {
        let size = croppedVideoSize
        guard size.width > 0, size.height > 0 else { return bounds }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// Zoom by `factor` keeping the picture under `point` (0…1 of the
    /// content area, top-left origin) where it is.
    func zoom(by factor: Double, around point: CGPoint) {
        lock.lock()
        let crop = cropRect
        let v = visibleRectLocked
        let scale = min(max(crop.width / v.width * factor, 1), 8)
        if scale <= 1.001 {
            zoomRect = nil
        } else {
            let w = crop.width / scale, h = crop.height / scale
            let anchor = CGPoint(x: v.minX + point.x * v.width, y: v.minY + point.y * v.height)
            zoomRect = clampToCrop(CGRect(x: anchor.x - point.x * w, y: anchor.y - point.y * h, width: w, height: h))
        }
        lock.unlock()
        redrawLast(resetSize: false)
    }

    /// Move the zoomed-in picture by a fraction of the content area.
    func pan(by delta: CGSize) {
        lock.lock()
        guard let v = zoomRect else { lock.unlock(); return }
        zoomRect = clampToCrop(v.offsetBy(dx: -delta.width * v.width, dy: -delta.height * v.height))
        lock.unlock()
        redrawLast(resetSize: false)
    }

    func resetZoom() {
        lock.lock()
        let wasZoomed = zoomRect != nil
        zoomRect = nil
        lock.unlock()
        if wasZoomed { redrawLast(resetSize: false) }
    }

    private func clampToCrop(_ r: CGRect) -> CGRect {
        let c = cropRect
        var r = r
        r.origin.x = min(max(r.minX, c.minX), c.maxX - r.width)
        r.origin.y = min(max(r.minY, c.minY), c.maxY - r.height)
        return r
    }

    private func redrawLast(resetSize: Bool) {
        renderQueue.async {
            if resetSize { self.lastReportedSize = .zero }
            self.lock.lock(); let frame = self.lastFrame; self.lock.unlock()
            if let frame { self.render(frame, timing: nil) }
            DispatchQueue.main.async { self.onViewportChange?() }
        }
    }

    /// The picture as the student sees it right now (cropped and zoomed),
    /// for saving or copying. Annotations are added by the caller.
    func snapshot() -> CGImage? {
        lock.lock()
        let frame = lastFrame
        let v = visibleRectLocked
        lock.unlock()
        guard let frame else { return nil }
        let image = CIImage(cvPixelBuffer: frame)
        let w = image.extent.width, h = image.extent.height
        // Core Image's origin is bottom-left.
        let rect = CGRect(x: v.minX * w, y: (1 - v.maxY) * h, width: v.width * w, height: v.height * h).integral
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        return ctx.createCGImage(image.cropped(to: rect), from: rect)
    }

    private func drainMailbox() {
        lock.lock()
        let item = pending
        pending = nil
        renderScheduled = false
        lock.unlock()
        guard let (pb, timing) = item else { return }
        render(pb, timing: timing)
    }

    // MARK: - Rendering (render queue)

    private func render(_ pb: CVPixelBuffer, timing: FrameTiming?) {
        if timing != nil {
            // A live frame that was already queued when freeze was pressed.
            lock.lock()
            if frozen { newestWhileFrozen = pb; lock.unlock(); return }
            lock.unlock()
        }
        guard let cache = textureCache,
              CVPixelBufferGetPlaneCount(pb) >= 2,
              let yTex = makeTexture(pb, plane: 0, format: .r8Unorm, cache: cache),
              let cTex = makeTexture(pb, plane: 1, format: .rg8Unorm, cache: cache) else { return }

        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)

        lock.lock()
        lastFrame = pb
        videoSize = CGSize(width: w, height: h)
        let target = drawableSize
        let visible = visibleRectLocked
        let shown = CGSize(width: Double(w) * cropRect.width, height: Double(h) * cropRect.height)
        lock.unlock()
        reportVideoSize(shown)

        guard let drawable = metalLayer.nextDrawable(),
              let cmd = commandQueue.makeCommandBuffer(),
              encode(cmd, pb, yTex, cTex, into: drawable.texture, target: target, shown: shown, visible: visible) else { return }

        if let timing {
            drawable.addPresentedHandler { d in
                if d.presentedTime > 0 {
                    LatencyStats.shared.framePresented(timing, presentedAt: d.presentedTime)
                }
            }
        }
        // Keep the CVMetalTextures (and so the IOSurface) alive until the GPU is done.
        cmd.addCompletedHandler { _ in _ = (yTex, cTex) }
        cmd.present(drawable)
        cmd.commit()
    }

    private func encode(_ cmd: MTLCommandBuffer, _ pb: CVPixelBuffer, _ yTex: CVMetalTexture, _ cTex: CVMetalTexture,
                        into texture: MTLTexture, target: CGSize, shown: CGSize, visible: CGRect) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setViewport(Self.aspectFit(video: shown, in: target))
        enc.setFragmentTexture(CVMetalTextureGetTexture(yTex), index: 0)
        enc.setFragmentTexture(CVMetalTextureGetTexture(cTex), index: 1)
        var params = Self.colorParams(for: pb)
        enc.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        var uvRect = SIMD4<Float>(Float(visible.minX), Float(visible.minY), Float(visible.width), Float(visible.height))
        enc.setFragmentBytes(&uvRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return true
    }

    /// Draws the current picture (with crop and zoom) into an off-screen
    /// image through the same shader as the screen. For the `ui` self-check.
    func renderOffscreen(size: CGSize) -> CGImage? {
        renderQueue.sync {
            lock.lock()
            let frame = lastFrame
            let visible = visibleRectLocked
            let shown = CGSize(width: videoSize.width * cropRect.width, height: videoSize.height * cropRect.height)
            lock.unlock()
            guard let frame, let cache = textureCache,
                  let yTex = makeTexture(frame, plane: 0, format: .r8Unorm, cache: cache),
                  let cTex = makeTexture(frame, plane: 1, format: .rg8Unorm, cache: cache) else { return nil }
            let w = Int(size.width), h = Int(size.height)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget]
            desc.storageMode = .managed
            guard let tex = device.makeTexture(descriptor: desc), let cmd = commandQueue.makeCommandBuffer(),
                  encode(cmd, frame, yTex, cTex, into: tex, target: size, shown: shown, visible: visible) else { return nil }
            let blit = cmd.makeBlitCommandEncoder()
            blit?.synchronize(resource: tex)
            blit?.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    private func clear() {
        guard let drawable = metalLayer.nextDrawable(), let cmd = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func makeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
        var tex: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        let st = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, plane, &tex)
        return st == kCVReturnSuccess ? tex : nil
    }

    private func reportVideoSize(_ size: CGSize) {
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        DispatchQueue.main.async { self.onVideoSizeChange?(size) }
    }

    static func aspectFit(video: CGSize, in target: CGSize) -> MTLViewport {
        guard video.width > 0, video.height > 0 else {
            return MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1)
        }
        let s = min(target.width / video.width, target.height / video.height)
        let w = (video.width * s).rounded(), h = (video.height * s).rounded()
        return MTLViewport(originX: Double((target.width - w) / 2).rounded(), originY: Double((target.height - h) / 2).rounded(),
                           width: Double(w), height: Double(h), znear: 0, zfar: 1)
    }

    // MARK: - Color conversion

    struct ColorParams {
        var yOffset: Float
        var yScale: Float
        var cScale: Float
        var r_v: Float, g_u: Float, g_v: Float, b_u: Float
    }

    static func colorParams(for pb: CVPixelBuffer) -> ColorParams {
        let full = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        // BT.709 unless the stream says BT.601.
        let is601 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        let (kr, kb): (Float, Float) = is601 ? (0.299, 0.114) : (0.2126, 0.0722)
        let kg = 1 - kr - kb
        return ColorParams(
            yOffset: full ? 0 : 16.0 / 255.0,
            yScale: full ? 1 : 255.0 / 219.0,
            cScale: full ? 1 : 255.0 / 224.0,
            r_v: 2 * (1 - kr),
            g_u: -2 * kb * (1 - kb) / kg,
            g_v: -2 * kr * (1 - kr) / kg,
            b_u: 2 * (1 - kb))
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };

    // One oversized triangle covering the viewport.
    vertex VOut vtx(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    struct ColorParams { float yOffset; float yScale; float cScale; float r_v; float g_u; float g_v; float b_u; };

    fragment float4 frag(VOut in [[stage_in]],
                         texture2d<float> yTex [[texture(0)]],
                         texture2d<float> cTex [[texture(1)]],
                         constant ColorParams& p [[buffer(0)]],
                         constant float4& uvRect [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        // uvRect: the part of the picture shown (crop / zoom).
        float2 uv = uvRect.xy + in.uv * uvRect.zw;
        float y = (yTex.sample(s, uv).r - p.yOffset) * p.yScale;
        float2 c = (cTex.sample(s, uv).rg - 0.5) * p.cScale;
        float3 rgb = float3(y + p.r_v * c.y,
                            y + p.g_u * c.x + p.g_v * c.y,
                            y + p.b_u * c.x);
        return float4(saturate(rgb), 1.0);
    }
    """
}
