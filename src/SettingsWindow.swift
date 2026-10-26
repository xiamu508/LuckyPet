import Cocoa
import ServiceManagement

/// 设置窗口（纯 AppKit 实现，避免 SwiftUI 宏在命令行编译下的限制）
@MainActor
final class SettingsWindowController: NSObject {

    private var window: NSWindow?
    private var prefs: Preferences?
    private var onChange: ((Preferences) -> Void)?
    private var onFireNow: (() -> Void)?
    private var onQuit: (() -> Void)?

    // 控件引用（用于读回值）
    private var intervalField: NSTextField!
    private var messagesTextView: NSTextView!
    private var quietStartPicker: NSDatePicker!
    private var quietEndPicker: NSDatePicker!
    private var nightStartPicker: NSDatePicker!
    private var nightEndPicker: NSDatePicker!
    private var scaleSlider: NSSlider!
    private var scaleLabel: NSTextField!
    private var breakStepper: NSStepper!
    private var breakLabel: NSTextField!

    func show(prefs: Preferences,
              onChange: @escaping (Preferences) -> Void,
              onFireNow: @escaping () -> Void,
              onQuit: @escaping () -> Void) {
        self.prefs = prefs
        self.onChange = onChange
        self.onFireNow = onFireNow
        self.onQuit = onQuit

        if let w = window {
            rebuildContent()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "LuckyPet · 设置"
        w.isReleasedWhenClosed = false
        w.center()
        w.level = .floating
        window = w
        rebuildContent()
        w.makeKeyAndOrderFront(nil)
        if let sv = w.contentView as? NSScrollView, let doc = sv.documentView {
            doc.layoutSubtreeIfNeeded()
            let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
            sv.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            sv.reflectScrolledClipView(sv.contentView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func rebuildContent() {
        guard let w = window, let prefs else { return }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 680))
        container.autoresizingMask = [.width, .height]

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        stack.addArrangedSubview(searchHeader(prefs))
        stack.addArrangedSubview(reminderCard(prefs))
        stack.addArrangedSubview(quietCard(prefs))
        stack.addArrangedSubview(deliveryCard(prefs))
        stack.addArrangedSubview(petCard(prefs))
        stack.addArrangedSubview(aboutCard())
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // 底部按钮条（独立于滚动区）
        let footer = NSStackView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        let hint = NSTextField(labelWithString: "修改立即生效")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        footer.addArrangedSubview(hint)
        footer.addArrangedSubview(NSView())
        let quitBtn = NSButton(title: "退出桌宠", target: self, action: #selector(doQuit))
        quitBtn.bezelStyle = .rounded
        quitBtn.controlSize = .small
        footer.addArrangedSubview(quitBtn)
        let doneBtn = NSButton(title: "完成", target: self, action: #selector(doClose))
        doneBtn.bezelStyle = .rounded
        doneBtn.controlSize = .small
        doneBtn.keyEquivalent = "\r"
        footer.addArrangedSubview(doneBtn)

        container.addSubview(scroll)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 24)
        ])

        w.contentView = container
        container.layoutSubtreeIfNeeded()
        let maxY = max(0, content.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - 区块构建

    private func searchHeader(_ prefs: Preferences) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 3

        let title = NSTextField(labelWithString: "久坐提醒")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let sub = NSTextField(labelWithString: "到点由桌宠亲自喊你起来活动，默认每 45 分钟一次")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        container.addArrangedSubview(title)
        container.addArrangedSubview(sub)
        return container
    }

    private func cardContainer(_ title: String, rows: [NSView]) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor

        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 9
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addArrangedSubview(label(title, size: 11, weight: .semibold, color: .secondaryLabelColor))
        for r in rows { v.addArrangedSubview(r) }
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 13),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -13),
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -13)
        ])
        for r in v.arrangedSubviews { r.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        return box
    }

    private func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        return t
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        return s
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    private func switchToggle(_ title: String, on: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = on ? .on : .off
        b.font = .systemFont(ofSize: 13)
        return b
    }

    // MARK: - 各卡片

    private func reminderCard(_ prefs: Preferences) -> NSView {
        var rows: [NSView] = []
        rows.append(switchToggle("启用定时提醒", on: prefs.reminderEnabled, action: #selector(toggleReminder(_:))))

        intervalField = NSTextField(labelWithString: "\(prefs.intervalMinutes)")
        intervalField.alignment = .right
        intervalField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        intervalField.textColor = .labelColor

        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 240
        stepper.increment = 5
        stepper.integerValue = prefs.intervalMinutes
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        let intervalRow = row([label("提醒间隔"), spacer(), intervalField, label("分钟", color: .secondaryLabelColor), stepper])
        intervalField.widthAnchor.constraint(equalToConstant: 46).isActive = true
        rows.append(intervalRow)

        let quick = NSStackView()
        quick.orientation = .horizontal
        quick.spacing = 6
        for m in [25, 45, 60, 90] {
            let b = NSButton(title: "\(m) 分钟", target: self, action: #selector(quickInterval(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = m
            quick.addArrangedSubview(b)
        }
        quick.addArrangedSubview(spacer())
        let fire = NSButton(title: "立即试一次", target: self, action: #selector(doFireNow))
        fire.bezelStyle = .rounded
        fire.controlSize = .small
        quick.addArrangedSubview(fire)
        rows.append(quick)

        // 文案编辑
        rows.append(label("提醒文案（每行一条，随机使用）", size: 11, color: .secondaryLabelColor))
        let textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let tv = NSTextView()
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 12)
        tv.string = prefs.reminderMessages.joined(separator: "\n")
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.delegate = self
        tv.autoresizingMask = [.width]
        textScroll.documentView = tv
        messagesTextView = tv
        rows.append(textScroll)

        let restore = NSButton(title: "恢复默认文案", target: self, action: #selector(restoreMessages))
        restore.bezelStyle = .inline
        restore.controlSize = .small
        rows.append(restore)

        return cardContainer("提醒节奏", rows: rows)
    }

    private func timePicker(_ hhmm: String) -> NSDatePicker {
        let p = NSDatePicker()
        p.datePickerStyle = .textFieldAndStepper
        p.datePickerElements = .hourMinute
        p.dateValue = Self.timeToDate(hhmm)
        p.target = self
        p.action = #selector(timeChanged(_:))
        p.controlSize = .small
        return p
    }

    private func quietCard(_ prefs: Preferences) -> NSView {
        var rows: [NSView] = []
        rows.append(switchToggle("午休时段不提醒", on: prefs.quietHoursEnabled, action: #selector(toggleQuiet(_:))))
        quietStartPicker = timePicker(prefs.quietStart)
        quietEndPicker = timePicker(prefs.quietEnd)
        rows.append(row([label("从", size: 12, color: .secondaryLabelColor), quietStartPicker,
                         label("至", size: 12, color: .secondaryLabelColor), quietEndPicker, spacer()]))
        rows.append(switchToggle("夜间不提醒", on: prefs.nightSilenceEnabled, action: #selector(toggleNight(_:))))
        nightStartPicker = timePicker(prefs.nightStart)
        nightEndPicker = timePicker(prefs.nightEnd)
        rows.append(row([label("从", size: 12, color: .secondaryLabelColor), nightStartPicker,
                         label("至", size: 12, color: .secondaryLabelColor), nightEndPicker, spacer()]))
        return cardContainer("免打扰时段", rows: rows)
    }

    private func deliveryCard(_ prefs: Preferences) -> NSView {
        var rows: [NSView] = []
        rows.append(switchToggle("发送系统通知（通知中心）", on: prefs.showSystemNotification,
                                 action: #selector(toggleNotification(_:))))
        rows.append(switchToggle("提醒时播放提示音", on: prefs.playSound, action: #selector(toggleSound(_:))))

        breakLabel = label("\(prefs.breakSeconds) 秒", size: 12, color: .secondaryLabelColor)
        breakLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let st = NSStepper()
        st.minValue = 4
        st.maxValue = 60
        st.increment = 2
        st.integerValue = prefs.breakSeconds
        st.target = self
        st.action = #selector(breakChanged(_:))
        breakStepper = st
        rows.append(row([label("气泡停留"), spacer(), breakLabel, st]))
        return cardContainer("提醒方式", rows: rows)
    }

    private func petCard(_ prefs: Preferences) -> NSView {
        var rows: [NSView] = []
        scaleSlider = NSSlider(value: prefs.petScale, minValue: 0.35, maxValue: 1.15,
                               target: self, action: #selector(scaleChanged(_:)))
        scaleSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        scaleLabel = label("\(Int(prefs.petScale * 100))%", size: 12, color: .secondaryLabelColor)
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rows.append(row([label("大小"), scaleSlider, scaleLabel, spacer()]))

        rows.append(switchToggle("始终置顶", on: prefs.alwaysOnTop, action: #selector(toggleTop(_:))))
        rows.append(switchToggle("空闲时随机表演小动作", on: prefs.randomActionsEnabled,
                                 action: #selector(toggleRandom(_:))))
        rows.append(switchToggle("开机自动启动", on: prefs.launchAtLogin, action: #selector(toggleLaunch(_:))))
        return cardContainer("桌宠", rows: rows)
    }

    private func aboutCard() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 3
        let a = label("动画素材来自开源项目 MerZlin/dsh-pet-indesktop（MIT 许可）", size: 10, color: .tertiaryLabelColor)
        let b = label("角色形象「LuckyPet」源自社区创作；本程序完全本地运行，不联网、不上传数据。",
                      size: 10, color: .tertiaryLabelColor)
        v.addArrangedSubview(a)
        v.addArrangedSubview(b)
        return v
    }

    // MARK: - 动作

    private func commit(_ mutate: (inout Preferences) -> Void) {
        guard var p = prefs else { return }
        mutate(&p)
        prefs = p
        p.save()
        onChange?(p)
    }

    @objc private func toggleReminder(_ b: NSButton) {
        commit { $0.reminderEnabled = (b.state == .on) }
    }
    @objc private func toggleQuiet(_ b: NSButton) {
        commit { $0.quietHoursEnabled = (b.state == .on) }
    }
    @objc private func toggleNight(_ b: NSButton) {
        commit { $0.nightSilenceEnabled = (b.state == .on) }
    }
    @objc private func toggleNotification(_ b: NSButton) {
        commit { $0.showSystemNotification = (b.state == .on) }
    }
    @objc private func toggleSound(_ b: NSButton) {
        commit { $0.playSound = (b.state == .on) }
    }
    @objc private func toggleTop(_ b: NSButton) {
        commit { $0.alwaysOnTop = (b.state == .on) }
    }
    @objc private func toggleRandom(_ b: NSButton) {
        commit { $0.randomActionsEnabled = (b.state == .on) }
    }
    @objc private func toggleLaunch(_ b: NSButton) {
        commit { $0.launchAtLogin = (b.state == .on) }
        if prefs?.launchAtLogin == true { LaunchHelper.register() } else { LaunchHelper.unregister() }
    }

    @objc private func intervalChanged(_ f: NSTextField) {
        let v = max(1, min(240, f.integerValue))
        f.stringValue = "\(v)"
        commit { $0.intervalMinutes = v }
    }
    @objc private func stepperChanged(_ s: NSStepper) {
        intervalField.stringValue = "\(s.integerValue)"
        commit { $0.intervalMinutes = s.integerValue }
    }
    @objc private func quickInterval(_ b: NSButton) {
        intervalField.stringValue = "\(b.tag)"
        commit { $0.intervalMinutes = b.tag }
    }
    @objc private func breakChanged(_ s: NSStepper) {
        breakLabel.stringValue = "\(s.integerValue) 秒"
        commit { $0.breakSeconds = s.integerValue }
    }
    @objc private func scaleChanged(_ s: NSSlider) {
        let v = (s.doubleValue * 100).rounded() / 100
        scaleLabel.stringValue = "\(Int(v * 100))%"
        commit { $0.petScale = v }
    }
    @objc private func timeChanged(_ p: NSDatePicker) {
        let s = Self.dateToTime(p.dateValue)
        if p === quietStartPicker { commit { $0.quietStart = s } }
        else if p === quietEndPicker { commit { $0.quietEnd = s } }
        else if p === nightStartPicker { commit { $0.nightStart = s } }
        else if p === nightEndPicker { commit { $0.nightEnd = s } }
    }
    @objc private func restoreMessages() {
        let d = defaultReminderMessages
        messagesTextView.string = d.joined(separator: "\n")
        commit { $0.reminderMessages = d }
    }
    @objc private func doFireNow() { onFireNow?() }
    @objc private func doQuit() { onQuit?() }
    @objc private func doClose() { window?.close() }

    private static func timeToDate(_ hhmm: String) -> Date {
        let mins = Preferences.minutes(from: hhmm) ?? 0
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = mins / 60
        c.minute = mins % 60
        return Calendar.current.date(from: c) ?? Date()
    }

    private static func dateToTime(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

extension SettingsWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let tv = messagesTextView else { return }
        let lines = tv.string.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        commit { $0.reminderMessages = lines.isEmpty ? defaultReminderMessages : lines }
    }
}

/// 开机自启封装
enum LaunchHelper {
    static func register() {
        if #available(macOS 13.0, *) {
            do { try SMAppService.mainApp.register() }
            catch { NSLog("[Pet] 开机自启注册失败: \(error.localizedDescription)") }
        }
    }
    static func unregister() {
        if #available(macOS 13.0, *) {
            do { try SMAppService.mainApp.unregister() }
            catch { NSLog("[Pet] 取消开机自启失败: \(error.localizedDescription)") }
        }
    }
}
