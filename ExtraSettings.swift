import AppKit

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

struct AceSetting {
    enum Kind {
        case toggle(mask: UInt8? = nil)
        case choice([String], timer: Bool = false)
        case slider(ClosedRange<Int>, signed: Bool = false)
        case name
        case promptMode
        case promptLevel
    }
    let title: String
    let tab: String
    let read: UInt8
    let write: UInt8
    let kind: Kind
    var namespace: UInt8 = 2
    var key: Int { Int(namespace) << 8 | Int(read) }
    var shortcutID: String {
        if case .toggle(let mask) = kind { return "setting.\(namespace).\(read).\(mask ?? 0)" }
        return "setting.\(namespace).\(read)"
    }

    static let all: [AceSetting] = [
        .init(title: "Adaptive noise cancellation", tab: "Audio options", read: 55, write: 56, kind: .toggle()),
        .init(title: "Speak-to-chat", tab: "Audio options", read: 49, write: 50, kind: .toggle()),
        .init(title: "Voice boost in Aware mode", tab: "Audio options", read: 47, write: 48, kind: .toggle()),
        .init(title: "Adaptive EQ", tab: "Audio options", read: 69, write: 68, kind: .toggle()),
        .init(title: "Spatial audio", tab: "Audio options", read: 16, write: 17, kind: .toggle()),
        .init(title: "Head tracking", tab: "Audio options", read: 18, write: 19, kind: .toggle()),
        .init(title: "Dolby head tracking", tab: "Audio options", read: 39, write: 40, kind: .toggle()),
        .init(title: "Dolby audio", tab: "Audio options", read: 35, write: 36, kind: .toggle()),
        .init(title: "Balance · left / right", tab: "Audio options", read: 33, write: 34, kind: .slider(-20...20, signed: true)),
        .init(title: "Headphone volume", tab: "Audio options", read: 3, write: 4, kind: .slider(0...100), namespace: 3),
        .init(title: "Wear detection", tab: "Controls", read: 12, write: 13, kind: .toggle(mask: 1)),
        .init(title: "Pause / resume when worn", tab: "Controls", read: 12, write: 13, kind: .toggle(mask: 2)),
        .init(title: "Answer calls when worn", tab: "Controls", read: 12, write: 13, kind: .toggle(mask: 4)),
        .init(title: "Noise-control button cycles", tab: "Controls", read: 4, write: 6, kind: .choice(["ANC + Aware", "Off + Aware", "Off + ANC", "ANC + Off + Aware"])),
        .init(title: "Content Key press speed", tab: "Controls", read: 45, write: 46, kind: .choice(["Default · 500 ms", "Slower · 750 ms", "Slowest · 1 second"])),
        .init(title: "Accessible LED colours", tab: "Controls", read: 43, write: 44, kind: .toggle()),
        .init(title: "Low power mode", tab: "Power", read: 24, write: 25, kind: .toggle(mask: 1)),
        .init(title: "Automatic low power mode", tab: "Power", read: 24, write: 25, kind: .toggle(mask: 2)),
        .init(title: "Fast charging", tab: "Power", read: 51, write: 52, kind: .toggle()),
        .init(title: "Turn off when idle", tab: "Power", read: 26, write: 27, kind: .choice(["5 minutes", "10 minutes", "30 minutes", "1 hour", "2 hours", "Never"])),
        .init(title: "Sleep timer", tab: "Power", read: 41, write: 42, kind: .choice(["Off", "15 minutes", "30 minutes", "45 minutes", "1 hour", "2 hours"], timer: true)),
        .init(title: "Spoken guidance", tab: "Voice", read: 57, write: 58, kind: .toggle()),
        .init(title: "Spoken battery level", tab: "Voice", read: 59, write: 60, kind: .toggle()),
        .init(title: "Guidance language", tab: "Voice", read: 61, write: 62, kind: .choice(["English (US)", "French"])),
        .init(title: "Prompt volume mode", tab: "Voice", read: 8, write: 9, kind: .promptMode, namespace: 3),
        .init(title: "Custom prompt volume", tab: "Voice", read: 8, write: 9, kind: .promptLevel, namespace: 3),
        .init(title: "Headphone name", tab: "Device", read: 9, write: 10, kind: .name),
        .init(title: "Bluetooth multipoint", tab: "Device", read: 12, write: 11, kind: .toggle(), namespace: 1)
    ]

