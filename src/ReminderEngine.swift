import Foundation

/// 久坐提醒引擎：固定间隔循环，支持静音时段、临时暂停、立即触发。
@MainActor
final class ReminderEngine {

    var prefs: Preferences {
        didSet { resetIfIntervalChanged(oldValue) }
    }

    /// 触发提醒（参数为文案）
    var onFire: ((String) -> Void)?

    private var timer: Timer?
    private var elapsed: TimeInterval = 0
    private var pausedUntil: Date?
    private var todayKey: String = ""
    private(set) var todayCount: Int = 0

    init(prefs: Preferences) {
        self.prefs = prefs
        self.todayKey = Self.dayKey(Date())
    }

    var intervalSeconds: TimeInterval { TimeInterval(max(1, prefs.intervalMinutes)) * 60 }

    var remainingSeconds: TimeInterval {
        max(0, intervalSeconds - elapsed)
    }

    var isPaused: Bool {
        if let until = pausedUntil, until > Date() { return true }
        return false
    }

    var isInQuietHours: Bool {
        let now = Date()
        if prefs.quietHoursEnabled,
           Preferences.nowInRange(now, start: prefs.quietStart, end: prefs.quietEnd) {
            return true
        }
        if prefs.nightSilenceEnabled,
           Preferences.nowInRange(now, start: prefs.nightStart, end: prefs.nightEnd) {
            return true
        }
        return false
    }

    /// 当前是否在有效计时（未暂停、不在静音时段、已启用）
    var isActive: Bool {
        prefs.reminderEnabled && !isPaused && !isInQuietHours
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        rolloverDayIfNeeded()
        guard prefs.reminderEnabled else { return }
        guard !isPaused, !isInQuietHours else { return }
        elapsed += 1
        if elapsed >= intervalSeconds {
            elapsed = 0
            todayCount += 1
            onFire?(pickMessage())
        }
    }

    /// 立即提醒一次（不影响计时进度）
    func fireNow() {
        rolloverDayIfNeeded()
        todayCount += 1
        onFire?(pickMessage())
    }

    /// 每行是一条候选提醒；兼容旧配置中多条文案被存进同一个数组项的情况。
    private func pickMessage() -> String {
        let messages = prefs.reminderMessages
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return messages.randomElement() ?? "该起来活动一下啦喵～"
    }

    /// 重新开始本次计时
    func restartCycle() {
        elapsed = 0
    }

    func pause(minutes: Int) {
        pausedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    func pause(until date: Date) {
        pausedUntil = date
    }

    func resume() {
        pausedUntil = nil
    }

    func snooze(minutes: Int) {
        elapsed = max(0, intervalSeconds - TimeInterval(minutes * 60))
        pausedUntil = nil
    }

    /// 距离恢复还有多久（秒）
    var pausedRemaining: TimeInterval? {
        guard let until = pausedUntil else { return nil }
        let d = until.timeIntervalSinceNow
        return d > 0 ? d : nil
    }

    private func resetIfIntervalChanged(_ old: Preferences) {
        if old.intervalMinutes != prefs.intervalMinutes {
            elapsed = min(elapsed, intervalSeconds)
        }
    }

    private func rolloverDayIfNeeded() {
        let key = Self.dayKey(Date())
        if key != todayKey {
            todayKey = key
            todayCount = 0
        }
    }

    private static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
