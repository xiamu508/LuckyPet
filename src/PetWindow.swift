import Cocoa
import AVFoundation

/// 桌宠主窗口：透明、无边框、置顶，自行处理拖动与抛掷物理。
@MainActor
final class PetWindow: NSWindow {

    /// 每个播放槽都有自己的播放器和图层。切换素材时先在闲置槽解码首帧，再做短交叉淡化，
    /// 这样旧动作的最后一帧会一直垫在下面，不会因为 removeAllItems() 暴露透明空帧。
    private final class PlaybackSlot {
        let player: AVQueuePlayer
        let layer: AVPlayerLayer
        var looper: AVPlayerLooper?
        var endObserver: NSObjectProtocol?
        var url: URL?
        var loop = false
        var rate: Float = 1.0
        var generation = 0

        init(layer: AVPlayerLayer) {
            player = AVQueuePlayer()
            self.layer = layer
            layer.player = player
            player.actionAtItemEnd = .none
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
        }
    }

    // 几何使用 640×360 逻辑画布；视频分辨率可独立提高，角色显示大小保持稳定。
    static let sourceWidth: CGFloat = 640
    static let sourceHeight: CGFloat = 360
    static let bubbleWidth: CGFloat = 308
    /// 播放画布四周保留透明余量，避免动作贴边时被窗口边界视觉上截住。
    static let playbackInset: CGFloat = 20
    /// 顶部气泡区固定保留，避免显示/隐藏气泡时改变 WindowServer 窗口尺寸。
    static let bubbleArea: CGFloat = 280
    private static let bubbleGap: CGFloat = 10
    private static let bubbleMargin: CGFloat = 12

