import Cocoa

/// 同一菜单栏按钮中上下排列鱼形图标和电量，整块区域仍使用系统原生菜单按钮。
@MainActor
enum PetStatusIcon {
    static func image(showBattery: Bool, reading: BatteryReading?, stale: Bool) -> NSImage {
        let color = NSColor.black
        let fish = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "LuckyPet")
            ?? makeFishIcon()
        fish.isTemplate = true
        guard showBattery else { return fish }

        let size = NSSize(width: 30, height: 22)
        let text = reading.map { "\($0.percent)%" } ?? "—"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        // 失联读数降低透明度；使用模板图像，自动适配深浅菜单栏与菜单按下高亮。
        let image = NSImage(size: size, flipped: false) { _ in
            color.set()
            fish.draw(in: NSRect(x: 8, y: 11, width: 14, height: 10),
                      from: .zero, operation: .sourceOver, fraction: 1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color.withAlphaComponent(stale ? 0.5 : 1)
            ]
            let title = NSAttributedString(string: text, attributes: attributes)
            title.draw(at: NSPoint(x: (size.width - title.size().width) / 2, y: 0))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 自绘鱼形托盘图标（SF Symbol 不可用时的兜底）
    private static func makeFishIcon() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            let body = NSBezierPath(ovalIn: NSRect(x: 0.5, y: 3, width: 11.5, height: 10))
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 11, y: 8))
            tail.line(to: NSPoint(x: 17, y: 2.5))
            tail.line(to: NSPoint(x: 17, y: 13.5))
            tail.close()
            body.append(tail)
            NSColor.black.setFill()
            body.fill()
            return true
        }
        img.isTemplate = true
        return img
    }

}
