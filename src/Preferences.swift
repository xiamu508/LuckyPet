import Foundation

/// 提醒内容池默认文案（沿用「LuckyPet」傲娇女仆人设：自称"人家"、句尾"喵"）
let defaultReminderMessages: [String] = [
    "已经坐了好久啦，起来站一会儿嘛喵～",
    "主人，该站起来活动活动了，人家可不想你腰疼喵。",
    "停一下！伸个懒腰、转转脖子，就一分钟喵～",
    "该喝水啦，顺便站起来走两步喵。",
    "望望窗外远处吧，眼睛也要休息的喵～",
    "肩颈放松一下，人家帮你数三十秒喵。"
]

/// 点击互动台词（与 click 素材数量无关，随机挑一句）
let defaultClickMessages: [String] = [
    "唔……摸头就摸头吧，人家才没有高兴喵。",
    "干嘛啦，人家正在认真待机喵！",
    "再摸就要收费了哦喵～",
    "嘿嘿，主人今天也很闲呢喵。",
    "人家的头发很好摸吧？只准摸一下喵。"
]

struct Preferences: Codable {
    // 提醒
    var reminderEnabled: Bool = true
    var intervalMinutes: Int = 45
    var breakSeconds: Int = 25          // 气泡停留秒数（提醒时）
    var reminderMessages: [String] = defaultReminderMessages
    var quietHoursEnabled: Bool = true
    var quietStart: String = "12:00"
    var quietEnd: String = "13:30"
    var nightSilenceEnabled: Bool = true
    var nightStart: String = "23:00"
    var nightEnd: String = "08:00"
    var showSystemNotification: Bool = true
    var playSound: Bool = true

    // 桌宠外观与行为
    var petScale: Double = 0.70
    var alwaysOnTop: Bool = true
    var randomActionsEnabled: Bool = true
    var clickMessages: [String] = defaultClickMessages
    var launchAtLogin: Bool = false

    // 运行时状态（不写入用户设置界面）
    var lastPositionX: Double? = nil
    var lastPositionY: Double? = nil

    static let storePath: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("LuckyPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static func load() -> Preferences {
        guard let data = try? Data(contentsOf: storePath),
              let p = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return p
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Preferences.storePath, options: .atomic)
        }
    }

    /// 解析 "HH:mm" 为当天的分钟数
    static func minutes(from hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// 当前时间是否落在 [start, end) 区间内（支持跨午夜）
    static func nowInRange(_ now: Date, start: String, end: String) -> Bool {
        guard let s = minutes(from: start), let e = minutes(from: end), s != e else { return false }
        let cal = Calendar.current
        let cur = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        if s < e { return cur >= s && cur < e }
        return cur >= s || cur < e   // 跨午夜
    }
}
