import Cocoa

/// 直接启动真实 AppDelegate，以隔离配置验证菜单与设置互相同步。
@main
struct MouseBatteryIntegrationTests {
    @MainActor
    static func main() {
        precondition(ProcessInfo.processInfo.environment["LUCKY_PET_CONFIG_DIR"] != nil,
                     "界面测试必须指定隔离配置目录")
        Preferences().save()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let status: NSStatusItem = property("statusItem", of: delegate)
            let monitor: MouseBatteryMonitor = property("mouseBattery", of: delegate)
            let menu = status.menu!
            delegate.menuNeedsUpdate(menu)
            let toggle = menu.items.first { $0.title == "显示设备电量" }!
            precondition(toggle.state == .off && !monitor.isEnabled)
            precondition(app.sendAction(toggle.action!, to: toggle.target, from: toggle))
            precondition(monitor.isEnabled && status.length == 34)
            precondition(status.button?.image?.size == NSSize(width: 30, height: 22))
            precondition(Preferences.load().showMouseBattery)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                precondition(!monitor.isRefreshing && monitor.nextRefreshDate != nil)
                precondition(abs((monitor.nextRefreshDate?.timeIntervalSinceNow ?? 0) - 3600) < 4)
                delegate.menuNeedsUpdate(menu)
                precondition(menu.items.first { $0.title == toggle.title }?.state == .on)
                precondition(menu.items.contains { $0.title == "立即刷新设备电量" })
                if let reading = monitor.reading {
                    precondition(status.button?.toolTip?.contains("\(reading.percent)%") == true)
                }
                let settingsItem = menu.items.first { $0.title == "提醒设置…" }!
                precondition(app.sendAction(settingsItem.action!, to: settingsItem.target, from: settingsItem))
                let controller: SettingsWindowController = property("settings", of: delegate)
                let window: NSWindow = property("window", of: controller)
                let checkbox = descendants(window.contentView!).compactMap { $0 as? NSButton }
                    .first { $0.title == "菜单栏显示设备电量" }!
                precondition(checkbox.state == .on)
                checkbox.performClick(nil)
                precondition(!monitor.isEnabled && monitor.nextRefreshDate == nil)
                precondition(!Preferences.load().showMouseBattery)
                precondition(status.length == NSStatusItem.squareLength)
                delegate.menuNeedsUpdate(menu)
                precondition(menu.items.first { $0.title == toggle.title }?.state == .off)
                precondition(!menu.items.contains { $0.title == "立即刷新设备电量" })

                // 菜单重新开启后，已经打开的设置窗口也必须同步勾选。
                let enable = menu.items.first { $0.title == toggle.title }!
                precondition(app.sendAction(enable.action!, to: enable.target, from: enable))
                precondition(checkbox.state == .on && Preferences.load().showMouseBattery)
                let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                if let scroll = descendants(window.contentView!).first(where: { $0 is NSScrollView }) as? NSScrollView {
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                window.contentView!.layoutSubtreeIfNeeded()
                let content = window.contentView!
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("settings.png"))
                }
                let report: [String: Any] = [
                    "passed": true, "hourlyInterval": MouseBatteryMonitor.refreshInterval,
                    "devicePercent": monitor.reading?.percent as Any? ?? NSNull(),
                    "deviceError": monitor.lastError?.localizedDescription as Any? ?? NSNull(),
                    "checks": ["菜单开启与持久化", "图标上下布局", "每小时调度", "设置关闭同步菜单", "菜单开启同步已打开设置"]
                ]
                let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try! data.write(to: output.appendingPathComponent("integration.json"))
                print(String(data: data, encoding: .utf8)!)
                monitor.setEnabled(false)
                window.orderOut(nil)
                app.terminate(nil)
            }
        }
        app.run()
    }

    static func property<T>(_ label: String, of object: Any) -> T {
        Mirror(reflecting: object).children.first { $0.label == label }!.value as! T
    }

    @MainActor
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
