import Foundation

/// 动画素材索引。素材来自 dsh-pet-indesktop（MIT），已离线转码为带 Alpha 的 HEVC。
struct ClipLibrary {
    struct Group {
        var name: String
        var clips: [URL]
        func pick(excluding: URL? = nil) -> URL? {
            guard !clips.isEmpty else { return nil }
            if clips.count == 1 { return clips[0] }
            var pool = clips
            if let ex = excluding, let i = pool.firstIndex(of: ex), pool.count > 1 {
                pool.remove(at: i)
            }
            return pool.randomElement()
        }
    }

    var idle: Group
    var click: Group
    var drag: Group
    var move: Group
    var turn: Group
    var random: Group
    var balance: Group

    static func resourceRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["LUCKY_PET_RESOURCES"] {
            return URL(fileURLWithPath: env)
        }
        if let r = Bundle.main.resourceURL {
            let clips = r.appendingPathComponent("clips")
            if FileManager.default.fileExists(atPath: clips.path) { return clips }
            if FileManager.default.fileExists(atPath: r.path) { return r }
        }
        return nil
    }

    static func load() -> ClipLibrary {
        guard let root = resourceRoot() else {
            NSLog("[Pet] 未找到素材目录")
            return empty()
        }
        func scan(_ sub: String) -> Group {
            let dir = root.appendingPathComponent(sub)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            let clips = files.filter { $0.pathExtension.lowercased() == "mov" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return Group(name: sub, clips: clips)
        }
        let lib = ClipLibrary(
            idle: scan("idle"),
            click: scan("click"),
            drag: scan("drag"),
            move: scan("move"),
            turn: scan("turn"),
            random: scan("random"),
            balance: scan("events/balance")
        )
        NSLog("[Pet] 素材载入 idle=\(lib.idle.clips.count) click=\(lib.click.clips.count) " +
              "random=\(lib.random.clips.count) drag=\(lib.drag.clips.count) " +
              "move=\(lib.move.clips.count) balance=\(lib.balance.clips.count)")
        return lib
    }

    static func empty() -> ClipLibrary {
        let g = Group(name: "", clips: [])
        return ClipLibrary(idle: g, click: g, drag: g, move: g, turn: g, random: g, balance: g)
    }
}
