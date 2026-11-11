import Cocoa

@MainActor
private final class TestBluetooth: BluetoothBatteryProviding {
    var devices: [String: BatteryDevice] = [:]
    var isScanning = false
    var isRefreshing = false
    var status = "蓝牙已开启。新耳机、键盘或手柄可在系统蓝牙设置中配对。"
    var onChange: (() -> Void)?
    var active = false
    var refreshes = 0
    var connectedID: String?
    func start(selectedID: String) { active = true }
    func stop() { active = false }
    func refresh() { refreshes += 1 }
    func scan() { isScanning = true; onChange?() }
    func connect(_ id: String) { connectedID = id; devices[id]?.connection = .connecting; onChange?() }
}

@main
struct DeviceBatteryTests {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = #"""
        {"SPBluetoothDataType":[{
          "device_connected":[
            {"AirPods Pro":{"device_address":"AA-BB-CC-DD-EE-01","device_minorType":"Headphones",
              "device_batteryLevelLeft":"72%","device_batteryLevelRight":"65%","device_batteryLevelCase":"90%"}},
            {"Magic Keyboard":{"device_address":"AA:BB:CC:DD:EE:02","device_minorType":"Keyboard","device_batteryLevelMain":"0%"}},
            {"同名设备":{"device_address":"AA-BB-CC-DD-EE-03","device_batteryLevelMain":"38%"}},
            {"同名设备":{"device_address":"AA-BB-CC-DD-EE-04","device_batteryLevelMain":"未提供"}},
            {"仅充电盒":{"device_address":"AA-BB-CC-DD-EE-06","device_batteryLevelCase":"80%"}}
          ],
          "device_not_connected":[
            {"Xbox Wireless Controller":{"device_address":"AA-BB-CC-DD-EE-05","device_batteryLevelMain":"91%"}}
          ]
        }]}
        """#
        let snapshot = BluetoothBatterySnapshot.devices(from: Data(fixture.utf8))
        precondition(snapshot.count == 6)
        let headphones = snapshot.first { $0.id == "bt:aabbccddee01" }!
        let keyboard = snapshot.first { $0.id == "bt:aabbccddee02" }!
        let controller = snapshot.first { $0.id == "bt:aabbccddee05" }!
        precondition(headphones.reading?.percent == 65 && headphones.components.count == 3)
        precondition(keyboard.reading?.percent == 0 && keyboard.kind == "键盘")
        precondition(controller.reading == nil && controller.connection == .disconnected && controller.kind == "手柄")
        precondition(snapshot.first { $0.id == "bt:aabbccddee04" }?.reading == nil, "不能把同名设备的电量混用")
        precondition(snapshot.first { $0.id == "bt:aabbccddee06" }?.reading == nil, "盒电量不能当作耳机电量")
        precondition(BluetoothBatterySnapshot.percent(true) == nil)
        precondition(BluetoothBatterySnapshot.percent(65.5) == nil)
        precondition(BluetoothBatterySnapshot.address("xAA-BB-CC-DD-EE-01") == nil)
        precondition(BluetoothBatterySnapshot.percent("101%") == nil)
        precondition(BluetoothBatterySnapshot.percent("-1%") == nil)
        precondition(BluetoothBatterySnapshot.percent("不支持") == nil)
        precondition(BluetoothBatterySnapshot.devices(from: Data("{}".utf8)).isEmpty)
        let alternateFixture = #"""
        {"SPBluetoothDataType":[{"device_connected":{
          "MCHOSE A5 5.0":{"BluetoothAddress":"AA:BB:CC:DD:EE:07","device_minorType":"Mouse",
            "battery":{"BatteryLevel":0.92}},
          "StadiaZHGY-1c91":{"BD_ADDR":"AA:BB:CC:DD:EE:08","device_minorType":"Controller",
            "BatteryPercent":88}
        }}]}
        """#
        let alternate = BluetoothBatterySnapshot.devices(from: Data(alternateFixture.utf8))
        precondition(alternate.first { $0.name == "MCHOSE A5 5.0" }?.reading?.percent == 92,
                     "HID 比例电量应转换成百分数")
        precondition(alternate.first { $0.name == "StadiaZHGY-1c91" }?.reading?.percent == 88 &&
                     alternate.first { $0.name == "StadiaZHGY-1c91" }?.kind == "手柄",
                     "手柄的系统电量字段应被识别")

        var callbacks: [(Result<BatteryReading, BatteryError>) -> Void] = []
        let mouse = MouseBatteryMonitor { callbacks.append($0) }
        let bluetooth = TestBluetooth()
        bluetooth.devices = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        let monitor = DeviceBatteryMonitor(mouse: mouse, bluetooth: bluetooth)
        monitor.configure(enabled: false, selectedID: nil, selectedName: nil)
        precondition(!mouse.isEnabled && !bluetooth.active && callbacks.isEmpty)
        monitor.setEnabled(true)
        precondition(mouse.isEnabled && callbacks.count == 1 && !bluetooth.active,
                     "只显示专用鼠标时不应启动蓝牙或请求蓝牙权限")
        monitor.configure(enabled: true, selectedID: headphones.id, selectedName: headphones.name)
        precondition(!mouse.isEnabled && bluetooth.active && monitor.reading?.percent == 65)
        callbacks[0](.success(BatteryReading(percent: 99, charging: false, timestamp: Date(), productName: "MCHOSE", productID: 1)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(monitor.reading?.percent == 65, "切换后的迟到鼠标回调不能覆盖耳机读数")
        monitor.configure(enabled: true, selectedID: keyboard.id, selectedName: keyboard.name)
        precondition(monitor.reading?.percent == 0 && monitor.statusText.contains("Magic Keyboard"))
        monitor.configure(enabled: true, selectedID: controller.id, selectedName: controller.name)
        precondition(monitor.reading == nil && !monitor.isStale, "无读数设备必须显示未知，不能沿用前一设备")
        monitor.configure(enabled: true, selectedID: headphones.id, selectedName: headphones.name)
        bluetooth.devices[headphones.id]?.connection = .disconnected
        precondition(monitor.isStale && monitor.statusText.contains("上次读数"))
        bluetooth.devices[headphones.id]?.connection = .connected
        monitor.configure(enabled: true, selectedID: "ble:absent", selectedName: "已记住的键盘")
        precondition(monitor.selectedDevice.name == "已记住的键盘" && monitor.reading == nil)
        monitor.refresh()
        precondition(bluetooth.refreshes == 1 && callbacks.count == 1)
        monitor.setEnabled(false)
        precondition(!bluetooth.active && !mouse.isEnabled)
        monitor.setBrowsing(true)
        precondition(bluetooth.active && mouse.isEnabled)
        callbacks.last?(.failure(.noDevice))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        monitor.setBrowsing(false)
        precondition(!bluetooth.active && !mouse.isEnabled)

        var prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"showMouseBattery":true,"intervalMinutes":90}"#.utf8))
        precondition(prefs.showMouseBattery && prefs.batteryDeviceID == nil && prefs.intervalMinutes == 90)
        prefs.batteryDeviceID = headphones.id
        prefs.batteryDeviceName = headphones.name
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        precondition(restored.batteryDeviceID == headphones.id && restored.batteryDeviceName == headphones.name)

        // 通过真实 AppKit 按钮验证选择、连接和开关，同时导出面板预览。
        var selected: String?
        let panel = BatteryDevicesWindowController(monitor: monitor, selectDevice: { device in
            selected = device.id
            monitor.configure(enabled: true, selectedID: device.id, selectedName: device.name)
        }, toggleEnabled: { monitor.setEnabled(!monitor.isEnabled) })
        monitor.onChange = { panel.update() }
        monitor.configure(enabled: false, selectedID: headphones.id, selectedName: headphones.name)
        panel.show()
        let window = app.windows.first { $0.title == "LuckyPet · 设备与电量" }!
        window.setContentSize(NSSize(width: 620, height: 720))
        window.contentView!.layoutSubtreeIfNeeded()
        let keyboardSelect = descendants(window.contentView!).compactMap { $0 as? NSButton }.first {
            $0.title == "显示电量" && $0.identifier?.rawValue == keyboard.id
        }!
        keyboardSelect.performClick(nil)
        precondition(selected == keyboard.id && monitor.isEnabled && monitor.reading?.percent == 0)
        let controllerConnect = descendants(window.contentView!).compactMap { $0 as? NSButton }.first {
            $0.title == "连接" && $0.identifier?.rawValue == controller.id
        }!
        controllerConnect.performClick(nil)
        precondition(bluetooth.connectedID == controller.id && bluetooth.devices[controller.id]?.connection == .connecting)
        let toggle = descendants(window.contentView!).compactMap { $0 as? NSButton }.first {
            $0.title == "菜单栏显示设备电量"
        }!
        toggle.performClick(nil)
        precondition(!monitor.isEnabled && bluetooth.active, "浏览面板期间关闭托盘仍能管理设备")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView!.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let view = window.contentView!
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("devices-\(appearance.rawValue).png"))
        }
        window.performClose(nil)
        precondition(!bluetooth.active && !mouse.isEnabled)
        monitor.onChange = nil
        let report: [String: Any] = ["passed": true, "checks": [
            "左右耳及充电盒分别显示", "0%有效与无效数据拒绝", "HID 比例字段与手柄字段识别", "同名设备地址隔离", "断连设备不采信缓存电量",
            "只显示充电盒不冒充耳机电量", "切换设备与迟到回调隔离", "上次读数标识", "缺席设备记忆",
            "旧配置迁移与设备选择持久化", "专用鼠标不开启蓝牙", "关闭与浏览生命周期", "真实按钮选择连接开关", "明暗面板预览"
        ]]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("tests.json"))
        print(String(data: data, encoding: .utf8)!)
    }

    @MainActor
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