    func valid(_ bytes: [UInt8]) -> Bool {
        switch kind {
        case .toggle(let mask): return bytes.count == 1 && (mask != nil || bytes[0] <= 1)
        case .choice(let choices, let timer): return bytes.count == (timer ? 2 : 1) && Int(bytes[0]) < choices.count
        case .slider(let range, let signed):
            return bytes.count == 1 && range.contains(signed ? Int(Int8(bitPattern: bytes[0])) : Int(bytes[0]))
        case .name: return !bytes.isEmpty && Int(bytes[0]) == bytes.count - 1 && String(bytes: bytes.dropFirst(), encoding: .utf8) != nil
        case .promptMode, .promptLevel: return bytes.count == 2 && bytes[0] <= 2 && bytes[1] <= 100
        }
    }

    func payload(value: Int, previous: [UInt8]) -> [UInt8]? {
        guard valid(previous) else { return nil }
        switch kind {
        case .toggle(let mask):
            guard value == 0 || value == 1 else { return nil }
            if let mask { return [value == 1 ? previous[0] | mask : previous[0] & ~mask] }
            return [UInt8(value)]
        case .choice(let choices, _): return choices.indices.contains(value) ? [UInt8(value)] : nil
        case .slider(let range, let signed):
            guard range.contains(value) else { return nil }
            return [signed ? UInt8(bitPattern: Int8(value)) : UInt8(value)]
        case .promptMode: return (0...2).contains(value) ? [UInt8(value), previous[1]] : nil
        case .promptLevel: return (0...100).contains(value) ? [2, UInt8(value)] : nil
        case .name: return nil
        }
    }
}

final class ExtraSettings: NSObject {
    private struct Row {
        let setting: AceSetting
        let editor: NSControl
        let action: NSControl
        let state: NSTextField
    }
    private var rows: [Row] = []
    private var cache: [Int: [UInt8]] = [:]
    private var unavailable: Set<Int> = []
    private var idle = false
    var send: ((UInt8, UInt8, [UInt8]) -> Void)?
    var log: ((String) -> Void)?
    var shortcuts: KeyboardShortcuts?
    let deviceStatus = NSTextField(wrappingLabelWithString: "Battery and activity will appear after connecting.")
    private var battery = "Battery: unknown"
    private var activity = "Activity: unknown"
    var headphoneName: String? {
        guard let bytes = cache[2 << 8 | 9] else { return nil }
        return String(bytes: bytes.dropFirst(), encoding: .utf8)
    }

    var readRequests: [(UInt8, UInt8)] {
        var seen = Set<Int>()
        return AceSetting.all.compactMap { seen.insert($0.key).inserted ? ($0.namespace, $0.read) : nil }
    }

    func addTabs(to tabs: NSTabView) {
        for name in ["Audio options", "Controls", "Power", "Voice", "Device"] {
            var views: [NSView] = []
            let note = NSTextField(wrappingLabelWithString: name == "Audio options"
                ? "Availability depends on headphone firmware and playback mode. Each change is checked against the headphones."
                : "Settings are read from your headphones. Unavailable controls remain disabled.")
            note.textColor = .secondaryLabelColor
            views.append(note)
            if name == "Device" { views.append(deviceStatus) }
            for setting in AceSetting.all where setting.tab == name { views.append(makeRow(setting)) }
            let tab = NSTabViewItem(identifier: name)
            tab.label = name
            tab.view = Self.scroll(views)
            tabs.addTabViewItem(tab)
        }
    }

    func makeMenu(_ tab: String, openDevice: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu(title: tab)
        menu.autoenablesItems = false
        for setting in AceSetting.all where setting.tab == tab {
            let bytes = cache[setting.key]
            let enabled = idle && bytes != nil && !unavailable.contains(setting.key)
            let change: (Int) -> Void = { [weak self] value in
                guard let self, self.idle, !self.unavailable.contains(setting.key),
                      let previous = self.cache[setting.key], let payload = setting.payload(value: value, previous: previous) else { return }
                self.setIdle(false)
                self.send?(setting.namespace, setting.write, payload)
            }
            switch setting.kind {
            case .toggle(let mask):
                let on = bytes.map { b in mask.map { b[0] & $0 != 0 } ?? (b[0] == 1) } ?? false
                menu.addItem(ActionMenuItem(setting.title, enabled: enabled, checked: on) { [weak self] in
                    guard let previous = self?.cache[setting.key] else { return }
                    let current = mask.map { previous[0] & $0 != 0 } ?? (previous[0] == 1)
                    change(current ? 0 : 1)
                })
            case .choice(let choices, _):
                addChoices(choices, setting: setting, selected: bytes.map { Int($0[0]) }, enabled: enabled, to: menu, change: change)
            case .promptMode:
                addChoices(["Default", "Follow headphone volume", "Custom"], setting: setting, selected: bytes.map { Int($0[0]) }, enabled: enabled, to: menu, change: change)
            case .slider(let range, let signed):
                let value = bytes.map { signed ? Int(Int8(bitPattern: $0[0])) : Int($0[0]) } ?? 0
                let item = NSMenuItem()
                item.view = MenuSliderView(title: setting.title, value: value, range: range, enabled: enabled, commit: change)
                menu.addItem(item)
            case .promptLevel:
                let item = NSMenuItem()
                item.view = MenuSliderView(title: setting.title, value: bytes.map { Int($0[1]) } ?? 0, range: 0...100, enabled: enabled, commit: change)
                menu.addItem(item)
            case .name:
                menu.addItem(ActionMenuItem("Rename headphones…", enabled: enabled, perform: openDevice))
            }
        }
        return menu
    }

