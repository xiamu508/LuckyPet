import Cocoa

/// 气泡层：固定在桌宠窗口顶部气泡区，内部用 CALayer 绘制卡片与文字。
/// overlay 自身位置/尺寸保持不变（已验证可显示），卡片在内部按需布局。
final class BubbleOverlayView: NSView {

    private let cardLayer = CALayer()
    private let textLayer = CATextLayer()
    private let accent = NSColor(calibratedRed: 0.29, green: 0.42, blue: 0.72, alpha: 1.0)

    static let tailHeight: CGFloat = 9
    static let padding: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        cardLayer.cornerRadius = 13
        cardLayer.masksToBounds = false
        cardLayer.borderWidth = 1
        cardLayer.borderColor = NSColor(calibratedWhite: 0.72, alpha: 1).cgColor
        cardLayer.backgroundColor = NSColor.white.cgColor
        cardLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(cardLayer)

        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.alignmentMode = .left
        textLayer.isWrapped = true
        textLayer.truncationMode = .none
        cardLayer.addSublayer(textLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 更新文字并返回卡片高度；cardTopInset 是卡片顶部相对 overlay 顶部的距离
    @discardableResult
    func update(text: String, emphasized: Bool, cardWidth: CGFloat) -> CGFloat {
        let padding = Self.padding
        let font = NSFont.systemFont(ofSize: emphasized ? 13.5 : 12.5, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
            .paragraphStyle: para
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textW = cardWidth - padding * 2
        let bound = attr.boundingRect(with: NSSize(width: textW, height: 10000),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textH = ceil(bound.height)
        let cardH = textH + padding * 2

        cardLayer.borderWidth = emphasized ? 1.8 : 1
        cardLayer.borderColor = emphasized
            ? accent.withAlphaComponent(0.85).cgColor
            : NSColor(calibratedWhite: 0.72, alpha: 1).cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // overlay 坐标系原点左下；卡片贴 overlay 顶部，底部留出尾巴空间
        let cardY = max(bounds.height - cardH - Self.tailHeight, Self.tailHeight)
        cardLayer.frame = CGRect(x: 0, y: cardY, width: cardWidth, height: cardH)
        textLayer.frame = CGRect(x: padding, y: padding, width: textW, height: textH)
        textLayer.string = attr
        CATransaction.commit()
        return cardH
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.backgroundColor = NSColor.clear.cgColor
        cardLayer.borderWidth = 0
        textLayer.string = ""
        CATransaction.commit()
    }

    /// 恢复白色卡片背景（clear 之后再次显示时调用）
    func restoreBackground() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.backgroundColor = NSColor.white.cgColor
        CATransaction.commit()
    }
}