    private let videoHost = PetVideoView(frame: .zero)
    private lazy var playbackSlots: [PlaybackSlot] = [
        PlaybackSlot(layer: videoHost.playerLayer),
        PlaybackSlot(layer: videoHost.transitionPlayerLayer)
    ]
    private var activeSlotIndex = 0
    private var hitSlotIndex = 0
    private var activeSlot: PlaybackSlot { playbackSlots[activeSlotIndex] }
    private var inactiveSlot: PlaybackSlot { playbackSlots[1 - activeSlotIndex] }
    private var player: AVQueuePlayer { activeSlot.player }
    private var playerLayer: AVPlayerLayer { activeSlot.layer }
    private var currentURL: URL? { activeSlot.url }
    private var currentLoop: Bool { activeSlot.loop }
    private var currentRate: Float { activeSlot.rate }
    private var transitionTimer: Timer?
    private var transitionStartedAt: CFTimeInterval?
    private var transitionTargetIndex: Int?
    private var transitionToken = 0
    private let transitionDuration: CFTimeInterval = 0.18
    private let hitOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ])
    private weak var hitOutputItem: AVPlayerItem?
    private var hitPixelBuffer: CVPixelBuffer?
    private var pointerTimer: Timer?
    private var pointerIsDown = false
    private let isRenderTest = ProcessInfo.processInfo.environment["PET_RENDER_TEST_DIR"] != nil
    private let restingSourceBounds: NSRect

    private(set) var state: String = "idle"

    var library: ClipLibrary
    var prefs: Preferences

    // 交互
    private var mouseDownScreen: NSPoint = .zero
    private var windowOriginAtDown: NSPoint = .zero
    private var lastDragSamples: [(t: TimeInterval, p: NSPoint)] = []
    private var didDrag = false

    // 物理
    private var physicsTimer: Timer?
    private var velocity: NSPoint = .zero
    private var lastPhysicsTick: TimeInterval = 0

    // 气泡（内嵌于本窗口，避免多窗口合成问题）
    private var bubbleOverlay: BubbleOverlayView?
    private var bubbleHeight: CGFloat = 0
    private var bubbleText: String?
    private var bubbleEmphasized = false
    private var bubbleHideTimer: Timer?

    // 提醒动效：临时改变窗口几何，不改写用户保存的 petScale 和位置。
    private enum ReminderPhase {
        case intro
        case playing
        case outro
    }

    private var reminderDisplayScale: CGFloat?
    private var reminderAnimationTimer: Timer?
    private var reminderPhase: ReminderPhase?
    private var reminderAnimationStartedAt: CFTimeInterval?
    private var reminderAnimationStartFrame: NSRect?
    private var reminderAnimationStartScale: CGFloat?
    private var reminderAnimationFinished = false
    private var reminderOriginalFrame: NSRect?
    private var reminderOriginalBodyCenter: NSPoint?
    private var reminderOriginalScale: CGFloat?
    private var reminderTargetFrame: NSRect?
    private var reminderTargetScale: CGFloat = 0

    private var displayScale: CGFloat { reminderDisplayScale ?? CGFloat(prefs.petScale) }

    var isBubbleVisible: Bool { bubbleHeight > 0 }
    var isReminderActive: Bool { reminderOriginalFrame != nil }

    // 回调
    var onClicked: ((NSPoint) -> Void)?
    var onRightClicked: ((NSPoint) -> Void)?
    var onStateChanged: ((String) -> Void)?

    var bodySize: NSSize {
        NSSize(width: Self.sourceWidth * displayScale,
               height: Self.sourceHeight * displayScale)
    }

    /// 放置位置以待机轮廓为准，允许画布中的透明留白越过屏幕边缘。
    var visiblePetFrame: NSRect {
        let s = displayScale
        let videoOrigin = playbackOrigin(for: s)
        return NSRect(x: frame.minX + videoOrigin.x + restingSourceBounds.minX * s,
                      y: frame.minY + videoOrigin.y + restingSourceBounds.minY * s,
                      width: restingSourceBounds.width * s, height: restingSourceBounds.height * s)
    }

    private func playbackOrigin(for scale: CGFloat) -> NSPoint {
        NSPoint(x: Self.playbackInset * scale, y: Self.playbackInset * scale)
    }

    private func animationFrameInWindow(for scale: CGFloat) -> NSRect {
        let fallback = NSRect(x: 0, y: 0, width: Self.sourceWidth, height: Self.sourceHeight)
        let sourceBounds = library.animationBounds(for: currentURL) ?? fallback
        let origin = playbackOrigin(for: scale)
        return NSRect(x: origin.x + sourceBounds.minX * scale,
                      y: origin.y + sourceBounds.minY * scale,
                      width: sourceBounds.width * scale,
                      height: sourceBounds.height * scale)
    }

    private var placementScreen: NSScreen? {
        let center = NSPoint(x: visiblePetFrame.midX, y: visiblePetFrame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? screen ?? NSScreen.main
    }

    private static func measureRestingBounds(library: ClipLibrary) -> NSRect {
        let fallback = NSRect(x: 190, y: 20, width: 260, height: 300)
        guard let url = library.idle.clips.first else { return fallback }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = NSSize(width: sourceWidth, height: sourceHeight)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var bounds: NSRect?
        // 合并待机动画不同姿态的轮廓，靠边后呼吸和轻微摇摆不会改变窗口位置。
        for seconds in [0.0, 2.5, 5.0, 7.5] {
            guard let image = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                                       actualTime: nil) else { continue }
            let width = image.width, height = image.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                                  CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { continue }
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 12 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { continue }
            let rect = NSRect(x: CGFloat(minX) / CGFloat(width) * sourceWidth,
                              y: CGFloat(height - maxY - 1) / CGFloat(height) * sourceHeight,
                              width: CGFloat(maxX - minX + 1) / CGFloat(width) * sourceWidth,
                              height: CGFloat(maxY - minY + 1) / CGFloat(height) * sourceHeight)
            bounds = bounds.map { $0.union(rect) } ?? rect
        }
        return bounds?.insetBy(dx: -2, dy: -2) ?? fallback
    }

    init(library: ClipLibrary, prefs: Preferences) {
        self.library = library
        self.prefs = prefs
        self.restingSourceBounds = Self.measureRestingBounds(library: library)
        let initialScale = CGFloat(prefs.petScale)
        let initialCanvasWidth = Self.sourceWidth + Self.playbackInset * 2
        let initialCanvasHeight = Self.sourceHeight + Self.playbackInset * 2
        let w = initialCanvasWidth * initialScale
        let h = initialCanvasHeight * initialScale + Self.bubbleArea
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = prefs.alwaysOnTop ? .statusBar : .normal
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true

        let container = PetContentView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        _ = playbackSlots
        playbackSlots[activeSlotIndex].layer.opacity = 1
        container.addSubview(videoHost)
        contentView = container

        let ov = BubbleOverlayView(frame: .zero)
        container.addSubview(ov)
        bubbleOverlay = ov

        applyGeometry()
        hitOutput.suppressesPlayerRendering = false
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePointerHitTesting() }
        }
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - 几何

    private func frameSize(for scale: CGFloat) -> NSSize {
        let canvasWidth = Self.sourceWidth + Self.playbackInset * 2
        let canvasHeight = Self.sourceHeight + Self.playbackInset * 2
        return NSSize(width: canvasWidth * scale,
                      height: canvasHeight * scale + Self.bubbleArea)
    }

    /// 以角色轮廓中心为锚点计算窗口位置，并保证整个窗口仍落在屏幕可见区域内。
    private func frameOrigin(for scale: CGFloat, bodyCenter: NSPoint, on screen: NSScreen) -> NSPoint {
        let size = frameSize(for: scale)
        let visible = screen.visibleFrame
        let videoOrigin = playbackOrigin(for: scale)
        let desired = NSPoint(x: bodyCenter.x - videoOrigin.x - restingSourceBounds.midX * scale,
                               y: bodyCenter.y - videoOrigin.y - restingSourceBounds.midY * scale)
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return NSPoint(x: min(max(desired.x, visible.minX), maxX),
                       y: min(max(desired.y, visible.minY), maxY))
    }

    private func setWindowGeometry(frame targetFrame: NSRect, scale: CGFloat) {
        setFrame(targetFrame, display: true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutVideoLayers(scale: scale)
        CATransaction.commit()

        if isBubbleVisible { layoutBubble() }
    }

    /// 窗口容纳完整 640×360 动画画布，头顶另留气泡区；不裁剪动作和特效。
    func applyGeometry() {
        let s = displayScale
        let size = frameSize(for: s)
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY)
        setWindowGeometry(frame: NSRect(origin: origin, size: size), scale: s)
        if isVisible && !isReminderActive { keepFullyOnScreen() }
    }

    private func layoutVideoLayers(scale: CGFloat) {
        let origin = playbackOrigin(for: scale)
        let canvasW = Self.sourceWidth * scale
        let canvasH = Self.sourceHeight * scale
        videoHost.frame = NSRect(x: origin.x, y: origin.y, width: canvasW, height: canvasH)
        for slot in playbackSlots {
            slot.layer.frame = videoHost.bounds
        }
        videoHost.updateBackingScale()
    }

    /// 透明区域穿透桌面，只在当帧实际可见的像素或提醒气泡上接收鼠标。
    private func refreshHitPixels() {
        let hitPlayer = playbackSlots[hitSlotIndex].player
        if hitPlayer.currentItem !== hitOutputItem {
            hitOutputItem?.remove(hitOutput)
            hitOutputItem = hitPlayer.currentItem
            hitOutputItem?.add(hitOutput)
            hitPixelBuffer = nil
        }
        let time = hitOutput.itemTime(forHostTime: CACurrentMediaTime())
        if hitOutput.hasNewPixelBuffer(forItemTime: time),
           let buffer = hitOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            hitPixelBuffer = buffer
        }
    }

    private func isVisiblePixel(at point: NSPoint) -> Bool {
        if isBubbleVisible, bubbleOverlay?.frame.contains(point) == true { return true }
        guard videoHost.frame.contains(point) else { return false }
        guard let pixel = hitPixelBuffer else {
            // 解码器尚未输出首帧时，只允许角色中心区域交互。
            let s = displayScale
            let local = videoHost.convert(point, from: nil)
            return NSRect(x: (Self.sourceWidth - 240) * s / 2, y: 20 * s,
                          width: 240 * s, height: 300 * s).contains(local)
        }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        let local = videoHost.convert(point, from: nil)
        let x = min(width - 1, max(0, Int(local.x / videoHost.bounds.width * CGFloat(width))))
        let y = min(height - 1, max(0, Int((1 - local.y / videoHost.bounds.height) * CGFloat(height))))
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { return false }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return bytes[y * CVPixelBufferGetBytesPerRow(pixel) + x * 4 + 3] > 12
    }

    private func updatePointerHitTesting() {
        guard isVisible else { ignoresMouseEvents = true; return }
        if playbackSlots[hitSlotIndex].player.currentItem !== hitOutputItem { refreshHitPixels() }
        guard !isRenderTest else { ignoresMouseEvents = true; return }
        guard !isReminderActive else { ignoresMouseEvents = true; return }
        guard !pointerIsDown else { ignoresMouseEvents = false; return }
        let point = mouseLocationOutsideOfEventStream
        guard contentView?.bounds.contains(point) == true else { ignoresMouseEvents = true; return }
        refreshHitPixels()
        ignoresMouseEvents = !isVisiblePixel(at: point)
    }

    private func constrainedOrigin(_ origin: NSPoint, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let body = visiblePetFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let minX = visible.minX - body.minX, maxX = visible.maxX - body.maxX
        let minY = visible.minY - body.minY, maxY = visible.maxY - body.maxY
        return NSPoint(x: min(max(origin.x, minX), max(minX, maxX)),
                       y: min(max(origin.y, minY), max(minY, maxY)))
    }

    func keepFullyOnScreen() {
        guard !isReminderActive else { return }
        guard let target = placementScreen else { return }
        let visible = target.visibleFrame
        if frame.width > visible.width || frame.height > visible.height {
            let canvasWidth = Self.sourceWidth + Self.playbackInset * 2
            let canvasHeight = Self.sourceHeight + Self.playbackInset * 2
            let fit = min(visible.width / canvasWidth,
                          max(1, visible.height - Self.bubbleArea) / canvasHeight)
            applyScale(fit)
            return
        }
        let origin = constrainedOrigin(frame.origin, on: target)
        let density = backingScaleFactor
        setFrameOrigin(NSPoint(x: (origin.x * density).rounded() / density,
                               y: (origin.y * density).rounded() / density))
        layoutBubble()
    }

    private func layoutBubble() {
        guard let overlay = bubbleOverlay, let text = bubbleText,
              let screen = placementScreen, let content = contentView else { return }
        let visible = screen.visibleFrame.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(content.bounds)
        guard visible.width > Self.bubbleMargin * 2, visible.height > Self.bubbleMargin * 2 else { return }
        let available = visible.insetBy(dx: Self.bubbleMargin, dy: Self.bubbleMargin)
        // 小桌宠也保留可读宽度，避免字体不变而气泡越缩越窄。
        var width = min(max(260, Self.bubbleWidth * displayScale), available.width)
        var height = overlay.update(text: text, emphasized: bubbleEmphasized, cardWidth: width)
        if height > available.height, width < available.width {
            width = available.width
            height = overlay.update(text: text, emphasized: bubbleEmphasized, cardWidth: width)
        }
        let animationFrame = animationFrameInWindow(for: displayScale)
        let normalX = animationFrame.midX - width / 2
        let x = min(max(normalX, available.minX), max(available.minX, available.maxX - width))
        // 气泡始终放在当前动画的安全 alpha 边界之外，避免遮住头顶特效。
        let above = animationFrame.maxY + Self.bubbleGap
        let bandMinY = max(animationFrame.maxY + Self.bubbleGap, available.minY)
        let bandMaxY = min(content.bounds.maxY - Self.bubbleMargin, available.maxY)
        let maxY = max(bandMinY, bandMaxY - height)
        let y = min(max(above, bandMinY), maxY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = NSRect(x: x, y: y, width: width, height: height)
        CATransaction.commit()
        bubbleHeight = height
    }

    // MARK: - 气泡

    private func keepBubbleFullyOnScreen() {
        guard isBubbleVisible, let overlay = bubbleOverlay,
              let screen = placementScreen else { return }
        for _ in 0..<3 {
            layoutBubble()
            let visible = screen.visibleFrame
            let bubble = overlay.frame.offsetBy(dx: frame.minX, dy: frame.minY)
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            if bubble.minX < visible.minX { dx = visible.minX - bubble.minX }
            if bubble.maxX > visible.maxX { dx = visible.maxX - bubble.maxX }
            if bubble.minY < visible.minY { dy = visible.minY - bubble.minY }
            if bubble.maxY > visible.maxY { dy = visible.maxY - bubble.maxY }
            if abs(dx) < 0.5 && abs(dy) < 0.5 { break }
            setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
        }
        layoutBubble()
    }

    func showBubble(text: String, duration: TimeInterval, emphasize: Bool = false) {
        bubbleHideTimer?.invalidate()
        bubbleText = text
        bubbleEmphasized = emphasize
        if !isReminderActive { keepFullyOnScreen() }
        layoutBubble()
        keepBubbleFullyOnScreen()
        bubbleHideTimer = Timer.scheduledTimer(withTimeInterval: max(duration, 2.0), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideBubble() }
        }
    }

    func hideBubble() {
        bubbleHideTimer?.invalidate()
        bubbleHideTimer = nil
        bubbleText = nil
        bubbleHeight = 0
        bubbleOverlay?.clear()
    }

    func applyScale(_ scale: Double) {
        guard !isReminderActive else { return }
        let visible = placementScreen?.visibleFrame
        let canvasWidth = Self.sourceWidth + Self.playbackInset * 2
        let canvasHeight = Self.sourceHeight + Self.playbackInset * 2
        let maxScale = visible.map { min($0.width / canvasWidth,
                                           ($0.height - Self.bubbleArea) / canvasHeight) } ?? 1.0
        let requested = min(max(scale, 0.25), maxScale)
        let density = backingScaleFactor
        // 画布宽度取整到物理像素，同时保持视频宽高比。
        prefs.petScale = (requested * Self.sourceWidth * density).rounded(.down) / (Self.sourceWidth * density)
        applyGeometry()
        prefs.save()
    }

    func applyAlwaysOnTop(_ on: Bool) {
        prefs.alwaysOnTop = on
        level = on ? .statusBar : .normal
        prefs.save()
    }

    // MARK: - 提醒动效

    /// 播放提醒回应，并把桌宠临时放大、移动到当前屏幕中央；提醒结束后恢复原位置。
    func showReminder(text: String, duration: TimeInterval) {
        stopPhysics()
        pointerIsDown = false
        lastDragSamples.removeAll()

        if isReminderActive {
            reminderAnimationFinished = false
            showBubble(text: text, duration: duration, emphasize: true)
            reminderAnimationStartFrame = frame
            reminderAnimationStartScale = displayScale
            reminderAnimationStartedAt = CACurrentMediaTime()
            reminderPhase = .intro
            playReminderAnimation()
            ensureReminderAnimationTimer()
            return
        }

        // 原位置先做一次普通的屏幕约束，确保返回动画有一个可靠终点。
        keepFullyOnScreen()
        guard let screen = placementScreen ?? NSScreen.main else {
            showBubble(text: text, duration: duration, emphasize: true)
            return
        }

        let originalFrame = frame
        let originalScale = displayScale
        let originalBodyCenter = NSPoint(x: visiblePetFrame.midX, y: visiblePetFrame.midY)
        let visible = screen.visibleFrame
        let canvasWidth = Self.sourceWidth + Self.playbackInset * 2
        let canvasHeight = Self.sourceHeight + Self.playbackInset * 2
        let fitScale = min(visible.width / canvasWidth,
                           max(0, visible.height - Self.bubbleArea) / canvasHeight)
        let targetScale = min(max(originalScale * 1.34, originalScale + 0.18), fitScale)
        let targetOrigin = frameOrigin(for: targetScale,
                                       bodyCenter: NSPoint(x: visible.midX, y: visible.midY),
                                       on: screen)
        let targetFrame = NSRect(origin: targetOrigin, size: frameSize(for: targetScale))

        reminderOriginalFrame = originalFrame
        reminderOriginalBodyCenter = originalBodyCenter
        reminderOriginalScale = originalScale
        reminderTargetFrame = targetFrame
        reminderTargetScale = targetScale
        reminderDisplayScale = originalScale
        reminderAnimationFinished = false
        reminderAnimationStartFrame = originalFrame
        reminderAnimationStartScale = originalScale
        reminderAnimationStartedAt = CACurrentMediaTime()
        reminderPhase = .intro

        showBubble(text: text, duration: duration, emphasize: true)
        playReminderAnimation()
        ensureReminderAnimationTimer()
    }

    private func playReminderAnimation() {
        guard let url = library.random.pick(excluding: currentURL) else {
            reminderAnimationFinished = true
            startReminderOutroIfReady()
            return
        }
        play(url: url, loop: false, rate: 1.0, state: "reminder") { [weak self] in
            guard let self else { return }
            self.reminderAnimationFinished = true
            self.startReminderOutroIfReady()
        }
    }

    private func ensureReminderAnimationTimer() {
        guard reminderAnimationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceReminderAnimation() }
        }
        reminderAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceReminderAnimation() {
        guard isReminderActive,
              let phase = reminderPhase,
              let targetFrame = reminderTargetFrame,
              let originalFrame = reminderOriginalFrame,
              let originalScale = reminderOriginalScale else {
            finishReminder()
            return
        }

        let now = CACurrentMediaTime()
        switch phase {
        case .intro:
            guard let startedAt = reminderAnimationStartedAt,
                  let startFrame = reminderAnimationStartFrame,
                  let startScale = reminderAnimationStartScale else {
                finishReminder()
                return
            }
            let raw = min(max((now - startedAt) / 0.55, 0), 1)
            let eased = reminderIntroEase(CGFloat(raw))
            let scale = startScale + (reminderTargetScale - startScale) * eased
            let origin = interpolate(startFrame.origin, targetFrame.origin, eased)
            setReminderGeometry(scale: scale, origin: origin)
            if raw >= 1 {
                setReminderGeometry(scale: reminderTargetScale, origin: targetFrame.origin)
                reminderPhase = .playing
                startReminderOutroIfReady()
            }

        case .playing:
            return

        case .outro:
            guard let startedAt = reminderAnimationStartedAt else {
                finishReminder()
                return
            }
            let raw = min(max((now - startedAt) / 0.55, 0), 1)
            let eased = reminderEaseInOut(CGFloat(raw))
            let scale = reminderTargetScale + (originalScale - reminderTargetScale) * eased
            let origin = interpolate(targetFrame.origin, originalFrame.origin, eased)
            setReminderGeometry(scale: scale, origin: origin)
            if raw >= 1 { finishReminder() }
        }
    }

    private func startReminderOutroIfReady() {
        guard reminderPhase == .playing,
              reminderAnimationFinished,
              let targetFrame = reminderTargetFrame else { return }
        reminderPhase = .outro
        reminderAnimationStartedAt = CACurrentMediaTime()
        reminderAnimationStartFrame = targetFrame
        reminderAnimationStartScale = reminderTargetScale
    }

    private func setReminderGeometry(scale: CGFloat, origin: NSPoint) {
        reminderDisplayScale = scale
        setWindowGeometry(frame: NSRect(origin: origin, size: frameSize(for: scale)), scale: scale)
    }

    private func interpolate(_ a: NSPoint, _ b: NSPoint, _ progress: CGFloat) -> NSPoint {
        NSPoint(x: a.x + (b.x - a.x) * progress,
                y: a.y + (b.y - a.y) * progress)
    }

    private func reminderIntroEase(_ progress: CGFloat) -> CGFloat {
        let t = min(max(progress, 0), 1)
        let inverse = 1 - t
        let cubic = 1 - inverse * inverse * inverse
        // 轻微弹性让“跳到中央”的到达感更明显，同时不越过屏幕边界。
        return min(1, cubic + sin(t * .pi) * 0.03)
    }

    private func reminderEaseInOut(_ progress: CGFloat) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func finishReminder() {
        guard let originalFrame = reminderOriginalFrame,
              let originalBodyCenter = reminderOriginalBodyCenter,
              let originalScale = reminderOriginalScale else {
            reminderAnimationTimer?.invalidate()
            reminderAnimationTimer = nil
            reminderPhase = nil
            reminderDisplayScale = nil
            return
        }

        reminderAnimationTimer?.invalidate()
        reminderAnimationTimer = nil

        let requestedScale = CGFloat(prefs.petScale)
        if abs(requestedScale - originalScale) < 0.001 {
            reminderDisplayScale = originalScale
            setWindowGeometry(frame: originalFrame, scale: originalScale)
        } else {
            let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(originalBodyCenter) })
                ?? NSScreen.main
            if let screen {
                reminderDisplayScale = requestedScale
                let origin = frameOrigin(for: requestedScale,
                                         bodyCenter: originalBodyCenter,
                                         on: screen)
                setWindowGeometry(frame: NSRect(origin: origin, size: frameSize(for: requestedScale)),
                                  scale: requestedScale)
            } else {
                reminderDisplayScale = originalScale
                setWindowGeometry(frame: originalFrame, scale: originalScale)
            }
        }

        reminderDisplayScale = nil
        reminderPhase = nil
        reminderAnimationStartedAt = nil
        reminderAnimationStartFrame = nil
        reminderAnimationStartScale = nil
        reminderAnimationFinished = false
        reminderOriginalFrame = nil
        reminderOriginalBodyCenter = nil
        reminderOriginalScale = nil
        reminderTargetFrame = nil
        reminderTargetScale = 0
        updatePointerHitTesting()
        returnToIdle()
    }

    // MARK: - 播放

    private func setLayerOpacity(_ layer: CALayer, _ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
    }

    private func removeEndObserver(from slot: PlaybackSlot) {
        if let observer = slot.endObserver {
            NotificationCenter.default.removeObserver(observer)
            slot.endObserver = nil
        }
    }

    private func reset(_ slot: PlaybackSlot, hideLayer: Bool = true) {
        slot.generation &+= 1
        removeEndObserver(from: slot)
        slot.looper?.disableLooping()
        slot.looper = nil
        slot.player.pause()
        slot.player.removeAllItems()
        slot.url = nil
        slot.loop = false
        slot.rate = 1.0
        if hideLayer { setLayerOpacity(slot.layer, 0) }
    }

    private func prepare(_ slot: PlaybackSlot, url: URL, loop: Bool, rate: Float,
                         onFinished: (() -> Void)? = nil) {
        reset(slot, hideLayer: false)
        slot.url = url
        slot.loop = loop
        slot.rate = rate
        let generation = slot.generation
        let slotIndex = playbackSlots.firstIndex(where: { $0 === slot }) ?? -1

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        if loop {
            // AVPlayerLooper 提前排队下一轮，避免循环回零时出现空帧。
            slot.looper = AVPlayerLooper(player: slot.player, templateItem: item)
        } else {
            slot.player.insert(item, after: nil)
            slot.endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self.activeSlotIndex == slotIndex,
                          self.playbackSlots[slotIndex].generation == generation,
                          self.activeSlot.url == url else { return }
                    if let onFinished {
                        onFinished()
                    } else {
                        self.returnToIdle()
                    }
                }
            }
        }
        slot.player.playImmediately(atRate: rate)
    }

    /// 取消正在等待首帧或交叉淡化的切换，恢复当前槽的完整可见状态。
    private func cancelTransition() {
        transitionToken += 1
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartedAt = nil
        if let targetIndex = transitionTargetIndex {
            reset(playbackSlots[targetIndex])
            transitionTargetIndex = nil
        }
        setLayerOpacity(activeSlot.layer, 1)
        hitSlotIndex = activeSlotIndex
    }

    private func finishTransition(to targetIndex: Int) {
        guard transitionTargetIndex == targetIndex else { return }
        transitionTimer?.invalidate()
        transitionTimer = nil
        let oldIndex = activeSlotIndex
        activeSlotIndex = targetIndex
        hitSlotIndex = targetIndex
        transitionTargetIndex = nil
        transitionStartedAt = nil
        setLayerOpacity(playbackSlots[targetIndex].layer, 1)
        reset(playbackSlots[oldIndex])
    }

    private func advanceTransition(token: Int) {
        guard token == transitionToken,
              let targetIndex = transitionTargetIndex else { return }
        let target = playbackSlots[targetIndex]
        let now = CACurrentMediaTime()
        if target.player.currentItem?.status == .failed {
            // 解码失败时回退到硬切换，避免窗口永远停在动作最后一帧。
            let url = target.url
            let loop = target.loop
            let rate = target.rate
            let nextState = state
            cancelTransition()
            if let url { play(url: url, loop: loop, rate: rate, state: nextState) }
            return
        }

        // 只有新素材已经真正出首帧后才开始淡化，动作最后一帧会一直垫在下面，
        // 即使磁盘或解码器稍慢也不会闪出透明空帧。
        guard target.layer.isReadyForDisplay else { return }
        if transitionStartedAt == nil {
            transitionStartedAt = now
            hitSlotIndex = targetIndex
        }
        guard let startedAt = transitionStartedAt else { return }
        let raw = min(max((now - startedAt) / transitionDuration, 0), 1)
        let eased = raw * raw * (3 - 2 * raw)
        let oldIndex = activeSlotIndex
        setLayerOpacity(playbackSlots[oldIndex].layer, Float(1 - eased))
        setLayerOpacity(target.layer, Float(eased))
        if raw >= 1 { finishTransition(to: targetIndex) }
    }

    private func playSmooth(url: URL, loop: Bool, rate: Float, state: String) {
        if currentURL == url, loop == currentLoop, player.rate > 0, transitionTargetIndex == nil { return }
        cancelTransition()
        let targetIndex = 1 - activeSlotIndex
        let target = playbackSlots[targetIndex]
        setLayerOpacity(activeSlot.layer, 1)
        setLayerOpacity(target.layer, 0)
        prepare(target, url: url, loop: loop, rate: rate)

        self.state = state
        onStateChanged?(state)
        transitionTargetIndex = targetIndex
        let token = transitionToken
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceTransition(token: token) }
        }
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func play(url: URL, loop: Bool, rate: Float = 1.0, state: String,
              onFinished: (() -> Void)? = nil) {
        if currentURL == url, loop == currentLoop, player.rate > 0,
           transitionTargetIndex == nil, onFinished == nil { return }
        cancelTransition()
        reset(inactiveSlot)
        setLayerOpacity(activeSlot.layer, 1)
        prepare(activeSlot, url: url, loop: loop, rate: rate, onFinished: onFinished)
        hitSlotIndex = activeSlotIndex
        self.state = state
        onStateChanged?(state)
    }

    var renderDiagnostics: [String: Any] {
        refreshHitPixels()
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[String: Any]]
        let server = windows?.first?[kCGWindowBounds as String] as? [String: Any]
        let serverW = (server?["Width"] as? NSNumber)?.doubleValue ?? 0
        let serverH = (server?["Height"] as? NSNumber)?.doubleValue ?? 0
        let visible = placementScreen?.visibleFrame.insetBy(dx: -1, dy: -1)
        let serverBounds = NSRect(x: 0, y: 0, width: serverW, height: serverH)
        let petBounds = visiblePetFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let videoFrame = videoHost.frame.offsetBy(dx: frame.minX, dy: frame.minY)
        let animationFrame = animationFrameInWindow(for: displayScale).offsetBy(dx: frame.minX, dy: frame.minY)
        let bubbleFrame = bubbleOverlay?.frame.offsetBy(dx: frame.minX, dy: frame.minY) ?? .zero
        return ["serverMatchesFrame": abs(serverW - frame.width) < 1 && abs(serverH - frame.height) < 1,
         "serverWindowWidth": serverW, "serverWindowHeight": serverH,
         "loopCount": activeSlot.looper?.loopCount ?? 0,
         "canvasInsideWindow": contentView?.bounds.contains(videoHost.frame) ?? false,
         "windowFullyOnScreen": screen?.visibleFrame.contains(frame) ?? false,
         "petFullyOnScreen": visible?.contains(visiblePetFrame) ?? false,
         "bubbleFullyOnScreen": !isBubbleVisible || (visible?.contains(bubbleFrame) ?? false),
         "bubbleInsideWindow": !isBubbleVisible || (contentView?.bounds.contains(bubbleOverlay?.frame ?? .zero) ?? false),
         "bubbleInsideServerWindow": !isBubbleVisible || serverBounds.contains(bubbleOverlay?.frame ?? .zero),
         "petInsideServerWindow": serverBounds.contains(petBounds),
         "bubbleTextFullyVisible": !isBubbleVisible || (bubbleOverlay?.isTextFullyVisible ?? false),
         "bubbleOverlapsVideo": isBubbleVisible && bubbleFrame.intersects(videoFrame),
         "bubbleOverlapsAnimation": isBubbleVisible && bubbleFrame.intersects(animationFrame),
         "videoFrame": [videoFrame.minX, videoFrame.minY, videoFrame.width, videoFrame.height],
         "animationFrame": [animationFrame.minX, animationFrame.minY, animationFrame.width, animationFrame.height],
         "bubbleGap": isBubbleVisible ? bubbleFrame.minY - visiblePetFrame.maxY : 0,
         "bubbleWidth": bubbleOverlay?.frame.width ?? 0,
         "bubbleHeight": bubbleHeight,
         "displayScale": displayScale,
         "reminderActive": isReminderActive,
         "bubbleVisible": isBubbleVisible,
         "restingSourceBounds": [restingSourceBounds.minX, restingSourceBounds.minY,
                                 restingSourceBounds.width, restingSourceBounds.height],
         "canvasWidth": videoHost.frame.width, "canvasHeight": videoHost.frame.height,
         "transparentCornerPassesThrough": !isVisiblePixel(at: NSPoint(x: 1, y: 1)),
         "hasHitPixels": hitPixelBuffer != nil,
         "centerReceivesMouse": isVisiblePixel(at: NSPoint(x: videoHost.frame.midX,
                                                          y: videoHost.frame.minY + 164 * CGFloat(prefs.petScale))),
         "state": state, "rate": player.rate, "timeControlStatus": player.timeControlStatus.rawValue,
         "readyForDisplay": playerLayer.isReadyForDisplay,
         "itemStatus": player.currentItem?.status.rawValue ?? -1,
         "time": player.currentTime().seconds,
         "backingScale": backingScaleFactor,
         "layerScale": playerLayer.contentsScale,
         "videoWidth": player.currentItem?.presentationSize.width ?? 0,
         "videoHeight": player.currentItem?.presentationSize.height ?? 0,
         "looperStatus": activeSlot.looper?.status.rawValue ?? -1,
         "windowVisible": isVisible,
         "error": player.currentItem?.error?.localizedDescription ?? ""]
    }

    /// 验收预览复用实际视频帧、气泡图层与窗口坐标，不截取桌面或其他应用。
    func saveRenderPreview(to destination: URL) {
        let density = backingScaleFactor
        guard let context = CGContext(data: nil, width: Int(ceil(frame.width * density)),
                                      height: Int(ceil(frame.height * density)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: density, y: density)
        context.setFillColor(NSColor(calibratedRed: 0.92, green: 0.88, blue: 0.81, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: frame.size))
        if let url = currentURL {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            if let image = try? generator.copyCGImage(at: player.currentTime(), actualTime: nil) {
                context.draw(image, in: videoHost.frame)
            }
        }
        if isBubbleVisible, let overlay = bubbleOverlay {
            context.saveGState()
            context.translateBy(x: overlay.frame.minX, y: overlay.frame.minY)
            overlay.renderPreview(in: context)
            context.restoreGState()
        }
        if let image = context.makeImage(),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: destination)
        }
    }

    func playIdle(smooth: Bool = false) {
        guard let url = library.idle.pick() else { return }
        if smooth {
            playSmooth(url: url, loop: true, rate: 1.0, state: "idle")
        } else {
            play(url: url, loop: true, rate: 1.0, state: "idle")
        }
    }

    func playClick() {
        guard let url = library.click.pick(excluding: currentURL) else { playIdle(); return }
        play(url: url, loop: false, rate: 1.15, state: "click")
    }

    func playRandom() {
        guard prefs.randomActionsEnabled,
              let url = library.random.pick(excluding: currentURL) else { return }
        play(url: url, loop: false, rate: 1.0, state: "random")
    }

    func playDragFeedback() {
        guard let url = library.drag.pick() else { return }
        play(url: url, loop: true, rate: 1.0, state: "drag")
    }

    func returnToIdle() {
        playIdle(smooth: true)
    }

    // MARK: - 鼠标交互

    override func mouseDown(with event: NSEvent) {
        guard !isReminderActive else { return }
        pointerIsDown = true
        ignoresMouseEvents = false
        stopPhysics()
        mouseDownScreen = convertPoint(toScreen: event.locationInWindow)
        windowOriginAtDown = frame.origin
        lastDragSamples = [(event.timestamp, mouseDownScreen)]
        didDrag = false
        playDragFeedback()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isReminderActive else { return }
        let now = convertPoint(toScreen: event.locationInWindow)
        let dx = now.x - mouseDownScreen.x
        let dy = now.y - mouseDownScreen.y
        if abs(dx) > 3 || abs(dy) > 3 { didDrag = true }
        let origin = NSPoint(x: windowOriginAtDown.x + dx, y: windowOriginAtDown.y + dy)
        // 拖动时允许跨屏；松手时只限制角色轮廓，透明留白可以越过屏缘。
        setFrameOrigin(origin)
        if isBubbleVisible { layoutBubble() }
        lastDragSamples.append((event.timestamp, now))
        if lastDragSamples.count > 6 { lastDragSamples.removeFirst() }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isReminderActive else {
            pointerIsDown = false
            return
        }
        pointerIsDown = false
        if didDrag {
            keepFullyOnScreen()
            launchIfThrown()
        } else if let cb = onClicked {
            cb(NSEvent.mouseLocation)
        } else {
            returnToIdle()
        }
        rememberPosition()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isReminderActive else { return }
        stopPhysics()
        keepFullyOnScreen()
        returnToIdle()
        onRightClicked?(NSEvent.mouseLocation)
    }

    // MARK: - 物理（抛掷）

    private func launchIfThrown() {
        guard lastDragSamples.count >= 2,
              let first = lastDragSamples.first, let last = lastDragSamples.last else {
            returnToIdle(); return
        }
        let dt = max(last.t - first.t, 0.001)
        let vx = (last.p.x - first.p.x) / CGFloat(dt)
        let vy = (last.p.y - first.p.y) / CGFloat(dt)
        if abs(vx) < 220 && abs(vy) < 220 {
            returnToIdle(); return
        }
        velocity = NSPoint(x: vx, y: vy)
        lastPhysicsTick = CACurrentMediaTime()
        playDragFeedback()
        state = "flying"
        physicsTimer?.invalidate()
        physicsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepPhysics() }
        }
    }

    private func stopPhysics() {
        physicsTimer?.invalidate()
        physicsTimer = nil
    }

    private func stepPhysics() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastPhysicsTick, 0.05)
        lastPhysicsTick = now

        let gravity: CGFloat = 2100   // pt/s²
        velocity.y -= gravity * CGFloat(dt)
        velocity.x *= 0.995
        velocity.y *= 0.999

        var origin = frame.origin
        origin.x += velocity.x * CGFloat(dt)
        origin.y += velocity.y * CGFloat(dt)

        guard let scr = placementScreen?.visibleFrame else { stopPhysics(); return }
        let body = visiblePetFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let bounce: CGFloat = 0.55

        if origin.x + body.minX < scr.minX {
            origin.x = scr.minX - body.minX
            velocity.x = abs(velocity.x) * bounce
        } else if origin.x + body.maxX > scr.maxX {
            origin.x = scr.maxX - body.maxX
            velocity.x = -abs(velocity.x) * bounce
        }
        if origin.y + body.maxY > scr.maxY {
            origin.y = scr.maxY - body.maxY
            velocity.y = -abs(velocity.y) * bounce
        }
        if origin.y + body.minY <= scr.minY {
            origin.y = scr.minY - body.minY
            if abs(velocity.y) < 120 {
                velocity = .zero
                setFrameOrigin(origin)
                if isBubbleVisible { layoutBubble() }
                stopPhysics()
                returnToIdle()
                rememberPosition()
                return
            }
            velocity.y = abs(velocity.y) * bounce
            velocity.x *= 0.82
        }
        setFrameOrigin(origin)
        if isBubbleVisible { layoutBubble() }
    }

    // MARK: - 位置

    func rememberPosition() {
        prefs.lastPositionX = frame.origin.x
        prefs.lastPositionY = frame.origin.y
        prefs.save()
    }

    func restorePosition() {
        if let x = prefs.lastPositionX, let y = prefs.lastPositionY {
            let p = NSPoint(x: x, y: y)
            let savedFrame = NSRect(origin: p, size: frame.size)
            let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(savedFrame) }
            if visible {
                setFrameOrigin(p)
                keepFullyOnScreen()
                return
            }
        }
        placeAtDefaultPosition()
    }

    func placeAtDefaultPosition() {
        guard let scr = screen ?? NSScreen.main else { return }
        let f = scr.visibleFrame
        setFrameOrigin(constrainedOrigin(NSPoint(x: f.maxX - frame.width - 60, y: f.minY + 20), on: scr))
    }

    /// 气泡锚点（当前动画安全边界上方，屏幕坐标）
    func bubbleAnchor() -> NSPoint {
        let bounds = animationFrameInWindow(for: displayScale)
        return NSPoint(x: frame.minX + bounds.midX, y: frame.minY + bounds.maxY + Self.bubbleGap)
    }
}

/// 允许窗口未激活时的第一次点击直接生效（否则要先点一下激活窗口）
final class PetContentView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
