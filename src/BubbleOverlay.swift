import Cocoa
import CoreText

/// 气泡层：以角色头顶为锚点，视图尺寸始终与完整卡片一致。
/// 卡片与文字由 CALayer 绘制，移动气泡不改变角色或窗口的位置。
final class BubbleOverlayView: NSView {

    private let cardLayer = CALayer()
    private let textLayer = BubbleTextLayer()
    private let accent = NSColor(calibratedRed: 0.29, green: 0.42, blue: 0.72, alpha: 1.0)
    private var lastText: String?
    private var lastEmphasized = false
    private var lastWidth: CGFloat = 0
    private var cardHeight: CGFloat = 0

    static let padding: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        cardLayer.cornerRadius = 13
        cardLayer.masksToBounds = false
        cardLayer.isHidden = true
        layer?.addSublayer(cardLayer)

        textLayer.needsDisplayOnBoundsChange = true
        cardLayer.addSublayer(textLayer)
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

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        cardLayer.contentsScale = scale
        textLayer.contentsScale = scale
        textLayer.setNeedsDisplay()
        CATransaction.commit()
    }

    /// 先按实际宽度测量全文，再让卡片与文字层共享同一个尺寸和原点。
    @discardableResult
    func update(text: String, emphasized: Bool, cardWidth: CGFloat) -> CGFloat {
        if lastText == text, lastEmphasized == emphasized, lastWidth == cardWidth {
            return cardHeight
        }
        let padding = Self.padding
        let font = NSFont.systemFont(ofSize: emphasized ? 13.5 : 12.5, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.alignment = .left
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
            .paragraphStyle: para
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textW = max(1, cardWidth - padding * 2)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: attr.length), nil,
            CGSize(width: textW, height: .greatestFiniteMagnitude), nil)
        // 多留两个点，避免中文回退字体及 Retina 像素取整切到首末行。
        let textH = ceil(measured.height) + 2
        let cardH = textH + padding * 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.isHidden = false
        cardLayer.backgroundColor = NSColor.white.cgColor
        cardLayer.borderWidth = emphasized ? 1.8 : 1
        cardLayer.borderColor = emphasized
            ? accent.withAlphaComponent(0.85).cgColor
            : NSColor(calibratedWhite: 0.72, alpha: 1).cgColor
        cardLayer.frame = CGRect(x: 0, y: 0, width: cardWidth, height: cardH)
        textLayer.frame = CGRect(x: padding, y: padding, width: textW, height: textH)
        textLayer.text = attr
        CATransaction.commit()
        lastText = text
        lastEmphasized = emphasized
        lastWidth = cardWidth
        cardHeight = cardH
        return cardH
    }

    /// 同时检查卡片边界和 Core Text 实际能排入文字层的字符范围。
    var isTextFullyVisible: Bool {
        guard let attr = textLayer.text else { return false }
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: textLayer.bounds, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attr.length), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        return bounds.contains(cardLayer.frame) && cardLayer.bounds.contains(textLayer.frame) &&
            visible.location + visible.length == attr.length
    }

    func renderPreview(in context: CGContext) {
        textLayer.displayIfNeeded()
        layer?.render(in: context)
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.isHidden = true
        textLayer.text = nil
        CATransaction.commit()
        lastText = nil
    }
}

/// 使用与测量相同的 Core Text 排版，确保中文行距和实际绘制的行数一致。
private final class BubbleTextLayer: CALayer {
    var text: NSAttributedString? {
        didSet { setNeedsDisplay() }
    }

    override func draw(in context: CGContext) {
        guard let text else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: bounds, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }
}
