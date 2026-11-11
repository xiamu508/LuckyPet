import Cocoa

@main
struct MouseBatteryTests {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // 完整旧配置中没有电量字段，其他用户设置应全部保持原值。
        var original = Preferences()
        original.intervalMinutes = 90
        original.petScale = 0.95
        original.quietStart = "14:15"
        original.reminderMessages = ["自定义提醒"]
        original.preferredDisplayID = 42
        original.lastPositionX = 123
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        legacy.removeValue(forKey: "showMouseBattery")
        var restored = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(!restored.showMouseBattery)
        precondition(restored.intervalMinutes == 90 && restored.petScale == 0.95)
        precondition(restored.quietStart == "14:15" && restored.reminderMessages == ["自定义提醒"])
        precondition(restored.preferredDisplayID == 42 && restored.lastPositionX == 123)
        restored.showMouseBattery = true
        let roundtrip = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(restored))
        precondition(roundtrip.showMouseBattery && roundtrip.intervalMinutes == 90)

        var completions: [(Result<BatteryReading, BatteryError>) -> Void] = []
        let monitor = MouseBatteryMonitor { completions.append($0) }
        monitor.refresh()
        precondition(completions.isEmpty, "关闭模块时不得读取 HID")
        monitor.setEnabled(true)
        precondition(completions.count == 1 && monitor.isRefreshing)
        monitor.refresh()
        precondition(completions.count == 1, "读取中不得重复发出请求")
        let full = BatteryReading(percent: 100, charging: false, timestamp: Date(), productName: "MCHOSE A5", productID: 0xF013)
        completions[0](.success(full))
        pump()
        precondition(monitor.reading?.percent == 100 && monitor.lastError == nil)
        precondition(abs((monitor.nextRefreshDate?.timeIntervalSinceNow ?? 0) - 3600) < 2)

        monitor.refresh()
        precondition(completions.count == 2)
        completions[1](.failure(.mouseOffline))
        pump()
        precondition(monitor.reading?.percent == 100 && monitor.lastError?.isMouseOffline == true)
        precondition(monitor.statusText.contains("上次读数"))
        precondition(abs((monitor.nextRefreshDate?.timeIntervalSinceNow ?? 0) - 3600) < 2,
                     "读取失败也须每小时刷新，不使用参考 App 的秒级重试")

        monitor.refresh()
        monitor.setEnabled(false)
        precondition(monitor.nextRefreshDate == nil && !monitor.isRefreshing)
        monitor.setEnabled(true)
        precondition(completions.count == 4)
        completions[2](.success(BatteryReading(percent: 1, charging: false, timestamp: Date(), productName: "过期请求", productID: 0xF013)))
        pump()
        precondition(monitor.isRefreshing && monitor.reading?.percent == 100, "忽略关闭前的迟到结果")
        completions[3](.success(BatteryReading(percent: 86, charging: true, timestamp: Date(), productName: "MCHOSE A5", productID: 0xF019)))
        pump()
        precondition(monitor.reading?.percent == 86 && monitor.lastError == nil && !monitor.isRefreshing)
        precondition(monitor.statusText.contains("充电中"))
        monitor.setEnabled(false)
        let callsBefore = completions.count
        pump()
        precondition(completions.count == callsBefore && monitor.nextRefreshDate == nil)

        let empty = MouseBatteryMonitor { $0(.failure(.noDevice)) }
        empty.setEnabled(true)
        pump()
        precondition(empty.reading == nil && empty.statusText.contains("未获取"))
        empty.setEnabled(false)

        // 以 2× 原生像素导出实际使用的图标，并生成明暗外观对照供视觉验收。
        let examples: [(String, Bool, BatteryReading?, Bool)] = [
            ("关闭", false, nil, false), ("100%", true, full, false),
            ("86% 充电", true, monitor.reading, false),
            ("20%", true, BatteryReading(percent: 20, charging: false, timestamp: Date(), productName: "MCHOSE", productID: 0xF013), false),
            ("失联上次读数", true, full, true), ("尚未获取", true, nil, false)
        ]
        let sheet = NSImage(size: NSSize(width: 720, height: 180), flipped: false) { _ in
            for (row, dark) in [false, true].enumerated() {
                let y = CGFloat(1 - row) * 90
                (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: 720, height: 90).fill()
                for (index, example) in examples.enumerated() {
                    let icon = renderedButton(PetStatusIcon.image(showBattery: example.1, reading: example.2, stale: example.3), dark: dark)
                    let rect = NSRect(x: CGFloat(index) * 120 + 43, y: y + 39, width: 34, height: 24)
                    icon.draw(in: rect)
                    let text = NSAttributedString(string: example.0, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dark ? NSColor.white : NSColor.black])
                    text.draw(at: NSPoint(x: CGFloat(index) * 120 + (120 - text.size().width) / 2, y: y + 15))
                }
            }
            return true
        }
        try savePNG(sheet, to: output.appendingPathComponent("status-icons.png"), scale: 2)
        for (index, example) in examples.enumerated() {
            try savePNG(PetStatusIcon.image(showBattery: example.1, reading: example.2, stale: example.3),
                        to: output.appendingPathComponent("icon-\(index).png"), scale: 2)
        }
        print("PASS: 旧配置迁移、电量设置持久化、首次读取、每小时调度、失败读数、关闭与迟到回调、图标渲染")
    }

    @MainActor
    static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    @MainActor
    static func renderedButton(_ image: NSImage, dark: Bool) -> NSImage {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 24))
        button.isBordered = false
        button.image = image
        button.imagePosition = .imageOnly
        button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        button.contentTintColor = dark ? .white : .black
        let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds)!
        button.cacheDisplay(in: button.bounds, to: bitmap)
        let result = NSImage(size: button.bounds.size)
        result.addRepresentation(bitmap)
        return result
    }

    @MainActor
    static func savePNG(_ image: NSImage, to url: URL, scale: CGFloat) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                                      pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
