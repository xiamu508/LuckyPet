import AppKit

// 生成 1024×1024 应用图标：圆角深蓝渐变底 + 角色立绘
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: px, pixelsHigh: px,
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

let S = CGFloat(px)
let inset: CGFloat = 88
let rect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius: CGFloat = 190
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// 外阴影
let shadow = NSShadow()
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
shadow.set()
NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.30, alpha: 1).setFill()
path.fill()

// 渐变底
NSGraphicsContext.saveGraphicsState()
path.addClip()
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.21, green: 0.34, blue: 0.62, alpha: 1),
    NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.23, alpha: 1)
])
grad?.draw(in: rect, angle: -90)

// 顶部高光
let glow = NSBezierPath(ovalIn: NSRect(x: S * 0.12, y: S * 0.55, width: S * 0.76, height: S * 0.55))
NSColor.white.withAlphaComponent(0.10).setFill()
glow.fill()
NSGraphicsContext.restoreGraphicsState()

// 内描边
let border = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
NSColor.white.withAlphaComponent(0.16).setStroke()
border.lineWidth = 3
border.stroke()

// 角色
if let img = NSImage(contentsOfFile: "icon_work/char.png") {
    let hide = S * 0.66
    let w = hide * 330.0 / 315.0
    let dest = NSRect(x: (S - w) / 2, y: inset + 30, width: w, height: hide)
    img.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1.0)
}

NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: "icon_work/icon_1024.png"))
print("图标已生成 icon_work/icon_1024.png")
