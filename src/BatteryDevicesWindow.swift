import Cocoa

/// 设备管理独立于提醒设置，列表中所有设备的电量与连接状态同步显示。
@MainActor
final class BatteryDevicesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let monitor: DeviceBatteryMonitor
    private let selectDevice: (BatteryDevice) -> Void
    private let toggleEnabled: () -> Void
    private var list: NSStackView?
    private var statusLabel: NSTextField?
    private var selectedLabel: NSTextField?
    private var enabledButton: NSButton?
    private var scanButton: NSButton?
    private var refreshButton: NSButton?

    init(monitor: DeviceBatteryMonitor, selectDevice: @escaping (BatteryDevice) -> Void,
         toggleEnabled: @escaping () -> Void) {
        self.monitor = monitor
        self.selectDevice = selectDevice
        self.toggleEnabled = toggleEnabled
    }

    func show() {
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        monitor.setBrowsing(true)
        update()
    }

    func windowWillClose(_ notification: Notification) { monitor.setBrowsing(false) }

    func update() {
        guard window?.isVisible == true, let list else { return }
        enabledButton?.state = monitor.isEnabled ? .on : .off
        selectedLabel?.stringValue = "菜单栏当前设备：\(monitor.selectedDevice.name)"
        statusLabel?.stringValue = monitor.bluetooth.status
        scanButton?.title = monitor.bluetooth.isScanning ? "扫描中…" : "扫描附近设备"
        scanButton?.isEnabled = !monitor.bluetooth.isScanning
        refreshButton?.isEnabled = !monitor.bluetooth.isRefreshing && !monitor.mouse.isRefreshing
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        for device in monitor.devices { list.addArrangedSubview(deviceRow(device)) }
        for view in list.arrangedSubviews { view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "LuckyPet · 设备与电量"
        w.minSize = NSSize(width: 540, height: 440)
        w.maxSize = NSSize(width: 1000, height: 1200)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        let root = NSStackView()
        root.orientation = .vertical
        root.distribution = .fill
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = BatterySurfaceView(card: false)
        w.contentView = content
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        root.addArrangedSubview(label("设备与电量", size: 22, weight: .semibold))
        let subtitle = label("选择菜单栏显示的设备，也可以查看其他设备的电量。", size: 12, secondary: true)
        root.addArrangedSubview(subtitle)
        let toggle = NSButton(checkboxWithTitle: "菜单栏显示设备电量", target: self, action: #selector(toggle))
        enabledButton = toggle
        root.addArrangedSubview(toggle)
        let selected = label("", size: 12, secondary: true)
        selected.lineBreakMode = .byTruncatingMiddle
        selectedLabel = selected
        root.addArrangedSubview(selected)

        let actions = NSStackView()
        actions.distribution = .fill
        actions.spacing = 8
        let refresh = button("刷新电量", action: #selector(refresh))
        let scan = button("扫描附近设备", action: #selector(scan))
        actions.addArrangedSubview(refresh)
        actions.addArrangedSubview(scan)
        actions.addArrangedSubview(button("系统蓝牙设置…", action: #selector(openBluetooth)))
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.addArrangedSubview(space)
        refreshButton = refresh
        scanButton = scan
        root.addArrangedSubview(actions)

        let status = label("", size: 11, secondary: true)
        status.preferredMaxLayoutWidth = 490
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        statusLabel = status
        root.addArrangedSubview(status)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = FlippedBatteryView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.distribution = .fill
        rows.alignment = .leading
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        list = rows
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -2)
        ])
        root.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let hint = label("新耳机、键盘和手柄请先在系统蓝牙设置中配对。电量取决于设备支持；左右耳与充电盒会分别列出。", size: 11, secondary: true)
        hint.preferredMaxLayoutWidth = 490
        hint.maximumNumberOfLines = 3
        hint.lineBreakMode = .byWordWrapping
        root.addArrangedSubview(hint)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }

    private func deviceRow(_ device: BatteryDevice) -> NSView {
        let box = BatterySurfaceView(card: true, selected: device.id == monitor.selectedID)
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12)
        ])
        let icon = NSImageView(image: NSImage(systemSymbolName: device.symbol, accessibilityDescription: device.kind) ?? NSImage())
        icon.contentTintColor = device.id == monitor.selectedID ? .controlAccentColor : .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        row.addArrangedSubview(icon)
        let details = NSStackView()
        details.orientation = .vertical
        details.distribution = .fill
        details.alignment = .leading
        details.spacing = 4
        let name = label(device.name, size: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        details.addArrangedSubview(name)
        details.addArrangedSubview(label(device.detail, size: 11, secondary: true))
        let source = device.id == BatteryDevice.mouseID ? "有线 / 2.4G 接收器" :
            device.id.hasPrefix("gc:") ? "系统手柄 · 本次连接" : device.id.hasPrefix("ble:") ? "低功耗蓝牙" : "已配对蓝牙"
        details.addArrangedSubview(label(source, size: 10, secondary: true))
        if !device.components.isEmpty { details.addArrangedSubview(label(device.components.joined(separator: " · "), size: 11, secondary: true)) }
        if let reading = device.reading {
            details.addArrangedSubview(label("更新于 \(MouseBatteryMonitor.timeFormatter.string(from: reading.timestamp))", size: 10, secondary: true))
        }
        if let message = device.message {
            let error = label(message, size: 11, secondary: true)
            error.lineBreakMode = .byWordWrapping
            error.preferredMaxLayoutWidth = 320
            error.maximumNumberOfLines = 3
            details.addArrangedSubview(error)
        }
        row.addArrangedSubview(details)
        details.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in details.arrangedSubviews { view.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true }
        let actions = NSStackView()
        actions.orientation = .vertical
        actions.distribution = .fill
        actions.spacing = 6
        let choose = button(device.id == monitor.selectedID ? "已选中" : "显示电量", action: #selector(choose(_:)))
        choose.identifier = NSUserInterfaceItemIdentifier(device.id)
        choose.isEnabled = device.id != monitor.selectedID
        actions.addArrangedSubview(choose)
        if device.id.hasPrefix("bt:") || device.id.hasPrefix("ble:") {
            let connect = button(device.connection == .connecting ? "连接中…" : "连接", action: #selector(connect(_:)))
            connect.identifier = NSUserInterfaceItemIdentifier(device.id)
            connect.isEnabled = device.connection != .connected && device.connection != .connecting
            actions.addArrangedSubview(connect)
        }
        actions.widthAnchor.constraint(equalToConstant: 90).isActive = true
        actions.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(actions)
        details.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -140).isActive = true
        return box
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func choose(_ sender: NSButton) {
        guard let device = monitor.devices.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        selectDevice(device)
    }
    @objc private func connect(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { monitor.bluetooth.connect(id) }
    }
    @objc private func toggle() { toggleEnabled() }
    @objc private func refresh() { monitor.refresh() }
    @objc private func scan() { monitor.bluetooth.scan() }
    @objc private func openBluetooth() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
    }
}

private final class FlippedBatteryView: NSView {
    override var isFlipped: Bool { true }
}

/// 动态系统颜色在外观变化时重新解析，避免深色模式出现白底白字。
private final class BatterySurfaceView: NSView {
    private let card: Bool
    private let selected: Bool
    init(card: Bool, selected: Bool = false) {
        self.card = card
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (card ? NSColor.controlBackgroundColor : .windowBackgroundColor).cgColor
            layer?.cornerRadius = card ? 10 : 0
            layer?.borderWidth = card ? 1 : 0
            layer?.borderColor = (selected ? NSColor.controlAccentColor : .separatorColor).cgColor
        }
    }
}
