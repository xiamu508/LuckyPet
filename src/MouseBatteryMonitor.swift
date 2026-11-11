import Cocoa

/// 开启时读取一次，此后无论成功或失败都按每小时刷新；菜单展开不触发设备读取。
@MainActor
final class MouseBatteryMonitor {
    static let refreshInterval: TimeInterval = 60 * 60
    typealias Reader = (@escaping (Result<BatteryReading, BatteryError>) -> Void) -> Void

    private let reader: Reader
    private var timer: Timer?
    private var generation = 0
    private(set) var isEnabled = false
    private(set) var isRefreshing = false
    private(set) var reading: BatteryReading?
    private(set) var lastError: BatteryError?
    private(set) var nextRefreshDate: Date?
    var onChange: (() -> Void)?

    convenience init() {
        let service = MouseBatteryService()
        var started = false
        self.init { completion in
            if !started {
                service.start()
                started = true
            }
            service.readBattery(completion: completion)
        }
    }

    init(reader: @escaping Reader) {
        self.reader = reader
    }

    deinit { timer?.invalidate() }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        generation += 1
        isEnabled = enabled
        isRefreshing = false
        timer?.invalidate()
        timer = nil
        nextRefreshDate = nil
        if enabled {
            refresh()
        } else {
            onChange?()
        }
    }

    func refresh() {
        guard isEnabled, !isRefreshing else { return }
        timer?.invalidate()
        timer = nil
        nextRefreshDate = nil
        isRefreshing = true
        onChange?()
        let requestGeneration = generation
        reader { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.isEnabled, self.generation == requestGeneration else { return }
                self.isRefreshing = false
                switch result {
                case .success(let reading):
                    self.reading = reading
                    self.lastError = nil
                case .failure(let error):
                    // 休眠/断连时保留上次真实读数，并明确标记，不能伪造为 0%。
                    self.lastError = error
                }
                self.scheduleNextRefresh()
                self.onChange?()
            }
        }
    }

    private func scheduleNextRefresh() {
        let next = Date().addingTimeInterval(Self.refreshInterval)
        nextRefreshDate = next
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var statusText: String {
        if isRefreshing { return "鼠标电量 · 正在读取…" }
        if let reading {
            if lastError != nil { return "鼠标电量 \(reading.percent)% · 上次读数" }
            return "鼠标电量 \(reading.percent)% · \(reading.charging ? "充电中" : "使用电池")"
        }
        return "鼠标电量 · 未获取"
    }

    var toolTip: String {
        var lines = ["LuckyPet · 久坐提醒", statusText]
        if let reading {
            lines.append("\(reading.productName) · 更新于 \(Self.timeFormatter.string(from: reading.timestamp))")
        }
        if let error = lastError { lines.append(error.localizedDescription) }
        lines.append("每小时自动刷新")
        return lines.joined(separator: "\n")
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}
