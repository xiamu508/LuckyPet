import Cocoa
@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth
import IOKit
import GameController

/// 经典蓝牙由系统配对列表提供；BLE 仅在用户主动扫描或选择时连接。
@MainActor
final class BluetoothBatteryService: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private(set) var devices: [String: BatteryDevice] = [:]
    private(set) var isScanning = false
    private(set) var isRefreshing = false
    private(set) var status = "连接已配对设备，或扫描附近的低功耗蓝牙设备。"
    var onChange: (() -> Void)?
    private var central: CBCentralManager?
    private var peripherals: [String: CBPeripheral] = [:]
    private var ownedConnections: Set<UUID> = []
    private var connectionTimeouts: [UUID: Timer] = [:]
    private var scanTimer: Timer?
    private var timer: Timer?
    private var running = false
    private var generation = 0
    private var pendingScan = false
    private var pendingID: String?
    private var controllerIDs: [ObjectIdentifier: String] = [:]
    private let worker = DispatchQueue(label: "com.jiean.luckypet.bluetooth", qos: .utility)
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")

    func start(selectedID: String) {
        pendingID = selectedID
        guard !running else { restoreSelectedPeripheral(); return }
        running = true
        generation += 1
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        running = false
        generation += 1
        timer?.invalidate()
        timer = nil
        stopScan()
        pendingScan = false
        connectionTimeouts.values.forEach { $0.invalidate() }
        connectionTimeouts.removeAll()
        for peripheral in peripherals.values where ownedConnections.contains(peripheral.identifier) {
            central?.cancelPeripheralConnection(peripheral)
        }
        ownedConnections.removeAll()
        central?.delegate = nil
        central = nil
        peripherals.values.forEach { $0.delegate = nil }
        peripherals.removeAll()
        isRefreshing = false
        for id in devices.keys { devices[id]?.connection = .disconnected }
    }

    func refresh() {
        guard running, !isRefreshing else { return }
        isRefreshing = true
        updatePairedDevices()
        updateControllers()
        if central?.state == .poweredOn {
            for peripheral in central?.retrieveConnectedPeripherals(withServices: [batteryService]) ?? [] {
                register(peripheral)
                read(peripheral)
            }
            for peripheral in peripherals.values where peripheral.state == .connected { read(peripheral) }
        }
        let requestGeneration = generation
        let existingDevices = Array(devices.values)
        onChange?()
        worker.async { [weak self] in
            let snapshot = Self.systemSnapshot(existingDevices: existingDevices)
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == requestGeneration else { return }
                if let snapshot {
                    for device in snapshot {
                        // 连接状态以实时配对列表为准，系统报告的历史缓存不当成新读数。
                        if var existing = self.devices[device.id] {
                            if existing.connection == .connected, device.connection == .connected {
                                if let reading = device.reading { existing.reading = reading; existing.message = nil }
                                else if existing.reading != nil { existing.message = "当前未获取到新的电量，保留上次读数。" }
                                existing.components = device.components
                            } else if existing.connection == .connected, existing.reading != nil {
                                existing.message = "系统暂未提供当前电量，保留上次读数。"
                            }
                            self.devices[device.id] = existing
                        } else { self.devices[device.id] = device }
                    }
                }
                if snapshot == nil {
                    for id in self.devices.keys where id.hasPrefix("bt:") && self.devices[id]?.reading != nil {
                        self.devices[id]?.message = "系统电量读取失败，保留上次读数；请稍后刷新。"
                    }
                }
                self.isRefreshing = false
                self.onChange?()
            }
        }
    }

    func scan() {
        pendingScan = true
        guard let central, central.state == .poweredOn else { onChange?(); return }
        pendingScan = false
        stopScan()
        isScanning = true
        status = "正在扫描附近设备…请让设备进入配对模式。"
        // 很多键盘和手柄不在广播包中声明电池服务，所以不能只按 180F 过滤。
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopScan()
                self?.status = "扫描完成。未找到设备时，请在系统蓝牙设置中配对后刷新。"
                self?.onChange?()
            }
        }
        onChange?()
    }

    private func stopScan() {
        central?.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        isScanning = false
    }

    func connect(_ id: String) {
        guard running, devices[id]?.connection != .connecting else { return }
        if id.hasPrefix("ble:"), let peripheral = peripherals[id], let central, central.state == .poweredOn {
            if peripheral.state == .connected { read(peripheral); return }
            devices[id]?.connection = .connecting
            devices[id]?.message = nil
            ownedConnections.insert(peripheral.identifier)
            central.connect(peripheral)
            connectionTimeouts[peripheral.identifier] = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self, weak peripheral] _ in
                Task { @MainActor in
                    guard let self, let peripheral, peripheral.state == .connecting else { return }
                    self.central?.cancelPeripheralConnection(peripheral)
                    self.devices[id]?.connection = .disconnected
                    self.devices[id]?.message = "连接超时，请唤醒设备后重试，或在系统蓝牙设置中完成配对。"
                    self.onChange?()
                }
            }
        } else if id.hasPrefix("bt:"),
                  let device = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: {
                      Self.deviceID($0) == id
                  }) {
            devices[id]?.connection = .connecting
            devices[id]?.message = nil
            let requestGeneration = generation
            worker.async { [weak self] in
                let result = device.openConnection(nil, withPageTimeout: 0x2000, authenticationRequired: true)
                DispatchQueue.main.async {
                    guard let self, self.running, self.generation == requestGeneration else { return }
                    let connected = device.isConnected()
                    self.devices[id]?.connection = connected ? .connected : .disconnected
                    self.devices[id]?.message = connected ? nil : "连接失败（\(result)）。请开启设备，或在系统蓝牙设置中重新配对。"
                    self.refresh()
                    self.onChange?()
                }
            }
        }
        onChange?()
    }

    private static func deviceID(_ device: IOBluetoothDevice) -> String? {
        guard let raw = device.addressString, let address = BluetoothBatterySnapshot.address(raw) else { return nil }
        return "bt:\(address)"
    }

    private func updatePairedDevices() {
        var seen: Set<String> = []
        for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] {
            guard let id = Self.deviceID(device) else { continue }
            seen.insert(id)
            let name = device.name ?? "未命名蓝牙设备"
            var entry = devices[id] ?? BatteryDevice(id: id, name: name, kind: BatteryDevice.kind(name: name))
            entry.name = name
            if entry.connection != .connecting { entry.connection = device.isConnected() ? .connected : .disconnected }
            devices[id] = entry
        }
        for id in devices.keys where id.hasPrefix("bt:") && !seen.contains(id) {
            devices[id]?.connection = .disconnected
        }
    }

    /// GameController 对部分 Xbox / DualSense 手柄提供电量，且无需依赖私有 HID 协议。
    private func updateControllers() {
        let controllers = GCController.controllers()
        let active = Set(controllers.map { ObjectIdentifier($0) })
        for (key, id) in controllerIDs where !active.contains(key) {
            devices[id]?.connection = .disconnected
            controllerIDs.removeValue(forKey: key)
        }
        for controller in controllers {
            let key = ObjectIdentifier(controller)
            let id = controllerIDs[key] ?? "gc:\(UUID().uuidString)"
            controllerIDs[key] = id
            let name = controller.vendorName ?? controller.productCategory
            var entry = devices[id] ?? BatteryDevice(id: id, name: name, kind: "手柄")
            entry.connection = .connected
            if let battery = controller.battery, battery.batteryState != .unknown,
               battery.batteryLevel.isFinite, (0...1).contains(battery.batteryLevel) {
                entry.reading = BatteryReading(percent: Int((battery.batteryLevel * 100).rounded()),
                                               charging: battery.batteryState == .charging,
                                               timestamp: Date(), productName: name, productID: 0)
                entry.message = nil
            } else if entry.reading != nil { entry.message = "手柄当前未提供有效电量，保留上次读数。" }
            devices[id] = entry
        }
    }

    // system_profiler 兼容系统提供的耳机左右耳 / 充电盒电量；IORegistry 补充 HID 键鼠电量。
    nonisolated private static func systemSnapshot(existingDevices: [BatteryDevice] = []) -> [BatteryDevice]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "8"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        var devices: [BatteryDevice]?
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            if process.terminationStatus == 0 { devices = BluetoothBatterySnapshot.devices(from: data) }
        } catch { watchdog.cancel() }
        // 某些鼠标 / 手柄不会把电量放进 system_profiler，而是挂在 HID
        // 服务的子节点或父节点上。把当前已配对列表带进来，便于在没有
        // 蓝牙地址属性时用唯一设备名关联，仍然不会把同名设备混用。
        var result = devices ?? []
        for existing in existingDevices where !result.contains(where: { $0.id == existing.id }) {
            result.append(existing)
        }
        let classes = ["IOHIDDevice", "AppleDeviceManagementHIDEventService", "AppleUserHIDEventService",
                       "IOHIDEventService", "IOBluetoothHIDDriver"]
        var updatedIDs: Set<String> = []
        for className in classes {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let info = properties?.takeRetainedValue() as? [String: Any] else { continue }
                let percentKeys = ["BatteryPercent", "BatteryPercentage", "BatteryLevel", "batteryLevel",
                                   "device_batteryLevelMain"]
                let percent = percentKeys.lazy.compactMap { key -> Int? in
                    if let value = info[key] { return BluetoothBatterySnapshot.percent(value, key: key) }
                    guard let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                                                                       kCFAllocatorDefault,
                                                                       IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) else { return nil }
                    return BluetoothBatterySnapshot.percent(value, key: key)
                }.first
                guard let percent else { continue }
                let addressKeys = ["DeviceAddress", "BD_ADDR", "BluetoothAddress", "device_address", "Address"]
                let raw = addressKeys.lazy.compactMap { key -> String? in
                    if let value = info[key] as? String { return value }
                    guard let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                                                                       kCFAllocatorDefault,
                                                                       IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) else { return nil }
                    return value as? String
                }.first
                let address = raw.flatMap(BluetoothBatterySnapshot.address)
                let transport = (info["Transport"] as? String) ?? {
                    guard let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Transport" as CFString,
                                                                       kCFAllocatorDefault,
                                                                       IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) else { return nil }
                    return value as? String
                }()
                // 同名的 USB 接收器和蓝牙设备可能同时存在，只有确认是
                // Bluetooth 传输，才允许在缺少地址时按设备名关联。
                if address == nil, let transport,
                   !transport.lowercased().contains("bluetooth") { continue }
                let id = address.map { "bt:\($0)" }
                let productKeys = ["Product", "ProductName", "Name", "device_name"]
                let product = productKeys.lazy.compactMap { key -> String? in
                    if let value = info[key] as? String { return value }
                    guard let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                                                                       kCFAllocatorDefault,
                                                                       IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) else { return nil }
                    return value as? String
                }.first
                let connected = result.indices.filter { result[$0].connection == .connected }
                let index: Int? = id.flatMap { wanted in
                    result.firstIndex { $0.id == wanted && $0.connection == .connected }
                } ?? {
                    guard let product else { return nil }
                    let normalized = product.lowercased().filter { $0.isLetter || $0.isNumber }
                    let matches = connected.filter {
                        $0 < result.count && result[$0].name.lowercased().filter { $0.isLetter || $0.isNumber } == normalized
                    }
                    return matches.count == 1 ? matches[0] : nil
                }()
                guard let index else { continue }
                let existingID = result[index].id
                guard !updatedIDs.contains(existingID) else { continue }
                updatedIDs.insert(existingID)
                result[index].reading = BatteryReading(percent: percent,
                                                       charging: (info["BatteryIsCharging"] as? Bool) ?? false,
                                                       timestamp: Date(), productName: result[index].name, productID: 0)
            }
        }
        return devices == nil && result.isEmpty ? nil : result
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard running else { return }
        switch central.state {
        case .poweredOn:
            status = "蓝牙已开启。新耳机、键盘或手柄可在系统蓝牙设置中配对。"
            restoreSelectedPeripheral()
            refresh()
            if pendingScan { scan() }
        case .poweredOff: status = "蓝牙已关闭，请在系统蓝牙设置中开启。"
        case .unauthorized: status = "未获得蓝牙权限，请在系统设置 → 隐私与安全性 → 蓝牙中允许 LuckyPet。"
        case .unsupported: status = "当前 Mac 未提供可用的蓝牙适配器。"
        default: status = "蓝牙正在准备…"
        }
        if central.state != .poweredOn {
            stopScan()
            for id in devices.keys where id.hasPrefix("ble:") { devices[id]?.connection = .disconnected }
        }
        onChange?()
    }

    private func restoreSelectedPeripheral() {
        guard let central, central.state == .poweredOn, let pendingID,
              pendingID.hasPrefix("ble:"), let uuid = UUID(uuidString: String(pendingID.dropFirst(4))) else { return }
        for peripheral in central.retrievePeripherals(withIdentifiers: [uuid]) {
            register(peripheral)
            if peripheral.state == .connected { read(peripheral) }
        }
    }

    private func register(_ peripheral: CBPeripheral) {
        let id = "ble:\(peripheral.identifier.uuidString)"
        peripherals[id] = peripheral
        let name = peripheral.name ?? "未命名蓝牙设备"
        var device = devices[id] ?? BatteryDevice(id: id, name: name, kind: BatteryDevice.kind(name: name))
        device.name = name
        device.connection = peripheral.state == .connected ? .connected : (peripheral.state == .connecting ? .connecting : .disconnected)
        devices[id] = device
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard running, isScanning, peripheral.name != nil || advertisementData[CBAdvertisementDataLocalNameKey] != nil else { return }
        register(peripheral)
        let discoveredID = "ble:\(peripheral.identifier.uuidString)"
        if peripheral.state == .disconnected { devices[discoveredID]?.connection = .nearby }
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            let id = "ble:\(peripheral.identifier.uuidString)"
            devices[id]?.name = name
            devices[id]?.kind = BatteryDevice.kind(name: name)
        }
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard running else { return }
        connectionTimeouts.removeValue(forKey: peripheral.identifier)?.invalidate()
        register(peripheral)
        read(peripheral)
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, message: error?.localizedDescription ?? "无法连接，请在系统蓝牙设置中配对后重试。")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral, message: error?.localizedDescription)
    }

    private func disconnected(_ peripheral: CBPeripheral, message: String?) {
        guard running else { return }
        connectionTimeouts.removeValue(forKey: peripheral.identifier)?.invalidate()
        ownedConnections.remove(peripheral.identifier)
        let id = "ble:\(peripheral.identifier.uuidString)"
        devices[id]?.connection = .disconnected
        // 主动超时取消时保留超时原因。
        if let message { devices[id]?.message = message }
        onChange?()
    }

    private func read(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([batteryService])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard running else { return }
        let id = "ble:\(peripheral.identifier.uuidString)"
        let services = (peripheral.services ?? []).filter { $0.uuid == batteryService }
        devices[id]?.message = error?.localizedDescription ?? (services.isEmpty ? "设备未提供标准电池服务" : nil)
        for service in services {
            peripheral.discoverCharacteristics([batteryLevel], for: service)
        }
        onChange?()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard running else { return }
        let id = "ble:\(peripheral.identifier.uuidString)"
        let characteristics = (service.characteristics ?? []).filter { $0.uuid == batteryLevel }
        devices[id]?.message = error?.localizedDescription ?? (characteristics.isEmpty ? "设备未提供电量数据" : nil)
        for characteristic in characteristics {
            if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
            if characteristic.properties.contains(.notify), !characteristic.isNotifying {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        onChange?()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard running, characteristic.uuid == batteryLevel else { return }
        let id = "ble:\(peripheral.identifier.uuidString)"
        if let error { devices[id]?.message = error.localizedDescription }
        else if let value = characteristic.value, value.count == 1, let byte = value.first, byte <= 100 {
            let name = devices[id]?.name ?? "蓝牙设备"
            devices[id]?.reading = BatteryReading(percent: Int(byte), charging: false, timestamp: Date(),
                                                  productName: name, productID: 0)
            devices[id]?.message = nil
            devices[id]?.connection = .connected
        } else { devices[id]?.message = "设备返回的电量数据无效" }
        onChange?()
    }
}