    private func addChoices(_ choices: [String], setting: AceSetting, selected: Int?, enabled: Bool, to menu: NSMenu, change: @escaping (Int) -> Void) {
        let item = NSMenuItem(title: setting.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: setting.title)
        submenu.autoenablesItems = false
        for (index, title) in choices.enumerated() {
            submenu.addItem(ActionMenuItem(title, enabled: enabled, checked: selected == index) { change(index) })
        }
        item.submenu = submenu
        menu.addItem(item)
    }

    static func scroll(_ views: [NSView]) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let content = SettingsDocumentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        scroll.documentView = content
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return scroll
    }

    private func makeRow(_ setting: AceSetting) -> NSView {
        let label = NSTextField(labelWithString: setting.title)
        label.widthAnchor.constraint(equalToConstant: 235).isActive = true
        let state = NSTextField(labelWithString: "Not connected")
        state.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 11)
        let editor: NSControl
        var action: NSControl?
        var extras: [NSView] = []
        switch setting.kind {
        case .toggle:
            editor = NSSwitch()
            if let shortcuts { extras = [shortcuts.checkbox(for: setting.shortcutID)] }
        case .choice(let values, _):
            let menu = NSPopUpButton(); menu.addItems(withTitles: values); editor = menu
        case .slider(let range, _):
            let slider = NSSlider(value: 0, minValue: Double(range.lowerBound), maxValue: Double(range.upperBound), target: nil, action: nil)
            slider.isContinuous = false; slider.widthAnchor.constraint(equalToConstant: 240).isActive = true; editor = slider
        case .promptMode:
            let menu = NSPopUpButton(); menu.addItems(withTitles: ["Default", "Follow headphone volume", "Custom"]); editor = menu
        case .promptLevel:
            let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
            slider.isContinuous = false; slider.widthAnchor.constraint(equalToConstant: 240).isActive = true; editor = slider
        case .name:
            let field = NSTextField(string: "")
            field.widthAnchor.constraint(equalToConstant: 220).isActive = true
            editor = field
            let apply = NSButton(title: "Apply", target: nil, action: nil)
            action = apply; extras = [apply]
        }
        let trigger = action ?? editor
        trigger.tag = rows.count; trigger.target = self; trigger.action = #selector(change(_:))
        editor.isEnabled = false; trigger.isEnabled = false
        editor.setAccessibilityLabel(setting.title)
        let controls = NSStackView(views: [label, editor] + extras)
        controls.orientation = .horizontal; controls.spacing = 12
        let row = NSStackView(views: [controls, state])
        row.orientation = .vertical; row.alignment = .leading; row.spacing = 3
        rows.append(Row(setting: setting, editor: editor, action: trigger, state: state))
        return row
    }

    func reset() {
        cache.removeAll(); unavailable.removeAll()
        for row in rows { row.state.stringValue = "Not connected" }
        battery = "Battery: unknown"; activity = "Activity: unknown"; renderDeviceStatus()
        setIdle(false)
    }

    func setIdle(_ value: Bool) {
        idle = value
        for row in rows {
            let enabled = idle && cache[row.setting.key] != nil && !unavailable.contains(row.setting.key)
            row.editor.isEnabled = enabled; row.action.isEnabled = enabled
        }
    }

    func setBattery(_ value: UInt8) { battery = "Battery: \(value)%"; renderDeviceStatus() }
    func setActivity(_ value: String) { activity = "Activity: \(value)"; renderDeviceStatus() }
    private func renderDeviceStatus() { deviceStatus.stringValue = battery + "\n" + activity }

    @objc private func change(_ sender: NSControl) {
        guard idle, rows.indices.contains(sender.tag) else { return }
        let row = rows[sender.tag], setting = row.setting
        guard let previous = cache[setting.key], !unavailable.contains(setting.key) else { return }
        let payload: [UInt8]?
        if case .name = setting.kind {
            let text = (row.editor as! NSTextField).stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let bytes = Array(text.utf8)
            guard !bytes.isEmpty, bytes.count <= 255 else { row.state.stringValue = "Enter a name of 1–255 UTF-8 bytes."; return }
            payload = [UInt8(bytes.count)] + bytes
        } else {
            let value: Int
            if let toggle = row.editor as? NSSwitch { value = toggle.state == .on ? 1 : 0 }
            else if let menu = row.editor as? NSPopUpButton { value = menu.indexOfSelectedItem }
            else { value = row.editor.integerValue }
            payload = setting.payload(value: value, previous: previous)
        }
        guard let payload else { return }
        row.state.stringValue = "Applying…"
        setIdle(false)
        send?(setting.namespace, setting.write, payload)
    }

    func toggleShortcut(_ setting: AceSetting) {
        guard idle, case .toggle(let mask) = setting.kind,
              let previous = cache[setting.key], !unavailable.contains(setting.key) else { return }
        let on = mask.map { previous[0] & $0 != 0 } ?? (previous[0] == 1)
        guard let payload = setting.payload(value: on ? 0 : 1, previous: previous) else { return }
        for row in rows where row.setting.key == setting.key { row.state.stringValue = "Applying…" }
        setIdle(false)
        send?(setting.namespace, setting.write, payload)
    }

    // A write ACK is never treated as state: only a fresh matching read updates UI.
    func handle(_ response: SonosProtocol.Response) -> Bool {
        let reads = rows.filter { $0.setting.namespace == response.namespace && $0.setting.read == response.command }
        if !reads.isEmpty {
            for row in reads {
                let setting = row.setting
                guard response.status == 0, setting.valid(response.payload) else {
                    cache.removeValue(forKey: setting.key); unavailable.insert(setting.key)
                    row.state.stringValue = response.status == 0 ? "Unrecognised value; control unavailable" : "Unavailable on this device (status \(response.status))"
                    continue
                }
                cache[setting.key] = response.payload; unavailable.remove(setting.key)
                render(row, response.payload)
            }
            return true
        }
        if let setting = AceSetting.all.first(where: { $0.namespace == response.namespace && $0.write == response.command }) {
            if response.status != 0 { failed(namespace: response.namespace, command: response.command, message: "Change rejected (status \(response.status))") }
            else {
                cache.removeValue(forKey: setting.key)
                for row in rows where row.setting.key == setting.key { row.state.stringValue = "Verifying…" }
            }
            // Read after rejection as well, to restore the current device value.
            send?(setting.namespace, setting.read, [])
            return true
        }
        return false
    }

    func failed(namespace: UInt8, command: UInt8, message: String) {
        for row in rows where row.setting.namespace == namespace && (row.setting.read == command || row.setting.write == command) {
            if let bytes = cache[row.setting.key] { render(row, bytes) }
            cache.removeValue(forKey: row.setting.key)
            unavailable.insert(row.setting.key)
            row.state.stringValue = message + " · Refresh to retry"
        }
    }

    private func render(_ row: Row, _ bytes: [UInt8]) {
        switch row.setting.kind {
        case .toggle(let mask):
            let on = mask.map { bytes[0] & $0 != 0 } ?? (bytes[0] == 1)
            (row.editor as! NSSwitch).state = on ? .on : .off
            row.state.stringValue = on ? "On" : "Off"
        case .choice(let choices, let timer):
            (row.editor as! NSPopUpButton).selectItem(at: Int(bytes[0]))
            row.state.stringValue = choices[Int(bytes[0])] + (timer && bytes[0] != 0 ? " · \(bytes[1]) minutes remaining" : "")
        case .slider(_, let signed):
            let value = signed ? Int(Int8(bitPattern: bytes[0])) : Int(bytes[0])
            row.editor.integerValue = value
            row.state.stringValue = signed ? (value == 0 ? "Centred" : "\(abs(value)) toward \(value < 0 ? "left" : "right")") : "\(value)%"
        case .name:
            (row.editor as! NSTextField).stringValue = String(bytes: bytes.dropFirst(), encoding: .utf8)!
            row.state.stringValue = "Saved on the headphones"
        case .promptMode:
            (row.editor as! NSPopUpButton).selectItem(at: Int(bytes[0]))
            row.state.stringValue = "Read from headphones"
        case .promptLevel:
            row.editor.integerValue = Int(bytes[1]); row.state.stringValue = "\(bytes[1])% · adjusting selects Custom mode"
        }
        log?("\(row.setting.title): \(row.state.stringValue)")
    }
}
