import Cocoa
import AVFoundation
import UserNotifications
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var pet: PetWindow!
    private var library: ClipLibrary!
    private var prefs: Preferences!
    private var reminder: ReminderEngine!
    private var settings: SettingsWindowController!

    private var statusItem: NSStatusItem!
    private var idleTimer: Timer?
    private var hidePet = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        prefs = Preferences.load()
        library = ClipLibrary.load()
        settings = SettingsWindowController()

        pet = PetWindow(library: library, prefs: prefs)
        pet.restorePosition()
        pet.orderFrontRegardless()
        pet.playIdle()

        if let testDirectory = ProcessInfo.processInfo.environment["PET_RENDER_TEST_DIR"] {
            runRenderTest(directory: URL(fileURLWithPath: testDirectory, isDirectory: true))
            return
        }

        pet.onClicked = { [weak self] point in
            guard let self else { return }
            self.pet.playClick()
            let text = self.prefs.clickMessages.randomElement() ?? "喵？"
            self.pet.showBubble(text: text, duration: 8)
        }
        pet.onRightClicked = { [weak self] point in
            self?.popUpPetMenu(at: point)
        }

        reminder = ReminderEngine(prefs: prefs)
        reminder.onFire = { [weak self] text in
            self?.deliverReminder(text)
        }
        reminder.start()

        buildStatusItem()
        scheduleIdleActions()
        requestNotificationPermission()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        if ProcessInfo.processInfo.environment["PET_SELFTEST"] == "1" {
            runSelfTest()
        }
    }

    /// 隔离的原生视频渲染自检；不启动提醒、不请求通知权限。
    private func runRenderTest(directory: URL) {
        var observations: [[String: Any]] = []
        func record(_ phase: String) {
            var data = pet.renderDiagnostics
            data["phase"] = phase
            observations.append(data)
            NSLog("[RenderTest] %@ %@", phase, String(describing: data))
        }
        let checks: [(Double, () -> Void)] = [
            (1, { record("idle") }),
            (2, { self.pet.applyScale(0.45) }),
            (3, { record("small"); self.pet.applyScale(0.95) }),
            (4, { record("large"); self.pet.applyScale(0.70) }),
            (12, { record("idle-after-loop") }),
            (13, { self.pet.playClick() }),
            (15, { record("click") }),
            (25, { record("return-to-idle"); self.pet.playDragFeedback() }),
            (27, { record("drag"); self.pet.playIdle() }),
            (29, { record("idle-restored") }),
            (30, {
                if let clip = self.library.random.clips.first(where: { $0.lastPathComponent == "蓝鲸现世.mov" }) {
                    self.pet.play(url: clip, loop: false, state: "wide-animation")
                }
            }),
            (32, { record("wide-animation") }),
            (34, {
                if let clip = self.library.random.clips.first(where: { $0.lastPathComponent == "放烟花.mov" }) {
                    self.pet.play(url: clip, loop: false, state: "full-canvas-effects")
                }
            }),
            (36, { record("full-canvas-effects") }),
            (38, {
                if let screen = self.pet.screen {
                    self.pet.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 10, y: screen.visibleFrame.maxY - 10))
                    self.pet.keepFullyOnScreen()
                }
                record("screen-edge")
            }),
            (39, {
                self.pet.showBubble(text: "完整动画与提醒气泡显示检查", duration: 8)
            }),
            (41, { record("bubble") })
        ]
        for (delay, action) in checks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 42) {
            let expectedStates = ["idle": "idle", "idle-after-loop": "idle", "click": "click",
                                  "return-to-idle": "idle", "drag": "drag", "idle-restored": "idle",
                                  "wide-animation": "wide-animation", "full-canvas-effects": "full-canvas-effects"]
            let ok = observations.allSatisfy { observation in
                (expectedStates[observation["phase"] as? String ?? ""].map { expected in
                    expected == (observation["state"] as? String)
                } ?? true) &&
                ((observation["phase"] as? String != "idle-after-loop") || ((observation["loopCount"] as? Int ?? 0) >= 1)) &&
                (observation["serverMatchesFrame"] as? Bool == true) &&
                (observation["hasHitPixels"] as? Bool == true) &&
                (observation["canvasInsideWindow"] as? Bool == true) &&
                (observation["windowFullyOnScreen"] as? Bool == true) &&
                ((observation["state"] as? String != "idle") ||
                 ((observation["transparentCornerPassesThrough"] as? Bool == true) &&
                  (observation["centerReceivesMouse"] as? Bool == true))) &&
                (observation["timeControlStatus"] as? Int == 2) &&
                ((observation["rate"] as? Float ?? 0) > 0) &&
                (observation["readyForDisplay"] as? Bool == true) &&
                (observation["itemStatus"] as? Int == 1) &&
                ((observation["videoWidth"] as? CGFloat) == 2560) &&
                ((observation["videoHeight"] as? CGFloat) == 1440) &&
                ((observation["backingScale"] as? CGFloat) == (observation["layerScale"] as? CGFloat)) &&
                ((observation["error"] as? String) == "")
            }
            let report: [String: Any] = ["passed": ok, "observations": observations]
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("render-smoke.json"))
            }
            NSLog("[RenderTest] completed passed=%@", String(ok))
            NSApp.terminate(nil)
        }
    }

    /// 开发自检：验证气泡 → 设置窗口 → 提醒引擎（间隔压到 1 分钟）
    private func runSelfTest() {
        NSLog("[Pet] SELFTEST 开始")
        reminder.prefs.intervalMinutes = 1
        reminder.restartCycle()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.pet.playClick()
            self.pet.showBubble(text: "已经坐了好久啦，起来站一会儿嘛喵～", duration: 10, emphasize: true)
            NSLog("[Pet] SELFTEST 气泡已显示")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            let loc = NSPoint(x: self.pet.frame.width / 2, y: self.pet.frame.height / 2)
            let t = ProcessInfo.processInfo.systemUptime
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: loc,
                                             modifierFlags: [], timestamp: t,
                                             windowNumber: self.pet.windowNumber,
                                             context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1),
               let up = NSEvent.mouseEvent(with: .leftMouseUp, location: loc,
                                           modifierFlags: [], timestamp: t + 0.1,
                                           windowNumber: self.pet.windowNumber,
                                           context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 0) {
                self.pet.mouseDown(with: down)
                self.pet.mouseUp(with: up)
                NSLog("[Pet] SELFTEST 已注入点击 state=\(self.pet.state)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.actionSettings()
            NSLog("[Pet] SELFTEST 设置窗口已打开")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 70) { [weak self] in
            guard let self else { return }
            NSLog("[Pet] SELFTEST 提醒计数=\(self.reminder.todayCount) 剩余=\(Int(self.reminder.remainingSeconds))s")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pet?.rememberPosition()
        prefs?.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func screenChanged() {
        guard let pet else { return }
        if pet.isEdgeHidden {
            pet.keepFullyOnScreen()
            return
        }
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(pet.frame) }) {
            pet.keepFullyOnScreen()
        } else {
            pet.placeAtDefaultPosition()
        }
    }

    // MARK: - 状态栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "LuckyPet")
                ?? Self.makeFishIcon()
            icon.isTemplate = true
            button.image = icon
            button.toolTip = "LuckyPet · 久坐提醒"
            NSLog("[Pet] 状态栏图标已创建 image=\(button.image != nil)")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if let w = self?.statusItem.button?.window {
                NSLog("[Pet] 状态栏窗口 frame=\(w.frame) visible=\(w.isVisible)")
            } else {
                NSLog("[Pet] 状态栏窗口不存在")
            }
        }
    }

    /// 自绘鱼形托盘图标（SF Symbol 不可用时的兜底）
    static func makeFishIcon() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            let body = NSBezierPath(ovalIn: NSRect(x: 0.5, y: 3, width: 11.5, height: 10))
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 11, y: 8))
            tail.line(to: NSPoint(x: 17, y: 2.5))
            tail.line(to: NSPoint(x: 17, y: 13.5))
            tail.close()
            body.append(tail)
            NSColor.black.setFill()
            body.fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let reminder else { return }

        let title = NSMenuItem(title: "LuckyPet · 桌宠", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        // 状态行
        let statusText: String
        if !prefs.reminderEnabled {
            statusText = "提醒已关闭"
        } else if reminder.isPaused {
            let m = Int((reminder.pausedRemaining ?? 0) / 60) + 1
            statusText = "已暂停 · 约 \(m) 分钟后恢复"
        } else if reminder.isInQuietHours {
            statusText = "免打扰时段中"
        } else {
            let s = Int(reminder.remainingSeconds)
            statusText = String(format: "下次提醒 %d:%02d 后", s / 60, s % 60)
        }
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let count = NSMenuItem(title: "今日已提醒 \(reminder.todayCount) 次", action: nil, keyEquivalent: "")
        count.isEnabled = false
        menu.addItem(count)
        menu.addItem(.separator())

        menu.addItem(item("摸摸头", #selector(actionPat), "t"))
        menu.addItem(item("立即提醒", #selector(actionFireNow), "r"))
        menu.addItem(item("本轮重新计时", #selector(actionRestart), ""))

        // 暂停子菜单
        let pauseItem = NSMenuItem(title: "暂停提醒", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        for (label, mins) in [("15 分钟", 15), ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120)] {
            let i = NSMenuItem(title: label, action: #selector(actionPause(_:)), keyEquivalent: "")
            i.target = self
            i.tag = mins
            pauseMenu.addItem(i)
        }
        pauseMenu.addItem(.separator())
        let resume = NSMenuItem(title: "恢复提醒", action: #selector(actionResume), keyEquivalent: "")
        resume.target = self
        resume.isEnabled = reminder.isPaused
        pauseMenu.addItem(resume)
        pauseItem.submenu = pauseMenu
        menu.addItem(pauseItem)

        menu.addItem(.separator())
        menu.addItem(item(hidePet ? "显示桌宠" : "隐藏桌宠", #selector(actionToggleVisible), "h"))

        // 大小
        let sizeItem = NSMenuItem(title: "桌宠大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (label, v) in [("小 (45%)", 0.45), ("中 (55%)", 0.55), ("大 (75%)", 0.75), ("特大 (95%)", 0.95)] {
            let i = NSMenuItem(title: label, action: #selector(actionScale(_:)), keyEquivalent: "")
            i.target = self
            i.tag = Int(v * 100)
            i.state = abs(prefs.petScale - v) < 0.02 ? .on : .off
            sizeMenu.addItem(i)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let top = NSMenuItem(title: "始终置顶", action: #selector(actionToggleTop), keyEquivalent: "")
        top.target = self
        top.state = prefs.alwaysOnTop ? .on : .off
        menu.addItem(top)

        menu.addItem(.separator())
        menu.addItem(item("提醒设置…", #selector(actionSettings), ","))
        menu.addItem(item("打开配置目录", #selector(actionOpenConfigDir), ""))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(actionQuit), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func popUpPetMenu(at screenPoint: NSPoint) {
        let menu = NSMenu()
        menu.addItem(item("摸摸头", #selector(actionPat), ""))
        menu.addItem(item("立即提醒", #selector(actionFireNow), ""))
        menu.addItem(item("暂停 30 分钟", #selector(actionPause30), ""))
        menu.addItem(.separator())
        menu.addItem(item("提醒设置…", #selector(actionSettings), ""))
        menu.addItem(item("隐藏桌宠", #selector(actionToggleVisible), ""))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(actionQuit), ""))
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    // MARK: - 菜单动作

    @objc private func actionPat() {
        pet.playClick()
        let text = prefs.clickMessages.randomElement() ?? "喵～"
        pet.showBubble(text: text, duration: 8)
    }

    @objc private func actionFireNow() {
        reminder.fireNow()
    }

    @objc private func actionRestart() {
        reminder.restartCycle()
    }

    @objc private func actionPause(_ sender: NSMenuItem) {
        reminder.pause(minutes: sender.tag)
    }

    @objc private func actionPause30() {
        reminder.pause(minutes: 30)
    }

    @objc private func actionResume() {
        reminder.resume()
    }

    @objc private func actionToggleVisible() {
        hidePet.toggle()
        if hidePet {
            pet.orderOut(nil)
            pet.hideBubble()
        } else {
            pet.orderFrontRegardless()
            pet.revealFromEdge(animated: true)
            pet.playIdle()
        }
    }

    @objc private func actionScale(_ sender: NSMenuItem) {
        let v = Double(sender.tag) / 100.0
        pet.applyScale(v)
    }

    @objc private func actionToggleTop() {
        pet.applyAlwaysOnTop(!prefs.alwaysOnTop)
    }

    @objc private func actionSettings() {
        settings.show(prefs: prefs,
                      onChange: { [weak self] newPrefs in
                          guard let self else { return }
                          let oldTop = self.prefs.alwaysOnTop
                          let oldScale = self.prefs.petScale
                          let oldLaunch = self.prefs.launchAtLogin
                          self.prefs = newPrefs
                          newPrefs.save()
                          self.reminder.prefs = newPrefs
                          if abs(oldScale - newPrefs.petScale) > 0.001 {
                              self.pet.prefs = newPrefs
                              self.pet.applyGeometry()
                          }
                          if oldTop != newPrefs.alwaysOnTop {
                              self.pet.applyAlwaysOnTop(newPrefs.alwaysOnTop)
                          }
                          if oldLaunch != newPrefs.launchAtLogin {
                              self.setLaunchAtLogin(newPrefs.launchAtLogin)
                          }
                      },
                      onFireNow: { [weak self] in
                          self?.reminder.fireNow()
                      },
                      onQuit: {
                          NSApp.terminate(nil)
                      })
    }

    @objc private func actionOpenConfigDir() {
        NSWorkspace.shared.open(Preferences.storePath.deletingLastPathComponent())
    }

    @objc private func actionQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - 提醒投递

    private func deliverReminder(_ text: String) {
        pet.playClick()
        pet.showBubble(text: text, duration: TimeInterval(prefs.breakSeconds), emphasize: true)

        if prefs.playSound {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        if prefs.showSystemNotification {
            sendNotification(title: "该起来活动啦", body: text)
        }
    }

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
            if let err { NSLog("[Pet] 通知授权失败: \(err.localizedDescription)") }
            NSLog("[Pet] 通知授权 granted=\(granted)")
        }
    }

    private func sendNotification(title: String, body: String) {
        if Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = prefs.playSound ? .default : nil
            let req = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { err in
                if let err { NSLog("[Pet] 通知投递失败: \(err.localizedDescription)") }
            }
        } else {
            // 无 bundle 环境（开发调试）退化到 osascript
            let esc = body.replacingOccurrences(of: "\"", with: "\\\"")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc)\" with title \"\(title)\""]
            try? p.run()
        }
    }

    // MARK: - 随机动作

    private func scheduleIdleActions() {
        idleTimer?.invalidate()
        let interval = Double.random(in: 22...45)
        idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.pet.state == "idle", !self.pet.isBubbleVisible, !self.pet.isEdgeHidden, !self.hidePet,
                   self.prefs.randomActionsEnabled {
                    self.pet.playRandom()
                }
                self.scheduleIdleActions()
            }
        }
    }

    // MARK: - 开机自启

    private func setLaunchAtLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[Pet] 开机自启设置失败: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "开机自启设置失败"
                alert.informativeText = "请把 App 拖到「应用程序」文件夹后再试。\n\(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
