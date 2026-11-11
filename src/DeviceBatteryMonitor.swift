import Cocoa

@MainActor
protocol BluetoothBatteryProviding: AnyObject {
    var devices: [String: BatteryDevice] { get }
    var isScanning: Bool { get }
    var isRefreshing: Bool { get }
    var status: String { get }
    var onChange: (() -> Void)? { get set }
    func start(selectedID: String)
    func stop()
    func refresh()
    func scan()
    func connect(_ id: String)
}

extension BluetoothBatteryService: BluetoothBatteryProviding {}

/// 将原有专用鼠标读数和通用蓝牙读数放在同一个设备列表中，托盘只显示选中设备。
@MainActor
final class DeviceBatteryMonitor {
    let mouse: MouseBatteryMonitor
    let bluetooth: any BluetoothBatteryProviding
    private(set) var selectedID = BatteryDevice.mouseID
    private var selectedName = "MCHOSE A5 Pro Max"
    private(set) var isEnabled = false
    private var browsing = false
    var onChange: (() -> Void)?

    convenience init() { self.init(mouse: MouseBatteryMonitor(), bluetooth: BluetoothBatteryService()) }

    init(mouse: MouseBatteryMonitor, bluetooth: any BluetoothBatteryProviding) {
        self.mouse = mouse
        self.bluetooth = bluetooth
        mouse.onChange = { [weak self] in self?.onChange?() }
        bluetooth.onChange = { [weak self] in self?.onChange?() }
    }

    var devices: [BatteryDevice] {
        let mouse = BatteryDevice(id: BatteryDevice.mouseID, name: "MCHOSE A5 Pro Max", kind: "鼠标",
                                  connection: mouse.reading != nil && mouse.lastError == nil ? .connected : .disconnected,
                                  reading: mouse.reading, message: mouse.lastError?.localizedDescription)
        var result = [mouse] + bluetooth.devices.values.sorted {
            if $0.connection == .connected && $1.connection != .connected { return true }
            if $1.connection == .connected && $0.connection != .connected { return false }
            return $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if !result.contains(where: { $0.id == selectedID }) {
            result.append(BatteryDevice(id: selectedID, name: selectedName,
                                        kind: BatteryDevice.kind(name: selectedName),
                                        message: "已记住选择，设备当前不可用。请连接设备后刷新。"))
        }
        return result
    }

    var selectedDevice: BatteryDevice { devices.first { $0.id == selectedID }! }
    var reading: BatteryReading? { selectedDevice.reading }
    var isStale: Bool { selectedDevice.isStale }
    var isRefreshing: Bool { selectedID == BatteryDevice.mouseID ? mouse.isRefreshing : bluetooth.isRefreshing }
    var statusText: String {
        let device = selectedDevice
        return "\(device.name) · \(isRefreshing ? "正在读取…" : device.detail)"
    }
    var toolTip: String {
        var lines = ["LuckyPet · 久坐提醒", statusText]
        if let reading { lines.append("更新于 \(MouseBatteryMonitor.timeFormatter.string(from: reading.timestamp))") }
        if !selectedDevice.components.isEmpty { lines.append(selectedDevice.components.joined(separator: " · ")) }
        if let message = selectedDevice.message { lines.append(message) }
        lines.append(selectedID == BatteryDevice.mouseID ? "每小时自动刷新" : "每分钟同步系统电量；支持的 BLE 设备自动推送")
        return lines.joined(separator: "\n")
    }

    func configure(enabled: Bool, selectedID: String?, selectedName: String?) {
        self.selectedID = selectedID ?? BatteryDevice.mouseID
        self.selectedName = selectedName ?? "MCHOSE A5 Pro Max"
        isEnabled = enabled
        synchronizeServices()
        onChange?()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        synchronizeServices()
        onChange?()
    }

    func setBrowsing(_ browsing: Bool) {
        self.browsing = browsing
        synchronizeServices()
        onChange?()
    }

    private func synchronizeServices() {
        mouse.setEnabled((isEnabled && selectedID == BatteryDevice.mouseID) || browsing)
        if (isEnabled && selectedID != BatteryDevice.mouseID) || browsing {
            bluetooth.start(selectedID: selectedID)
        } else { bluetooth.stop() }
    }

    func refresh() {
        if browsing || selectedID == BatteryDevice.mouseID { mouse.refresh() }
        if browsing || selectedID != BatteryDevice.mouseID { bluetooth.refresh() }
    }
}
