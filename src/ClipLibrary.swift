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

    /// 每段素材在 640×360 逻辑画布中的安全可见边界。
    /// 边界来自超分管线的跨帧 alpha 裁剪范围，含卷积安全余量，适合避让气泡。
    private var animationBoundsByPath: [String: NSRect]
    private var resourceRootURL: URL?

    static let canvasSize = NSSize(width: 640, height: 360)

    static func resourceRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["LUCKY_PET_RESOURCES"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let r = Bundle.main.resourceURL {
            let clips = r.appendingPathComponent("clips")
            if FileManager.default.fileExists(atPath: clips.path) { return clips }
            if FileManager.default.fileExists(atPath: r.path) { return r }
        }
        return nil
    }

    private static func loadAnimationBounds(root: URL) -> [String: NSRect] {
        let candidates = [
            root.deletingLastPathComponent().appendingPathComponent("hd_manifest.json"),
            root.appendingPathComponent("hd_manifest.json")
        ]
        guard let manifestURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: manifestURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: NSRect] = [:]
        for (path, value) in raw {
            guard let record = value as? [String: Any],
                  let crop = record["crop"] as? [Any], crop.count == 4 else { continue }
            let values = crop.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard values.count == 4 else { continue }
            let x0 = CGFloat(values[0]), y0 = CGFloat(values[1])
            let x1 = CGFloat(values[2]), y1 = CGFloat(values[3])
            guard x1 > x0, y1 > y0 else { continue }
            result[path] = NSRect(x: x0, y: canvasSize.height - y1,
                                  width: x1 - x0, height: y1 - y0)
        }
        return result
    }

    func animationBounds(for url: URL?) -> NSRect? {
        guard let url, let root = resourceRootURL else { return nil }
        let rootPath = root.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        guard urlPath.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(urlPath.dropFirst(rootPath.count + 1))
            .replacingOccurrences(of: ".mov", with: ".webm")
        return animationBoundsByPath[relative]
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
            balance: scan("events/balance"),
            animationBoundsByPath: loadAnimationBounds(root: root),
            resourceRootURL: root
        )
        NSLog("[Pet] 素材载入 idle=\(lib.idle.clips.count) click=\(lib.click.clips.count) " +
              "random=\(lib.random.clips.count) drag=\(lib.drag.clips.count) " +
              "move=\(lib.move.clips.count) balance=\(lib.balance.clips.count) " +
              "bounds=\(lib.animationBoundsByPath.count)")
        return lib
    }

    static func empty() -> ClipLibrary {
        let g = Group(name: "", clips: [])
        return ClipLibrary(idle: g, click: g, drag: g, move: g, turn: g, random: g, balance: g,
                           animationBoundsByPath: [:], resourceRootURL: nil)
    }
}
