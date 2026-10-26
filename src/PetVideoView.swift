import Cocoa
import AVFoundation

/// 保持视频层与所在屏幕的像素密度同步，包括跨屏拖动后的更新。
@MainActor
final class PetVideoView: NSView {
    let playerLayer = AVPlayerLayer()
    /// 过渡层：在动作结束、切回待机时先解码新画面，再与旧画面交叉淡化，避免替换 AVPlayerItem 时露出空帧。
    let transitionPlayerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        for videoLayer in [playerLayer, transitionPlayerLayer] {
            videoLayer.backgroundColor = NSColor.clear.cgColor
            videoLayer.isOpaque = false
            videoLayer.videoGravity = .resizeAspect
            videoLayer.minificationFilter = .trilinear
            videoLayer.magnificationFilter = .linear
            videoLayer.opacity = 0
        }
        layer?.addSublayer(playerLayer)
        layer?.addSublayer(transitionPlayerLayer)
        updateBackingScale()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        playerLayer.contentsScale = scale
        transitionPlayerLayer.contentsScale = scale
        CATransaction.commit()
    }
}
