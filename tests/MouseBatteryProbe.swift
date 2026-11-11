import Foundation

/// 独立读取真实鼠标，不启动桌宠、不更改用户配置。
@main
struct MouseBatteryProbe {
    static func main() {
        let service = MouseBatteryService()
        service.start()
        CFRunLoopRunInMode(.defaultMode, 1.2, false)
        print("匹配接口：\(service.matchedDevices().count)")
        let done = DispatchSemaphore(value: 0)
        service.readBattery { result in
            switch result {
            case .success(let reading):
                print("真实鼠标电量：\(reading.percent)% · \(reading.charging ? "充电中" : "使用电池") · \(reading.productName)")
            case .failure(let error):
                print("读取结果：\(error.localizedDescription)")
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 8) == .timedOut {
            print("读取超时")
            exit(1)
        }
    }
}
