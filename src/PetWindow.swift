import Cocoa
import AVFoundation

/// 桌宠主窗口：透明、无边框、置顶，自行处理拖动与抛掷物理。
@MainActor
final class PetWindow: NSWindow {

    // 视频源 1280×720（2× 超采样）；角色逻辑占位约 308×310，窗口按此裁剪
    static let sourceWidth: CGFloat = 1280
    static let sourceHeight: CGFloat = 720
    static let cropWidth: CGFloat = 308
    static let cropHeight: CGFloat = 310
    static let cropCenterX: CGFloat = 640
    static let cropCenterY: CGFloat = 392
    /// 顶部常驻气泡区高度（窗口固定高度，避免动态 resize 不提交到 WindowServer）
    static let bubbleArea: CGFloat = 96
    static let bubbleAreaTail: CGFloat = 9

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let videoHost = NSView()
    private let cardLayer = CALayer()
    private let textLayer = CATextLayer()
    private var endObserver: NSObjectProtocol?
    private var currentURL: URL?
    private var currentLoop = false
    private var currentRate: Float = 1.0

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
        NSSize(width: Self.cropWidth * prefs.petScale,
               height: Self.cropHeight * prefs.petScale)
    }

    init(library: ClipLibrary, prefs: Preferences) {
        self.library = library
        self.prefs = prefs
        let w = Self.cropWidth * prefs.petScale
        let h = Self.cropHeight * prefs.petScale + Self.bubbleArea
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

        videoHost.wantsLayer = true
        videoHost.layer?.backgroundColor = NSColor.clear.cgColor
        videoHost.layer?.masksToBounds = false
        playerLayer.player = player
        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.isOpaque = false
        videoHost.layer?.addSublayer(playerLayer)
        container.addSubview(videoHost)
        contentView = container



        let overlay = BubbleOverlayView(frame: NSRect(x: 0, y: Self.cropHeight * prefs.petScale,
                                                     width: w, height: Self.bubbleArea))
        overlay.wantsLayer = true

        container.addSubview(overlay)
        bubbleOverlay = overlay

        let ov = BubbleOverlayView(frame: NSRect(x: 0, y: Self.cropHeight * prefs.petScale,
                                                 width: w, height: Self.bubbleArea))
        container.addSubview(ov)
        bubbleOverlay = ov

        player.actionAtItemEnd = .none
        player.isMuted = true
        applyGeometry()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - 几何

    /// 按当前缩放，把视频层摆到使角色居中的位置（窗口高度含气泡区）
    func applyGeometry() {
        let s = CGFloat(prefs.petScale)
        let roleW = Self.cropWidth * s
        let roleH = Self.cropHeight * s
        let totalH = roleH + Self.bubbleArea
        let origin = frame.origin
        setFrame(NSRect(origin: origin, size: NSSize(width: roleW, height: totalH)), display: true)

        // 素材为 1280×720（2× 像素密度），显示时按 s/2 折算，视觉尺寸保持不变
        let vs = s / 2
        let vw = Self.sourceWidth * vs
        let vh = Self.sourceHeight * vs
        let x = roleW / 2 - Self.cropCenterX * vs
        // 视频区相对窗口底部（气泡占据顶部，不影响角色位置）
        let y = roleH / 2 - (Self.sourceHeight - Self.cropCenterY) * vs
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoHost.frame = NSRect(x: x, y: y, width: vw, height: vh)
        playerLayer.frame = CGRect(x: 0, y: 0, width: vw, height: vh)
        CATransaction.commit()
        bubbleOverlay?.frame = NSRect(x: 0, y: roleH, width: roleW, height: Self.bubbleArea)
    }

    // MARK: - 气泡

    func showBubble(text: String, duration: TimeInterval, emphasize: Bool = false) {
        bubbleHideTimer?.invalidate()
        let s = CGFloat(prefs.petScale)
        let roleW = Self.cropWidth * s
        let roleH = Self.cropHeight * s

        if bubbleOverlay == nil {
            let v = BubbleOverlayView(frame: NSRect(x: 0, y: roleH, width: roleW, height: Self.bubbleArea))
            contentView?.addSubview(v)
            bubbleOverlay = v
        }
        guard let overlay = bubbleOverlay else { return }
        overlay.frame = NSRect(x: 0, y: roleH, width: roleW, height: Self.bubbleArea)
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
        prefs.petScale = scale
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

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        player.play()
        player.rate = rate

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if loop {
                        self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                        self.player.play()
                        self.player.rate = rate
                    } else {
                        self.returnToIdle()
                    }
                }
            }
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
        // 允许拖出屏幕一部分，但不能完全飞走
        if let scr = screen?.visibleFrame {
            origin.x = min(max(origin.x, scr.minX - frame.width * 0.5), scr.maxX - frame.width * 0.5)
            origin.y = min(max(origin.y, scr.minY - 10), scr.maxY - frame.height * 0.4)
        }
        setFrameOrigin(origin)
        lastDragSamples.append((CACurrentMediaTime(), NSEvent.mouseLocation))
        if lastDragSamples.count > 6 { lastDragSamples.removeFirst() }
    }

    override func mouseUp(with event: NSEvent) {
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
            if visible { setFrameOrigin(p); return }
        }
        placeAtDefaultPosition()
    }

    func placeAtDefaultPosition() {
        guard let scr = screen ?? NSScreen.main else { return }
        let f = scr.visibleFrame
        setFrameOrigin(NSPoint(x: f.maxX - frame.width - 60, y: f.minY + 20))
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
