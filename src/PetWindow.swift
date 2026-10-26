import Cocoa
import AVFoundation

/// 桌宠主窗口：透明、无边框、置顶，自行处理拖动与抛掷物理。
@MainActor
final class PetWindow: NSWindow {

    // 几何使用 640×360 逻辑画布；视频分辨率可独立提高，角色显示大小保持稳定。
    static let sourceWidth: CGFloat = 640
    static let sourceHeight: CGFloat = 360
    static let bubbleWidth: CGFloat = 308
    /// 顶部常驻气泡区高度（窗口固定高度，避免动态 resize 不提交到 WindowServer）
    static let bubbleArea: CGFloat = 96
    static let bubbleAreaTail: CGFloat = 9

    private let player = AVQueuePlayer()
    private var playerLooper: AVPlayerLooper?
    private let videoHost = PetVideoView(frame: .zero)
    private var playerLayer: AVPlayerLayer { videoHost.playerLayer }
    private let cardLayer = CALayer()
    private let textLayer = CATextLayer()
    private var endObserver: NSObjectProtocol?
    private var currentURL: URL?
    private var currentLoop = false
    private var currentRate: Float = 1.0
    private let hitOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ])
    private weak var hitOutputItem: AVPlayerItem?
    private var hitPixelBuffer: CVPixelBuffer?
    private var pointerTimer: Timer?
    private var pointerIsDown = false

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
    private var bubbleHideTimer: Timer?
    private var originBeforeBubble: NSPoint?

    var isBubbleVisible: Bool { bubbleHeight > 0 }

    // 回调
    var onClicked: ((NSPoint) -> Void)?
    var onRightClicked: ((NSPoint) -> Void)?
    var onStateChanged: ((String) -> Void)?

    var bodySize: NSSize {
        NSSize(width: Self.sourceWidth * prefs.petScale,
               height: Self.sourceHeight * prefs.petScale)
    }

    init(library: ClipLibrary, prefs: Preferences) {
        self.library = library
        self.prefs = prefs
        let w = Self.sourceWidth * prefs.petScale
        let h = Self.sourceHeight * prefs.petScale + Self.bubbleArea
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

        playerLayer.player = player
        container.addSubview(videoHost)
        contentView = container

        let bubbleW = Self.bubbleWidth * prefs.petScale
        let ov = BubbleOverlayView(frame: NSRect(x: (w - bubbleW) / 2, y: Self.sourceHeight * prefs.petScale,
                                                 width: bubbleW, height: Self.bubbleArea))
        container.addSubview(ov)
        bubbleOverlay = ov

        player.actionAtItemEnd = .none
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
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

    /// 窗口容纳完整 640×360 动画画布，头顶另留气泡区；不裁剪动作和特效。
    func applyGeometry() {
        let s = CGFloat(prefs.petScale)
        let canvasW = Self.sourceWidth * s
        let canvasH = Self.sourceHeight * s
        let totalH = canvasH + Self.bubbleArea
        let origin = NSPoint(x: frame.midX - canvasW / 2, y: frame.minY)
        setFrame(NSRect(origin: origin, size: NSSize(width: canvasW, height: totalH)), display: true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoHost.frame = NSRect(x: 0, y: 0, width: canvasW, height: canvasH)
        playerLayer.frame = videoHost.bounds
        videoHost.updateBackingScale()
        CATransaction.commit()
        let bubbleW = Self.bubbleWidth * s
        bubbleOverlay?.frame = NSRect(x: (canvasW - bubbleW) / 2, y: canvasH,
                                      width: bubbleW, height: Self.bubbleArea)
        if isVisible { keepFullyOnScreen() }
    }

    /// 透明区域穿透桌面，只在当帧实际可见的像素或提醒气泡上接收鼠标。
    private func refreshHitPixels() {
        if player.currentItem !== hitOutputItem {
            hitOutputItem?.remove(hitOutput)
            hitOutputItem = player.currentItem
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
            let s = CGFloat(prefs.petScale)
            return NSRect(x: (Self.sourceWidth - 240) * s / 2, y: 20 * s,
                          width: 240 * s, height: 300 * s).contains(point)
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
        if player.currentItem !== hitOutputItem { refreshHitPixels() }
        guard !pointerIsDown else { ignoresMouseEvents = false; return }
        let point = mouseLocationOutsideOfEventStream
        guard contentView?.bounds.contains(point) == true else { ignoresMouseEvents = true; return }
        refreshHitPixels()
        ignoresMouseEvents = !isVisiblePixel(at: point)
    }

    private func constrainedOrigin(_ origin: NSPoint, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width)),
                       y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height)))
    }

    func keepFullyOnScreen() {
        guard let target = screen ?? NSScreen.main else { return }
        let visible = target.visibleFrame
        if frame.width > visible.width || frame.height > visible.height {
            let fit = min(visible.width / Self.sourceWidth,
                          max(1, visible.height - Self.bubbleArea) / Self.sourceHeight)
            applyScale(fit)
            return
        }
        let origin = constrainedOrigin(frame.origin, on: target)
        let density = backingScaleFactor
        setFrameOrigin(NSPoint(x: (origin.x * density).rounded() / density,
                               y: (origin.y * density).rounded() / density))
    }

    // MARK: - 气泡

    func showBubble(text: String, duration: TimeInterval, emphasize: Bool = false) {
        bubbleHideTimer?.invalidate()
        let s = CGFloat(prefs.petScale)
        let roleW = Self.bubbleWidth * s
        let roleH = Self.sourceHeight * s
        let bubbleX = (Self.sourceWidth * s - roleW) / 2

        if bubbleOverlay == nil {
            let v = BubbleOverlayView(frame: NSRect(x: bubbleX, y: roleH, width: roleW, height: Self.bubbleArea))
            contentView?.addSubview(v)
            bubbleOverlay = v
        }
        guard let overlay = bubbleOverlay else { return }
        overlay.frame = NSRect(x: bubbleX, y: roleH, width: roleW, height: Self.bubbleArea)
        overlay.restoreBackground()
        let cardH = overlay.update(text: text, emphasized: emphasize, cardWidth: roleW)
        bubbleHeight = cardH
        overlay.needsDisplay = true

        bubbleHideTimer = Timer.scheduledTimer(withTimeInterval: max(duration, 2.0), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideBubble() }
        }
    }

    func hideBubble() {
        bubbleHideTimer?.invalidate()
        bubbleHideTimer = nil
        guard bubbleHeight > 0 else { return }
        bubbleHeight = 0
        bubbleOverlay?.clear()
    }

    func applyScale(_ scale: Double) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame
        let maxScale = visible.map { min($0.width / Self.sourceWidth, ($0.height - Self.bubbleArea) / Self.sourceHeight) } ?? 1.0
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

    // MARK: - 播放

    func play(url: URL, loop: Bool, rate: Float = 1.0, state: String) {
        if currentURL == url, loop == currentLoop, player.rate > 0 { return }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        currentURL = url
        currentLoop = loop
        currentRate = rate
        self.state = state
        onStateChanged?(state)

        playerLooper?.disableLooping()
        playerLooper = nil
        player.removeAllItems()
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        if loop {
            // AVPlayerLooper 提前排队下一轮，避免 seek 回零时的空帧闪烁。
            playerLooper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.returnToIdle() }
                }
        }
        player.playImmediately(atRate: rate)
    }

    var renderDiagnostics: [String: Any] {
        refreshHitPixels()
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[String: Any]]
        let server = windows?.first?[kCGWindowBounds as String] as? [String: Any]
        let serverW = (server?["Width"] as? NSNumber)?.doubleValue ?? 0
        let serverH = (server?["Height"] as? NSNumber)?.doubleValue ?? 0
        return ["serverMatchesFrame": abs(serverW - frame.width) < 1 && abs(serverH - frame.height) < 1,
         "serverWindowWidth": serverW, "serverWindowHeight": serverH,
         "loopCount": playerLooper?.loopCount ?? 0,
         "canvasInsideWindow": contentView?.bounds.contains(videoHost.frame) ?? false,
         "windowFullyOnScreen": screen?.visibleFrame.contains(frame) ?? false,
         "canvasWidth": videoHost.frame.width, "canvasHeight": videoHost.frame.height,
         "transparentCornerPassesThrough": !isVisiblePixel(at: NSPoint(x: 1, y: 1)),
         "hasHitPixels": hitPixelBuffer != nil,
         "centerReceivesMouse": isVisiblePixel(at: NSPoint(x: bodySize.width / 2,
                                                          y: 164 * CGFloat(prefs.petScale))),
         "state": state, "rate": player.rate, "timeControlStatus": player.timeControlStatus.rawValue,
         "readyForDisplay": playerLayer.isReadyForDisplay,
         "itemStatus": player.currentItem?.status.rawValue ?? -1,
         "time": player.currentTime().seconds,
         "backingScale": backingScaleFactor,
         "layerScale": playerLayer.contentsScale,
         "videoWidth": player.currentItem?.presentationSize.width ?? 0,
         "videoHeight": player.currentItem?.presentationSize.height ?? 0,
         "looperStatus": playerLooper?.status.rawValue ?? -1,
         "error": player.currentItem?.error?.localizedDescription ?? ""]
    }

    func playIdle() {
        guard let url = library.idle.pick() else { return }
        play(url: url, loop: true, rate: 1.0, state: "idle")
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
        playIdle()
    }

    // MARK: - 鼠标交互

    override func mouseDown(with event: NSEvent) {
        pointerIsDown = true
        ignoresMouseEvents = false
        stopPhysics()
        mouseDownScreen = NSEvent.mouseLocation
        windowOriginAtDown = frame.origin
        lastDragSamples = [(CACurrentMediaTime(), mouseDownScreen)]
        didDrag = false
        playDragFeedback()
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseDownScreen.x
        let dy = now.y - mouseDownScreen.y
        if abs(dx) > 3 || abs(dy) > 3 { didDrag = true }
        var origin = NSPoint(x: windowOriginAtDown.x + dx, y: windowOriginAtDown.y + dy)
        // 拖动时也保留完整动画画布，不能把角色或道具拖到屏幕外。
        if let target = NSScreen.screens.first(where: { $0.frame.contains(now) }) ?? screen {
            origin = constrainedOrigin(origin, on: target)
        }
        setFrameOrigin(origin)
        lastDragSamples.append((CACurrentMediaTime(), NSEvent.mouseLocation))
        if lastDragSamples.count > 6 { lastDragSamples.removeFirst() }
    }

    override func mouseUp(with event: NSEvent) {
        pointerIsDown = false
        if didDrag {
            launchIfThrown()
        } else if let cb = onClicked {
            cb(NSEvent.mouseLocation)
        } else {
            returnToIdle()
        }
        rememberPosition()
    }

    override func rightMouseDown(with event: NSEvent) {
        stopPhysics()
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

        guard let scr = screen?.visibleFrame else { stopPhysics(); return }
        let bounce: CGFloat = 0.55

        if origin.x < scr.minX {
            origin.x = scr.minX
            velocity.x = abs(velocity.x) * bounce
        } else if origin.x + frame.width > scr.maxX {
            origin.x = scr.maxX - frame.width
            velocity.x = -abs(velocity.x) * bounce
        }
        if origin.y + frame.height > scr.maxY {
            origin.y = scr.maxY - frame.height
            velocity.y = -abs(velocity.y) * bounce
        }
        if origin.y <= scr.minY {
            origin.y = scr.minY
            if abs(velocity.y) < 120 {
                velocity = .zero
                setFrameOrigin(origin)
                stopPhysics()
                returnToIdle()
                rememberPosition()
                return
            }
            velocity.y = abs(velocity.y) * bounce
            velocity.x *= 0.82
        }
        setFrameOrigin(origin)
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
            let visible = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(p) }
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

    /// 气泡锚点（窗口顶部中心，屏幕坐标）
    func bubbleAnchor() -> NSPoint {
        NSPoint(x: frame.midX, y: frame.maxY - 6)
    }
}

/// 允许窗口未激活时的第一次点击直接生效（否则要先点一下激活窗口）
final class PetContentView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
