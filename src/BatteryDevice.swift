import Foundation
import CoreFoundation

enum BatteryConnection: String {
    case connected = "已连接", connecting = "连接中…", disconnected = "未连接", nearby = "附近设备"
}

struct BatteryDevice {
    static let mouseID = "mchose:usb"
    let id: String
    var name: String
    var kind: String = "蓝牙设备"
    var connection: BatteryConnection = .disconnected
    var reading: BatteryReading?
    var components: [String] = []
    var message: String?

    var symbol: String {
        switch kind {
        case "鼠标": return "computermouse"
        case "键盘": return "keyboard"
        case "手柄": return "gamecontroller"
        case "耳机": return "headphones"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    var isStale: Bool { reading != nil && (connection != .connected || message != nil) }

    var detail: String {
        var parts = [connection.rawValue]
        if let reading {
            parts.append("\(reading.percent)%" + (isStale ? " · 上次读数" : ""))
            if reading.charging { parts.append("充电中") }
        } else {
            parts.append(connection == .connected ? "未提供电量" : "电量未知")
        }
        return parts.joined(separator: " · ")
    }

    static func kind(name: String, type: String = "") -> String {
        let text = (name + " " + type).lowercased()
        if ["keyboard", "键盘"].contains(where: text.contains) { return "键盘" }
        if ["controller", "gamepad", "dualshock", "dualsense", "xbox", "手柄"].contains(where: text.contains) { return "手柄" }
        if ["head", "airpods", "buds", "beats", "earphone", "耳机", "音频", "audio"].contains(where: text.contains) { return "耳机" }
        if ["mouse", "mchose", "trackpad", "鼠标"].contains(where: text.contains) { return "鼠标" }
        return "蓝牙设备"
    }
}

/// 优先按蓝牙地址合并系统数据；HID 只有在设备名唯一时才允许回退关联，避免同名外设串电量。
enum BluetoothBatterySnapshot {
    static func address(_ value: String) -> String? {
        let compact = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        guard compact.count == 12, compact.allSatisfy({ $0.isHexDigit }) else { return nil }
        return compact
    }

    static func percent(_ value: Any?) -> Int? {
        let number: Int?
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue.rounded() == value.doubleValue, (0...100).contains(value.doubleValue) else { return nil }
            number = value.intValue
        }
        else if let value = value as? String {
            number = Int(value.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
        } else { number = nil }
        guard let number, (0...100).contains(number) else { return nil }
        return number
    }

    /// macOS 在不同版本中会把 HID 电量写成百分数（92）、带百分号的字符串
    ///（"92%"），或者写成 0…1 的比例（0.92）。比例只在字段名明确是
    /// BatteryLevel 时解释，避免把普通的小数误当成电量。
    static func percent(_ value: Any?, key: String) -> Int? {
        let key = key.lowercased()
        if key.contains("level"), !key.contains("percent") {
            if let number = value as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite, (0...1).contains(number.doubleValue),
               number.doubleValue != 0, number.doubleValue != 1 {
                return Int((number.doubleValue * 100).rounded())
            }
            if let string = value as? String,
               let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)),
               (0...1).contains(number), number != 0, number != 1 {
                return Int((number * 100).rounded())
            }
        }
        return percent(value)
    }

    private static func batteryLevels(in value: Any) -> [(String, Int)] {
        var result: [(String, Int)] = []
        if let dictionary = value as? [String: Any] {
            for (key, raw) in dictionary {
                let normalized = key.lowercased()
                if normalized.contains("battery"), let value = percent(raw, key: key) {
                    let label: String
                    if normalized.contains("left") { label = "左耳" }
                    else if normalized.contains("right") { label = "右耳" }
                    else if normalized.contains("case") || normalized.contains("chargingbox") {
                        label = "充电盒"
                    } else { label = "电量" }
                    result.append((label, value))
                } else {
                    result.append(contentsOf: batteryLevels(in: raw))
                }
            }
        } else if let array = value as? [Any] {
            for item in array { result.append(contentsOf: batteryLevels(in: item)) }
        }
        return result
    }

    private static func deviceEntries(_ value: Any) -> [(String, [String: Any])] {
        if let entries = value as? [[String: Any]] {
            return entries.flatMap { dictionary in
                dictionary.compactMap { name, raw in
                    guard let info = raw as? [String: Any] else { return nil }
                    return (name, info)
                }
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.compactMap { name, raw in
                guard let info = raw as? [String: Any] else { return nil }
                return (name, info)
            }
        }
        return []
    }

    private static func rawAddress(in info: [String: Any]) -> String? {
        let keys = ["device_address", "deviceAddress", "BluetoothAddress", "BD_ADDR",
                    "bluetooth_address", "address"]
        for key in keys {
            if let value = info[key] as? String { return value }
        }
        let normalized = info.reduce(into: [String: Any]()) { result, item in
            result[item.key.lowercased()] = item.value
        }
        for key in ["device_address", "deviceaddress", "bluetoothaddress", "bd_addr", "bluetooth_address", "address"] {
            if let value = normalized[key] as? String { return value }
        }
        return nil
    }

    static func devices(from data: Data, date: Date = Date()) -> [BatteryDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var result: [BatteryDevice] = []
        for controller in controllers {
            for (section, connection) in [("device_connected", BatteryConnection.connected),
                                           ("device_not_connected", .disconnected)] {
                guard let value = controller[section] else { continue }
                for (name, info) in deviceEntries(value) {
                    guard let rawAddress = rawAddress(in: info),
                          let address = address(rawAddress) else { continue }
                    var device = BatteryDevice(id: "bt:\(address)", name: name,
                                               kind: BatteryDevice.kind(name: name, type: info["device_minorType"] as? String ?? ""),
                                               connection: connection)
                    // 左右耳的较低电量作为托盘读数，充电盒单独列出。
                    let levels = batteryLevels(in: info)
                    device.components = connection == .connected ? levels.map { "\($0.0) \($0.1)%" } : []
                    let ears = levels.filter { $0.0 == "左耳" || $0.0 == "右耳" }
                    let main = levels.first { $0.0 == "电量" }?.1
                    // 只有充电盒电量时，不把它冒充为耳机电量。
                    if connection == .connected, let level = ears.map({ $0.1 }).min() ?? main {
                        device.reading = BatteryReading(percent: level, charging: false, timestamp: date,
                                                        productName: name, productID: 0)
                    }
                    result.append(device)
                }
            }
        }
        return result
    }
}
