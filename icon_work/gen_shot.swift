import AppKit

// 生成 README 展示图：渐变背景 + 角色 + 气泡（无桌面杂物）
let S: CGFloat = 2                     // 2x 渲染
let W: CGFloat = 900, H: CGFloat = 880
let pxW = Int(W * S), pxH = Int(H * S)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: pxW, pixelsHigh: pxH,
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.cgContext.scaleBy(x: S, y: S)

let accent = NSColor(calibratedRed: 0.38, green: 0.55, blue: 0.90, alpha: 1)

// 1. 背景：深蓝对角渐变
NSGradient(colors: [
    NSColor(calibratedRed: 0.118, green: 0.175, blue: 0.320, alpha: 1),
    NSColor(calibratedRed: 0.032, green: 0.048, blue: 0.100, alpha: 1)
])?.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -66)

// 2. 中央柔光（径向渐变，无硬边）
let glowRect = NSRect(x: -260, y: -300, width: 1420, height: 1420)
NSGradient(colors: [
    NSColor(calibratedRed: 0.45, green: 0.60, blue: 0.90, alpha: 0.16),
    NSColor(calibratedRed: 0.45, green: 0.60, blue: 0.90, alpha: 0.0)
])?.draw(in: glowRect, relativeCenterPosition: .zero)

// 3. 地面阴影：桌宠为悬浮形态，此处留空

// 4. 角色（1 秒处，睁眼）
if let img = NSImage(contentsOfFile: "/tmp/char_clean.png") {
    let h: CGFloat = 592
    let w = h * 660.0 / 630.0
    img.draw(in: NSRect(x: (W - w) / 2, y: 34, width: w, height: h),
             from: .zero, operation: .sourceOver, fraction: 1.0)
}

// 5. 气泡
let bubbleW: CGFloat = 566
let bubbleH: CGFloat = 140
let bx = (W - bubbleW) / 2
let by: CGFloat = 654
let path = NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bubbleW, height: bubbleH),
                        xRadius: 19, yRadius: 19)

// 尾巴（先填充白色，再补两侧描边）
let cx = W / 2
let tail = NSBezierPath()
tail.move(to: NSPoint(x: cx - 13, y: by + 2))
tail.line(to: NSPoint(x: cx, y: by - 17))
tail.line(to: NSPoint(x: cx + 13, y: by + 2))
tail.close()
NSColor.white.setFill()
tail.fill()

NSColor.white.setFill()
path.fill()

accent.setStroke()
path.lineWidth = 2.2
path.stroke()

let tailStroke = NSBezierPath()
tailStroke.move(to: NSPoint(x: cx - 13, y: by + 1))
tailStroke.line(to: NSPoint(x: cx, y: by - 17))
tailStroke.line(to: NSPoint(x: cx + 13, y: by + 1))
tailStroke.lineWidth = 2.2
tailStroke.stroke()

// 6. 文字
let text = "已经坐了好久啦\n起来站一会儿嘛喵～"
let para = NSMutableParagraphStyle()
para.lineSpacing = 8
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 21, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.13, alpha: 1),
    .paragraphStyle: para
]
let attr = NSAttributedString(string: text, attributes: attrs)
let bound = attr.boundingRect(with: NSSize(width: bubbleW - 56, height: 600),
                              options: [.usesLineFragmentOrigin, .usesFontLeading])
let ty = by + (bubbleH - bound.height) / 2
attr.draw(with: NSRect(x: bx + 28, y: ty, width: bubbleW - 56, height: bound.height),
          options: [.usesLineFragmentOrigin, .usesFontLeading])

NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: "docs/screenshot.png"))
print("展示图已生成: docs/screenshot.png  \(pxW)x\(pxH)")
