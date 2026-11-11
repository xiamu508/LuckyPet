// MCHOSE HID 读取逻辑移植自用户提供的 MCHOSEBattery。
// 协议参考 https://github.com/z750sasr/mchose-a5-pro-max-web-driver
import Foundation
import IOKit.hid

struct BatteryReading {
    let percent: Int
    let charging: Bool
    let timestamp: Date
    let productName: String
    let productID: Int
}

enum BatteryError: LocalizedError {
    case noDevice
    case sendFailed(IOReturn)
    case noResponse
    case mouseOffline
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "未检测到 MCHOSE A5（接收器未插入，或鼠标处于关闭状态）"
        case .sendFailed(let code):
            return "发送读电量指令失败（IOReturn 0x\(String(format: "%08X", code))）"
        case .noResponse:
            return "设备无有效应答（请动一下鼠标后重试）"
        case .mouseOffline:
            return "接收器已就绪，但鼠标未连接（请开机，或按一下鼠标按键唤醒）"
        case .transport(let message):
            return message
        }
    }

    var isMouseOffline: Bool {
        if case .mouseOffline = self { return true }
        return false
    }
}

struct MCHOSEInterface {
    let device: IOHIDDevice
    let productName: String
    let productID: Int
    let usagePage: Int
    let reportID: Int
    let featureBytes: Int

    var transportLabel: String {
        switch productID {
        case 0xF019: return "有线"
        case 0xF013: return "2.4G 接收器（1K）"
        case 0xF015: return "2.4G 接收器（4K）"
        default: return "未知通道"
        }
    }

    var pidLabel: String {
        String(format: "0x%04X", productID)
    }
}

/// 与 MCHOSE A5 Pro Max 的 WebHID 协议保持一致：
/// VID 0x2023 / PID 0xF019、0xF013、0xF015，usage page 0xFFFF，64 字节 Feature report。
/// 读电量 = route 2 / page 0 / command 0x83，
/// 应答 byte[0] == 0xA1，byte[4..5] 回显 page/command，byte[6] 充电标志，byte[7] 电量百分比。
final class MouseBatteryService {

    static let vendorID = 0x2023
    static let productIDs = [0xF019, 0xF013, 0xF015]
    static let debugEnabled = CommandLine.arguments.contains("--debug")
    private static let vendorUsagePage = 0xFFFF

    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "com.jiean.luckypet.mouse-battery")
    private(set) var managerStatus: IOReturn = kIOReturnSuccess

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = Self.productIDs.map { pid in
            [
                kIOHIDVendorIDKey: Self.vendorID,
                kIOHIDProductIDKey: pid
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as NSArray as CFArray)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func start() {
        managerStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// 枚举当前匹配到的 MCHOSE 接口，优先返回 usage page 0xFFFF 的厂商集合。
    func matchedDevices() -> [MCHOSEInterface] {
        let all = allMatchedInterfaces()
        let vendor = all.filter { $0.usagePage == Self.vendorUsagePage }
        return vendor.isEmpty ? all : vendor
    }

    func readBattery(completion: @escaping (Result<BatteryReading, BatteryError>) -> Void) {
        queue.async {
            let interfaces = self.matchedDevices()
            guard !interfaces.isEmpty else {
                completion(.failure(.noDevice))
                return
            }

            var lastError: BatteryError = .noResponse
            for interface in interfaces {
                do {
                    let reading = try self.read(interface)
                    completion(.success(reading))
                    return
                } catch let error as BatteryError {
                    lastError = error
                } catch {
                    lastError = .transport(error.localizedDescription)
                }
            }
            completion(.failure(lastError))
        }
    }

    // MARK: - Private

    private func allMatchedInterfaces() -> [MCHOSEInterface] {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) else { return [] }
        let count = CFSetGetCount(deviceSet)
        guard count > 0 else { return [] }

        var rawPointers = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(deviceSet, &rawPointers)

        var result: [MCHOSEInterface] = []
        for pointer in rawPointers {
            guard let pointer else { continue }
            let device = unsafeBitCast(pointer, to: IOHIDDevice.self)

            let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "MCHOSE A5"

            let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
            let report = HIDReportDescriptor.preferredFeatureReport(from: descriptor)

            result.append(
                MCHOSEInterface(
                    device: device,
                    productName: productName,
                    productID: productID,
                    usagePage: usagePage,
                    reportID: report.id,
                    featureBytes: report.byteSize
                )
            )
        }
        return result
    }

    private func read(_ interface: MCHOSEInterface) throws -> BatteryReading {
        let device = interface.device
        let openStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if openStatus != kIOReturnSuccess && openStatus != kIOReturnExclusiveAccess {
            throw BatteryError.transport("无法打开厂商 HID 接口（IOReturn 0x\(String(format: "%08X", openStatus))），通常是缺少「输入监控」授权")
        }

        defer {
            if openStatus == kIOReturnSuccess {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        }

        var request = [UInt8](repeating: 0, count: 64)
        request[2] = 2      // route: 鼠标本体
        request[3] = 2      // 载荷长度
        request[4] = 0      // page 0
        request[5] = 0x83   // 读电量

        var status = send(request, to: device, reportID: interface.reportID)
        if MouseBatteryService.debugEnabled {
            print("[debug] SetReport(64B, id=\(interface.reportID)) → 0x\(String(format: "%08X", status))")
        }
        if status != kIOReturnSuccess {
            throw BatteryError.sendFailed(status)
        }

        let capacity = max(8, interface.featureBytes)
        var sawNoData = false

        for attempt in 0..<5 {
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.04 : 0.03)

            var response = [UInt8](repeating: 0, count: capacity)
            var length = CFIndex(capacity)
            status = IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(interface.reportID),
                &response,
                &length
            )
            if MouseBatteryService.debugEnabled {
                let head = response.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
                print("[debug] GetReport(try=\(attempt)) → 0x\(String(format: "%08X", status)) len=\(length)  head: \(head)")
            }

            if status == kIOReturnSuccess {
                let count = max(0, min(Int(length), response.count))
                let bytes = Array(response[0..<count])

                // A1 = 正常应答；A4 = 接收器转发成功但鼠标端没有数据。
                if bytes.count >= 8, bytes[0] == 0xA1, bytes[4] == 0x00, bytes[5] == 0x83 {
                    return BatteryReading(
                        percent: min(100, Int(bytes[7])),
                        charging: bytes[6] > 0,
                        timestamp: Date(),
                        productName: interface.productName,
                        productID: interface.productID
                    )
                }
                if bytes.count >= 8, bytes[0] == 0xA4 {
                    sawNoData = true
                }
            }

            if attempt == 1 {
                _ = send(request, to: device, reportID: interface.reportID)
            }
        }

        throw sawNoData ? BatteryError.mouseOffline : BatteryError.noResponse
    }

    private func send(_ bytes: [UInt8], to device: IOHIDDevice, reportID: Int) -> IOReturn {
        bytes.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(reportID),
                buffer.baseAddress!,
                CFIndex(bytes.count)
            )
        }
    }
}

