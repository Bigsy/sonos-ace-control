import AppKit
import CoreBluetooth
import Foundation

// Independent interoperability probe.
final class AceController: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate, NSMenuDelegate {
    private var manager: CBCentralManager!
    private var window: NSWindow!
    private let tabs = NSTabView()
    private var statusItem: NSStatusItem!
    private var batteryLevel: UInt8?
    private var batteryCharacteristic: CBCharacteristic?
    private var batteryTimer: Timer?
    private let status = NSTextField(wrappingLabelWithString: "Starting Bluetooth…")
    private let sidetoneLabel = NSTextField(labelWithString: "Sidetone: waiting for headphones")
    private let sidetone = NSSwitch()
    private let callAudio = CallAudioTest()
    private let extraSettings = ExtraSettings()
    private let shortcuts = KeyboardShortcuts()
    private let callTest = NSButton(title: "Test call audio", target: nil, action: nil)
    private let callHelp = NSTextField(wrappingLabelWithString: "Opens the Sonos mic for 90 seconds; nothing is recorded. Call audio can reduce playback quality.")
    private let noiseMode = NSPopUpButton()
    private let loudness = NSSwitch()
    private let eqType = NSPopUpButton()
    private var eqSliders: [NSSlider] = []
    private var eqNames: [NSTextField] = []
    private var eqValues: [NSTextField] = []
    private var eqRows: [NSStackView] = []
    private let devices = NSPopUpButton()
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let refresh = NSButton(title: "Refresh settings", target: nil, action: nil)
    private let scan = NSButton(title: "Scan again", target: nil, action: nil)
    private let details = NSTextView()
    private var found: [CBPeripheral] = []
    private var peripheral: CBPeripheral?
    private var write: CBCharacteristic?
    private var notify: CBCharacteristic?
    private var setupWrite: CBCharacteristic?
    private var setupNotify: CBCharacteristic?
    private var expectedAuthReply: UInt8?
    private var attestation: SonosAttestation?
    private var authTimeout: Timer?
    private var pending: UInt8?
    private var pendingNamespace: UInt8 = 2
    private var pendingPayload: [UInt8] = []
    private var timeout: Timer?
    private var queued: [(UInt8, UInt8, [UInt8])] = []
    private var knownSidetone: Bool?
    private var knownNoiseMode: UInt8?
    private var knownLoudness: Bool?
    private var knownEQ: SonosProtocol.EQSettings?
    private var ready = false
    private var connectionIssue: String?
    private let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Ace Control.log")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AceControl", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        buildWindow()
        buildStatusItem()
        log("Ace Control started. Settings are read after connecting; each change is verified by readback.")
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts.stop()
        batteryTimer?.invalidate()
        callAudio.stop()
        if let peripheral { manager.cancelPeripheralConnection(peripheral) }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 720)
        window.title = "Ace Control — Bluetooth prototype"
        window.center()
        let title = NSTextField(labelWithString: "Sonos Ace Control")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "Control your headphones directly from your Mac. Sidetone lets you hear your own voice during calls with ANC on.")
        help.textColor = .secondaryLabelColor
        devices.addItem(withTitle: "Searching for Sonos headphones…")
        devices.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        connect.target = self; connect.action = #selector(connectSelected)
        connect.isEnabled = false
        scan.target = self; scan.action = #selector(scanAgain)
        refresh.target = self; refresh.action = #selector(refreshSettings)
        refresh.isEnabled = false
        sidetone.target = self; sidetone.action = #selector(changeSidetone)
        sidetone.isEnabled = false
        callTest.target = self; callTest.action = #selector(toggleCallAudio)
        callTest.isEnabled = false
        callHelp.textColor = .secondaryLabelColor
        callAudio.changed = { [weak self] active, message in
            guard let self else { return }
            self.callTest.title = active ? "Stop call audio" : "Test call audio"
            self.callTest.isEnabled = active || self.ready
            self.callHelp.stringValue = message
            self.log(message)
        }
        extraSettings.send = { [weak self] namespace, command, payload in
            self?.enqueue(command, payload: payload, namespace: namespace)
        }
        extraSettings.log = { [weak self] in self?.log($0) }
        extraSettings.shortcuts = shortcuts
        shortcuts.add("sidetone", title: "Sidetone") { [weak self] in
            guard let self, self.menuCanWrite, let value = self.knownSidetone else { return }
            self.enqueue(SonosProtocol.setSidetone, payload: [value ? 0 : 1])
        }
        shortcuts.add("noise.cycle", title: "Noise control · next mode") { [weak self] in
            guard let self, self.menuCanWrite, let mode = self.knownNoiseMode, mode <= 2 else { return }
            self.enqueue(SonosProtocol.setANC, payload: [(mode + 1) % 3])
        }
        shortcuts.add("loudness", title: "Loudness") { [weak self] in
            guard let self, self.menuCanWrite, let value = self.knownLoudness else { return }
            self.enqueue(SonosProtocol.setLoudness, payload: [value ? 0 : 1])
        }
        for setting in AceSetting.all {
            guard case .toggle = setting.kind else { continue }
            shortcuts.add(setting.shortcutID, title: setting.title) { [weak self] in
                self?.extraSettings.toggleShortcut(setting)
            }
        }
        noiseMode.addItems(withTitles: ["Off", "Noise cancelling", "Aware"])
        noiseMode.target = self; noiseMode.action = #selector(changeNoiseMode)
        noiseMode.isEnabled = false
        let noiseRow = NSStackView(views: [NSTextField(labelWithString: "Noise control:"), noiseMode, shortcuts.checkbox(for: "noise.cycle")])
        noiseRow.orientation = .horizontal
        noiseRow.spacing = 16
        loudness.target = self; loudness.action = #selector(changeLoudness)
        loudness.isEnabled = false
        loudness.setAccessibilityLabel("Loudness")
        sidetone.setAccessibilityLabel("Sidetone")
        let loudnessRow = NSStackView(views: [NSTextField(labelWithString: "Loudness"), loudness, shortcuts.checkbox(for: "loudness")])
        loudnessRow.orientation = .horizontal
        loudnessRow.spacing = 16
        eqType.addItems(withTitles: ["Basic · 3 bands", "Advanced · 8 bands"])
        eqType.target = self; eqType.action = #selector(changeEQType)
        eqType.isEnabled = false
        let eqHeading = NSStackView(views: [NSTextField(labelWithString: "Equalizer"), eqType])
        eqHeading.orientation = .horizontal
        eqHeading.spacing = 16
        let eqStack = NSStackView()
        eqStack.orientation = .vertical
        eqStack.alignment = .leading
        eqStack.spacing = 5
        for band in 0..<8 {
            let name = NSTextField(labelWithString: band < 3 ? ["Bass", "Mid", "Treble"][band] : "Band \(band + 1)")
            name.widthAnchor.constraint(equalToConstant: 65).isActive = true
            let slider = NSSlider(value: 0, minValue: -10, maxValue: 10, target: self, action: #selector(changeEQBand(_:)))
            slider.tag = band
            slider.isContinuous = false
            slider.numberOfTickMarks = 21
            slider.allowsTickMarkValuesOnly = true
            slider.isEnabled = false
            slider.widthAnchor.constraint(equalToConstant: 430).isActive = true
            slider.setAccessibilityLabel(name.stringValue)
            let value = NSTextField(labelWithString: "0")
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 35).isActive = true
            let row = NSStackView(views: [name, slider, value])
            row.orientation = .horizontal
            row.spacing = 12
            row.isHidden = band >= 3
            eqStack.addArrangedSubview(row)
            eqSliders.append(slider); eqNames.append(name); eqValues.append(value); eqRows.append(row)
        }
        let deviceRow = NSStackView(views: [devices, connect, scan])
        deviceRow.orientation = .horizontal
        let toggleRow = NSStackView(views: [sidetoneLabel, sidetone, shortcuts.checkbox(for: "sidetone"), refresh])
        toggleRow.orientation = .horizontal
        toggleRow.spacing = 16
        details.isEditable = false
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.textColor = .textColor
        details.backgroundColor = .textBackgroundColor
        let scroll = NSScrollView()
        scroll.documentView = details
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let callRow = NSStackView(views: [callTest, callHelp])
        callRow.orientation = .horizontal
        callRow.spacing = 12
        let sound = NSTabViewItem(identifier: "Sound")
        sound.label = "Sound"
        sound.view = ExtraSettings.scroll([toggleRow, callRow, noiseRow, loudnessRow, eqHeading, eqStack])
        tabs.addTabViewItem(sound)
        extraSettings.addTabs(to: tabs)
        shortcuts.addTab(to: tabs)
        let logTab = NSTabViewItem(identifier: "Log")
        logTab.label = "Log"; logTab.view = scroll
        tabs.addTabViewItem(logTab)
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        let stack = NSStackView(views: [title, help, status, deviceRow, tabs])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -22),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let controlsItem = appMenu.addItem(withTitle: "Headphone controls", action: #selector(showStatusMenu), keyEquivalent: "h")
        controlsItem.target = self
        controlsItem.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ace Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        NSApplication.shared.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var menuCanWrite: Bool { ready && pending == nil && queued.isEmpty }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.readBattery() }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = HeadphoneStatusImage.make(battery: batteryLevel)
        let value = batteryLevel.map { "\($0)% battery" } ?? "battery unavailable"
        button.toolTip = "Ace Control · \(value)"
        button.setAccessibilityLabel("Ace Control, \(value)")
    }

    private func readBattery() {
        guard let peripheral, peripheral.state == .connected, let batteryCharacteristic else { return }
        peripheral.readValue(for: batteryCharacteristic)
    }

    @objc private func showStatusMenu() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
        }
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        readBattery()
        menu.removeAllItems()
        let heading = NSMenuItem(title: extraSettings.headphoneName ?? peripheral?.name ?? "Ace Control", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let state = ready ? (menuCanWrite ? "Connected" : "Updating settings…") : (peripheral == nil ? "Disconnected" : "Connecting…")
        let info = NSMenuItem(title: batteryLevel.map { "\($0)% battery · \(state)" } ?? state, action: nil, keyEquivalent: "")
        info.isEnabled = false; menu.addItem(info)
        menu.addItem(.separator())
        let noise = NSMenu(title: "Noise control"); noise.autoenablesItems = false
        for (index, title) in ["Off", "Noise cancelling", "Aware"].enumerated() {
            noise.addItem(ActionMenuItem(title, enabled: menuCanWrite && knownNoiseMode != nil, checked: knownNoiseMode == UInt8(index)) { [weak self] in
                guard let self, self.menuCanWrite, self.knownNoiseMode != nil else { return }
                self.enqueue(SonosProtocol.setANC, payload: [UInt8(index)])
            })
        }
        addSubmenu(noise, to: menu)
        menu.addItem(ActionMenuItem("Sidetone", enabled: menuCanWrite && knownSidetone != nil, checked: knownSidetone == true) { [weak self] in
            guard let self, self.menuCanWrite, let value = self.knownSidetone else { return }
            self.enqueue(SonosProtocol.setSidetone, payload: [value ? 0 : 1])
        })
        menu.addItem(ActionMenuItem("Loudness", enabled: menuCanWrite && knownLoudness != nil, checked: knownLoudness == true) { [weak self] in
            guard let self, self.menuCanWrite, let value = self.knownLoudness else { return }
            self.enqueue(SonosProtocol.setLoudness, payload: [value ? 0 : 1])
        })
        let eqMenu = NSMenu(title: "Equalizer"); eqMenu.autoenablesItems = false
        for (index, title) in ["Basic · 3 bands", "Advanced · 8 bands"].enumerated() {
            eqMenu.addItem(ActionMenuItem(title, enabled: menuCanWrite && knownEQ?.bands[UInt8(index)] != nil, checked: knownEQ?.active == UInt8(index)) { [weak self] in
                guard let self, self.menuCanWrite, self.knownEQ?.bands[UInt8(index)] != nil else { return }
                self.enqueue(SonosProtocol.setEQType, payload: [UInt8(index)])
            })
        }
        if let eq = knownEQ, eq.active <= 1, let values = eq.bands[eq.active] {
            eqMenu.addItem(.separator())
            for (index, value) in values.enumerated() {
                let title = eq.active == 0 && index < 3 ? ["Bass", "Mid", "Treble"][index] : "Band \(index + 1)"
                let item = NSMenuItem()
                item.view = MenuSliderView(title: title, value: value, range: -10...10, enabled: menuCanWrite && (-10...10).contains(value)) { [weak self] value in
                    guard let self, self.menuCanWrite, let current = self.knownEQ, current.active == eq.active,
                          current.bands[current.active]?.indices.contains(index) == true, (-10...10).contains(value) else { return }
                    self.enqueue(SonosProtocol.setEQBand, payload: [current.active, UInt8(index), UInt8(bitPattern: Int8(value))])
                }
                eqMenu.addItem(item)
            }
        }
        addSubmenu(eqMenu, to: menu)
        for name in ["Audio options", "Controls", "Power", "Voice", "Device"] {
            addSubmenu(extraSettings.makeMenu(name) { [weak self] in
                self?.tabs.selectTabViewItem(withIdentifier: "Device")
                self?.showWindow()
            }, to: menu)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(callAudio.isActive ? "Stop call audio test" : "Test call audio…", enabled: ready || callAudio.isActive) { [weak self] in self?.toggleCallAudio() })
        menu.addItem(ActionMenuItem("Refresh settings", enabled: menuCanWrite) { [weak self] in
            guard self?.menuCanWrite == true else { return }
            self?.refreshSettings()
        })
        menu.addItem(ActionMenuItem("Keyboard shortcuts…") { [weak self] in
            self?.tabs.selectTabViewItem(withIdentifier: "Shortcuts")
            self?.showWindow()
        })
        menu.addItem(ActionMenuItem("Open Ace Control…") { [weak self] in self?.showWindow() })
        menu.addItem(ActionMenuItem(peripheral == nil ? "Connect" : "Disconnect", enabled: connect.isEnabled) { [weak self] in self?.connectSelected() })
        menu.addItem(ActionMenuItem("Scan for headphones", enabled: scan.isEnabled) { [weak self] in self?.scanAgain() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Quit Ace Control") { NSApplication.shared.terminate(nil) })
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        details.textStorage?.append(NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]))
        details.scrollToEndOfDocument(nil)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else { try? Data(line.utf8).write(to: logURL) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scanAgain()
        case .unauthorized: status.stringValue = "Allow Ace Control in System Settings → Privacy & Security → Bluetooth."; log("Bluetooth permission denied or awaiting approval.")
        case .poweredOff: status.stringValue = "Turn on Bluetooth on your Mac."
        case .unsupported: status.stringValue = "Bluetooth is unsupported."
        default: status.stringValue = "Bluetooth state: \(central.state.rawValue)"
        }
    }

    @objc private func scanAgain() {
        guard manager.state == .poweredOn, peripheral == nil else { return }
        // Developer probe mode uses an explicitly supplied, previously verified
        // peripheral UUID; it never chooses an arbitrary nearby device.
        if let option = CommandLine.arguments.firstIndex(of: "--probe-device"),
           CommandLine.arguments.indices.contains(option + 1),
           let id = UUID(uuidString: CommandLine.arguments[option + 1]),
           let cached = manager.retrievePeripherals(withIdentifiers: [id]).first {
            add(cached)
            if let index = found.firstIndex(where: { $0.identifier == id }) {
                devices.selectItem(at: index)
                connectSelected()
            }
            return
        }
        status.stringValue = "Searching for the Sonos BLE service…"
        if let saved = UserDefaults.standard.string(forKey: "lastHeadphones"),
           let id = UUID(uuidString: saved),
           let cached = manager.retrievePeripherals(withIdentifiers: [id]).first {
            add(cached)
        }
        for device in manager.retrieveConnectedPeripherals(withServices: [CBUUID(string: SonosProtocol.service)]) { add(device) }
        manager.scanForPeripherals(withServices: [CBUUID(string: SonosProtocol.service)], options: nil)
        log("Scanning for service FE07.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self else { return }
            self.manager.stopScan()
            if self.found.isEmpty { self.status.stringValue = "No Sonos headphones found. Keep them on and nearby; close the phone app if necessary, then scan again." }
        }
    }

    private func add(_ device: CBPeripheral) {
        if let index = found.firstIndex(where: { $0.identifier == device.identifier }) {
            if let name = device.name { devices.item(at: index)?.title = name }
            return
        }
        if found.isEmpty { devices.removeAllItems() }
        found.append(device)
        devices.addItem(withTitle: device.name ?? "Sonos device \(device.identifier.uuidString.prefix(8))")
        connect.isEnabled = peripheral == nil
        status.stringValue = "Found \(found.count) Sonos device(s). Choose your headphones and Connect."
        log("Found \(device.name ?? "unnamed Sonos device") [\(device.identifier)].")
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) { add(device) }

    @objc private func connectSelected() {
        if let peripheral {
            manager.cancelPeripheralConnection(peripheral)
            return
        }
        guard devices.indexOfSelectedItem >= 0, devices.indexOfSelectedItem < found.count else { return }
        let selected = found[devices.indexOfSelectedItem]
        // Sonos headphones may advertise without a local name. Verify the
        // headphone-specific control characteristics before issuing requests.
        let name = selected.name ?? "Sonos BLE device"
        connectionIssue = nil
        attestation = nil
        manager.stopScan()
        peripheral = selected
        selected.delegate = self
        connect.isEnabled = false
        scan.isEnabled = false
        status.stringValue = "Connecting to \(name)…"
        log("Connecting to \(name).")
        manager.connect(selected, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self, weak selected] in
            guard let self, let selected, self.peripheral === selected, !self.ready else { return }
            self.log("Connection setup timed out. Try closing Sonos on the phone and reconnecting.")
            self.status.stringValue = "Connection timed out. Close Sonos on the phone, then try again."
            self.manager.cancelPeripheralConnection(selected)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        connect.title = "Disconnect"
        connect.isEnabled = true
        log("Connected. Discovering control service.")
        device.discoverServices([CBUUID(string: SonosProtocol.service), CBUUID(string: "180F")])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) { disconnected(error) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) { disconnected(error) }

    private func disconnected(_ error: Error?) {
        callAudio.stop()
        extraSettings.reset()
        batteryCharacteristic = nil; batteryLevel = nil
        updateStatusItem()
        log("Disconnected: \(error?.localizedDescription ?? "connection closed").")
        timeout?.invalidate(); timeout = nil
        authTimeout?.invalidate(); authTimeout = nil; expectedAuthReply = nil
        attestation = nil
        ready = false; knownSidetone = nil; knownNoiseMode = nil; pending = nil
        knownLoudness = nil; knownEQ = nil
        queued.removeAll(); write = nil; notify = nil; setupWrite = nil; setupNotify = nil; peripheral = nil
        sidetone.isEnabled = false; refresh.isEnabled = false
        noiseMode.isEnabled = false
        updateControlAvailability()
        connect.isEnabled = !found.isEmpty
        connect.title = "Connect"
        scan.isEnabled = true
        status.stringValue = connectionIssue ?? "Disconnected. Choose the headphones and reconnect."
    }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("Service error: \(error.localizedDescription)"); return }
        for service in device.services ?? [] where service.uuid == CBUUID(string: "180F") {
            device.discoverCharacteristics([CBUUID(string: "2A19")], for: service)
        }
        guard let service = device.services?.first(where: { $0.uuid == CBUUID(string: SonosProtocol.service) }) else { log("Sonos service was not found."); return }
        device.discoverCharacteristics([CBUUID(string: SonosProtocol.controlWrite), CBUUID(string: SonosProtocol.controlNotify), CBUUID(string: SonosProtocol.setupWrite), CBUUID(string: SonosProtocol.setupNotify)], for: service)
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("Characteristic error: \(error.localizedDescription)"); return }
        if service.uuid == CBUUID(string: "180F") {
            for characteristic in service.characteristics ?? [] where characteristic.properties.contains(.read) {
                batteryCharacteristic = characteristic
                device.readValue(for: characteristic)
            }
            return
        }
        for characteristic in service.characteristics ?? [] {
            log("Control characteristic \(characteristic.uuid), properties=\(characteristic.properties.rawValue).")
            if characteristic.uuid == CBUUID(string: SonosProtocol.controlWrite) { write = characteristic }
            if characteristic.uuid == CBUUID(string: SonosProtocol.controlNotify) { notify = characteristic }
            if characteristic.uuid == CBUUID(string: SonosProtocol.setupWrite) { setupWrite = characteristic }
            if characteristic.uuid == CBUUID(string: SonosProtocol.setupNotify) { setupNotify = characteristic }
        }
        guard write != nil, notify != nil, setupWrite != nil, let setupNotify else { log("Required Sonos characteristics were not found."); return }
        // The working Android capture subscribes to setup and authenticates
        // before subscribing to control notifications.
        device.setNotifyValue(true, for: setupNotify)
    }

    func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            let failure = error as NSError
            log("Notification error: \(failure.domain) code \(failure.code): \(error.localizedDescription)")
            if failure.domain == CBATTErrorDomain && [5, 12, 15].contains(failure.code) {
                connectionIssue = "Secure BLE pairing is needed. Put the headphones in pairing mode, then reconnect and accept any macOS pairing prompt."
            } else if failure.domain == "CBInternalErrorDomain" && failure.code == 13 {
                connectionIssue = "Headphone control connection is busy. Close Sonos on your phone, then reconnect here."
            } else {
                connectionIssue = "Control subscription failed: \(error.localizedDescription)"
            }
            status.stringValue = connectionIssue!
            manager.cancelPeripheralConnection(device)
            return
        }
        guard characteristic.isNotifying else { return }
        if characteristic.uuid == CBUUID(string: SonosProtocol.controlNotify) {
            log("Control notifications enabled. Reading sidetone, EQ, ANC and loudness.")
            ready = true
            refreshSettings()
        } else if characteristic.uuid == CBUUID(string: SonosProtocol.setupNotify) {
            attestation = SonosAttestation()
            sendAuthentication(SonosAttestation.hello(), expecting: 1, label: "device-verification hello")
        }
    }

    private func sendAuthentication(_ data: Data, expecting reply: UInt8, label: String) {
        guard let peripheral, let setupWrite else { return }
        expectedAuthReply = reply
        let type: CBCharacteristicWriteType = setupWrite.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        guard data.count <= peripheral.maximumWriteValueLength(for: type) else { authenticationFailed("Authentication message exceeds the negotiated BLE write size."); return }
        status.stringValue = "Authenticating with headphones: \(label)…"
        // Never write authentication tokens to logs or disk.
        log("Authentication TX: \(label) (\(data.count) bytes).")
        peripheral.writeValue(data, for: setupWrite, type: type)
        authTimeout?.invalidate()
        authTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.authenticationFailed("Authentication timed out during \(label).")
        }
    }

    private func authenticationFailed(_ message: String) {
        authTimeout?.invalidate(); authTimeout = nil; expectedAuthReply = nil
        connectionIssue = message
        status.stringValue = message
        log(message)
        if let peripheral { manager.cancelPeripheralConnection(peripheral) }
    }

    private func handleAuthentication(_ data: Data) {
        if data.first == 0, let attestation {
            log("Device verification RX: message \(data.dropFirst().first.map(String.init) ?? "unknown"), \(data.count) bytes.")
            do {
                switch try attestation.receive(data) {
                case .waiting: break
                case .send(let challenge):
                    sendAuthentication(challenge, expecting: 5, label: "device-verification challenge")
                case .complete:
                    self.attestation = nil
                    log("Device challenge signature verified. Starting token negotiation.")
                    sendAuthentication(SonosAuthentication.hello, expecting: 1, label: "client hello after device verification")
                }
            } catch { authenticationFailed(error.localizedDescription) }
            return
        }
        guard let message = SonosAuthentication.parse(data), message.type == expectedAuthReply else {
            log("Ignored unrelated or malformed authentication message (\(data.count) bytes).")
            return
        }
        authTimeout?.invalidate()
        log("Authentication RX: message \(message.type), status \(message.status.map(String.init) ?? "not supplied").")
        if let status = message.status, status != 0 { authenticationFailed("Headphones rejected authentication step \(message.type): status \(status)."); return }
        switch message.type {
        case 1:
            guard message.elements[1] == [1, 0, 0, 0], let flags = message.elements[2], flags.count == 4, flags[3] & 1 == 1 else {
                authenticationFailed("Headphones did not offer the expected pairwise authentication protocol.")
                return
            }
            sendAuthentication(SonosAuthentication.selectPairwise, expecting: 3, label: "select pairwise authentication")
        case 3:
            guard message.status == 0 else { authenticationFailed("Authentication method reply has no success status."); return }
            sendAuthentication(SonosAuthentication.requestCommonToken, expecting: 5, label: "request common-access token")
        case 5:
            guard message.status == 0, let token = message.elements[4], let request = SonosAuthentication.authenticate(token: token) else {
                authenticationFailed("Headphones did not issue a valid common-access token.")
                return
            }
            sendAuthentication(request, expecting: 7, label: "authenticate common-access session")
        case 7:
            guard message.status == 0 else { authenticationFailed("Authentication response has no success status."); return }
            if let peripheral { UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastHeadphones") }
            expectedAuthReply = nil
            status.stringValue = "Session authenticated. Subscribing to controls…"
            log("Session authenticated. Enabling control notifications.")
            if let peripheral, let notify { peripheral.setNotifyValue(true, for: notify) }
        default: authenticationFailed("Unexpected authentication response.")
        }
    }

    @objc private func refreshSettings() {
        guard ready, pending == nil else { return }
        readBattery()
        readActivity()
        enqueue(SonosProtocol.getSidetone)
        enqueue(SonosProtocol.getEQ)
        enqueue(SonosProtocol.getANC)
        enqueue(SonosProtocol.getLoudness)
        for (namespace, command) in extraSettings.readRequests { enqueue(command, namespace: namespace) }
    }

    private func readActivity() {
        guard ready, let peripheral, let write, peripheral.canSendWriteWithoutResponse else { return }
        // Read-only status namespace command from HeadphonesTargetStatusApi.
        peripheral.writeValue(Data([0, 0, 5]), for: write, type: .withoutResponse)
        log("Reading headphone activity (status namespace, getCurrentActivity).")
    }

    private func enqueue(_ command: UInt8, payload: [UInt8] = [], namespace: UInt8 = 2) {
        queued.append((namespace, command, payload))
        sendNext()
    }

    private func sendNext() {
        guard pending == nil, !queued.isEmpty, ready, let peripheral, let write else { return }
        let (namespace, command, payload) = queued.removeFirst()
        let data = Data([0, namespace, command] + payload)
        let type: CBCharacteristicWriteType
        if write.properties.contains(.writeWithoutResponse) { type = .withoutResponse }
        else if write.properties.contains(.write) { type = .withResponse }
        else { log("Control characteristic is not writable."); return }
        if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
            queued.insert((namespace, command, payload), at: 0)
            return
        }
        pending = command; pendingNamespace = namespace; pendingPayload = payload
        updateControlAvailability()
        log("TX \(data.hex)")
        peripheral.writeValue(data, for: write, type: type)
        timeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.log("No response for command \(command).")
            self.status.stringValue = "No response. The phone app may be holding the control connection."
            self.extraSettings.failed(namespace: namespace, command: command, message: "No response")
            if command == SonosProtocol.setSidetone {
                self.knownSidetone = nil
                self.sidetoneLabel.stringValue = "Sidetone: state unknown — refresh to verify"
            }
            if command == SonosProtocol.setANC { self.knownNoiseMode = nil }
            self.invalidateChangedSetting(command)
            self.finishCommand()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse device: CBPeripheral) { sendNext() }

    func peripheral(_ device: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            if characteristic.uuid == CBUUID(string: SonosProtocol.setupWrite) {
                authenticationFailed("Authentication write failed: \(error.localizedDescription)")
                return
            }
            log("Write failed: \(error.localizedDescription)")
            status.stringValue = "Request failed: \(error.localizedDescription)"
            if pending == SonosProtocol.setSidetone { knownSidetone = nil }
            if pending == SonosProtocol.setANC { knownNoiseMode = nil }
            if let pending { invalidateChangedSetting(pending) }
            if let pending { extraSettings.failed(namespace: pendingNamespace, command: pending, message: error.localizedDescription) }
            finishCommand()
        }
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == CBUUID(string: "2A19") {
            guard error == nil, characteristic.value?.count == 1, let value = characteristic.value?.first, value <= 100 else {
                batteryLevel = nil; updateStatusItem(); return
            }
            if batteryLevel != value { log("Battery level: \(value)%") }
            batteryLevel = value
            extraSettings.setBattery(value)
            updateStatusItem()
            return
        }
        if let error { log("Read failed: \(error.localizedDescription)"); return }
        if characteristic.uuid == CBUUID(string: SonosProtocol.setupNotify), let data = characteristic.value {
            handleAuthentication(data)
            return
        }
        guard characteristic.uuid == CBUUID(string: SonosProtocol.controlNotify), let data = characteristic.value else { return }
        log("RX \(data.hex)")
        if let response = SonosProtocol.response(data), response.namespace == 0,
           response.command == 5, response.status == 0, let activity = response.payload.first {
            let name = [0: "Idle", 1: "Busy", 2: "Audio playback", 3: "Call", 4: "TV audio", 5: "USB audio", 6: "Analog audio"][Int(activity)] ?? "Unknown (\(activity))"
            log("Headphone activity: \(name).")
            extraSettings.setActivity(name)
            return
        }
        guard let response = SonosProtocol.response(data), response.namespace == pendingNamespace, response.command == pending else { return }
        timeout?.invalidate()
        if extraSettings.handle(response) { finishCommand(); return }
        guard response.status == 0 else {
            status.stringValue = "Headphones rejected command \(response.command): status \(response.status)."
            log(status.stringValue)
            if response.command == SonosProtocol.setSidetone, let knownSidetone { sidetone.state = knownSidetone ? .on : .off }
            if response.command == SonosProtocol.setANC, let knownNoiseMode { noiseMode.selectItem(at: Int(knownNoiseMode)) }
            if let knownLoudness { loudness.state = knownLoudness ? .on : .off }
            renderEQ()
            finishCommand(); return
        }
        if response.command == SonosProtocol.getSidetone {
            if response.payload.count == 1, response.payload[0] <= 1 {
                let enabled = response.payload[0] == 1
                knownSidetone = enabled
                sidetone.state = enabled ? .on : .off
                sidetoneLabel.stringValue = "Sidetone: \(enabled ? "on" : "off")"
                status.stringValue = "Connected. Sidetone read from the headphones."
                log("Sidetone readback: \(enabled ? "ON" : "OFF").")
            } else { knownSidetone = nil; log("Unexpected sidetone response length/value.") }
        } else if response.command == SonosProtocol.setSidetone {
            knownSidetone = nil
            log("Sidetone change acknowledged. Verifying readback.")
            queued.insert((2, SonosProtocol.getSidetone, []), at: 0)
        } else if response.command == SonosProtocol.getEQ {
            knownEQ = SonosProtocol.parseEQ(response.payload)
            renderEQ()
            if let eq = SonosProtocol.describeEQ(response.payload) { log(eq) }
            else { log("Unrecognised EQ payload; raw response retained above.") }
        } else if response.command == SonosProtocol.setEQType || response.command == SonosProtocol.setEQBand {
            knownEQ = nil
            log("EQ change acknowledged. Verifying readback.")
            queued.insert((2, SonosProtocol.getEQ, []), at: 0)
        } else if response.command == SonosProtocol.setANC {
            knownNoiseMode = nil
            log("Noise-control change acknowledged. Verifying readback.")
            queued.insert((2, SonosProtocol.getANC, []), at: 0)
        } else if response.command == SonosProtocol.getANC, response.payload.count == 1 {
            let modes = ["Off", "Noise cancelling", "Aware"]
            let value = Int(response.payload[0])
            if value < modes.count {
                knownNoiseMode = response.payload[0]
                noiseMode.selectItem(at: value)
            } else { knownNoiseMode = nil }
            log("ANC mode: \(value < modes.count ? modes[value] : "unknown (\(value))")")
        } else if response.command == SonosProtocol.getLoudness, response.payload.count == 1, response.payload[0] <= 1 {
            knownLoudness = response.payload[0] == 1
            loudness.state = knownLoudness! ? .on : .off
            log("Loudness: \(knownLoudness! ? "on" : "off")")
        } else if response.command == SonosProtocol.setLoudness {
            knownLoudness = nil
            log("Loudness change acknowledged. Verifying readback.")
            queued.insert((2, SonosProtocol.getLoudness, []), at: 0)
        }
        finishCommand()
    }

    private func finishCommand() {
        timeout?.invalidate(); timeout = nil; pending = nil; pendingPayload = []
        updateControlAvailability()
        sendNext()
    }

    private func invalidateChangedSetting(_ command: UInt8) {
        if command == SonosProtocol.setLoudness { knownLoudness = nil }
        if command == SonosProtocol.setEQType || command == SonosProtocol.setEQBand { knownEQ = nil }
    }

    private func updateControlAvailability() {
        callTest.isEnabled = ready || callAudio.isActive
        let idle = ready && pending == nil && queued.isEmpty
        extraSettings.setIdle(idle)
        refresh.isEnabled = idle
        sidetone.isEnabled = idle && knownSidetone != nil
        noiseMode.isEnabled = idle && knownNoiseMode != nil
        loudness.isEnabled = idle && knownLoudness != nil
        eqType.isEnabled = idle && knownEQ?.bands[0] != nil && knownEQ?.bands[1] != nil
        for (band, slider) in eqSliders.enumerated() {
            slider.isEnabled = idle && knownEQ.map { eq in
                guard eq.active <= 1, let values = eq.bands[eq.active], band < values.count else { return false }
                return (-10...10).contains(values[band])
            } == true
        }
    }

    private func renderEQ() {
        guard let eq = knownEQ, eq.active <= 1, let values = eq.bands[eq.active] else { return }
        eqType.selectItem(at: Int(eq.active))
        for band in 0..<8 {
            eqRows[band].isHidden = band >= values.count
            guard band < values.count else { continue }
            let name = eq.active == 0 && band < 3 ? ["Bass", "Mid", "Treble"][band] : "Band \(band + 1)"
            eqNames[band].stringValue = name
            eqSliders[band].setAccessibilityLabel(name)
            eqSliders[band].integerValue = values[band]
            eqValues[band].stringValue = String(values[band])
        }
    }

    @objc private func toggleCallAudio() {
        if callAudio.isActive { callAudio.stop(); return }
        guard ready, let name = extraSettings.headphoneName ?? peripheral?.name else { return }
        callAudio.start(headphoneName: name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.readActivity() }
    }

    @objc private func changeSidetone() {
        guard ready, pending == nil, knownSidetone != nil else { return }
        let enabled = sidetone.state == .on
        enqueue(SonosProtocol.setSidetone, payload: [enabled ? 1 : 0])
    }

    @objc private func changeNoiseMode() {
        guard ready, pending == nil, knownNoiseMode != nil, (0...2).contains(noiseMode.indexOfSelectedItem) else { return }
        enqueue(SonosProtocol.setANC, payload: [UInt8(noiseMode.indexOfSelectedItem)])
    }

    @objc private func changeLoudness() {
        guard ready, pending == nil, knownLoudness != nil else { return }
        enqueue(SonosProtocol.setLoudness, payload: [loudness.state == .on ? 1 : 0])
    }

    @objc private func changeEQType() {
        guard ready, pending == nil, let eq = knownEQ, (0...1).contains(eqType.indexOfSelectedItem) else { return }
        let type = UInt8(eqType.indexOfSelectedItem)
        guard eq.bands[type] != nil else { return }
        enqueue(SonosProtocol.setEQType, payload: [type])
    }

    @objc private func changeEQBand(_ sender: NSSlider) {
        guard ready, pending == nil, let eq = knownEQ, eq.active <= 1,
              let values = eq.bands[eq.active], values.indices.contains(sender.tag) else { return }
        let value = Int(sender.doubleValue.rounded())
        guard (-10...10).contains(value) else { return }
        sender.integerValue = value
        eqValues[sender.tag].stringValue = String(value)
        enqueue(SonosProtocol.setEQBand, payload: [eq.active, UInt8(sender.tag), UInt8(bitPattern: Int8(value))])
    }
}

if CommandLine.arguments.contains("--self-test") {
    let wear = AceSetting.all.first { $0.title == "Pause / resume when worn" }!
    precondition(wear.payload(value: 0, previous: [0x87]) == [0x85])
    precondition(wear.payload(value: 1, previous: [0x85]) == [0x87])
    precondition(wear.payload(value: 1, previous: []) == nil)
    let balance = AceSetting.all.first { $0.read == 33 && $0.namespace == 2 }!
    precondition(balance.payload(value: -1, previous: [0]) == [255])
    precondition(balance.payload(value: 21, previous: [0]) == nil)
    let sleep = AceSetting.all.first { $0.read == 41 }!
    precondition(sleep.payload(value: 2, previous: [1, 14]) == [2])
    precondition(sleep.valid([1]) == false)
    let name = AceSetting.all.first { $0.title == "Headphone name" }!
    precondition(name.valid([2, 0xC3, 0xA9]))
    precondition(!name.valid([1, 0xC3]))
    let prompt = AceSetting.all.first { $0.title == "Prompt volume mode" }!
    precondition(prompt.payload(value: 1, previous: [2, 42]) == [1, 42])
    precondition(SonosProtocol.response(Data([2, 2, 53])) == nil)
    let response = SonosProtocol.response(Data([2, 2, 53, 0, 1]))!
    precondition(response.command == 53 && response.status == 0 && response.payload == [1])
    precondition(SonosProtocol.describeEQ([0, 1, 0, 3, 0, 255, 2])?.contains("0, -1, 2") == true)
    precondition(SonosProtocol.describeEQ([0, 1, 0, 3, 0]) == nil)
    precondition(SonosProtocol.describeEQ([0, 0, 99]) == nil)
    precondition(SonosAuthentication.parse(Data([1, 3, 0, 0, 2, 0, 0]))?.status == 0)
    precondition(SonosAuthentication.parse(Data([1, 3, 0, 0, 2, 0])) == nil)
    precondition(SonosAuthentication.parse(Data([1, 3, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0])) == nil)
    precondition(SonosAuthentication.parse(Data([0, 1, 6, 255, 255, 0]), protocolID: 0) == nil)
    // Reject a truncated certificate sequence and a completion without any
    // challenge. Neither may advance the authentication state machine.
    do {
        _ = try SonosAttestation().receive(Data([0, 3, 5, 0, 1, 3, 7, 0, 1, 0]))
        preconditionFailure("An invalid certificate hash was accepted")
    } catch {}
    do {
        _ = try SonosAttestation().receive(Data([0, 7, 5, 0, 1, 3, 7, 0, 1, 0]))
        preconditionFailure("An unsolicited challenge completion was accepted")
    } catch {}
    print("Protocol parsing checks passed.")
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let controller = AceController()
    app.delegate = controller
    // NSApplication holds its delegate weakly.
    withExtendedLifetime(controller) { app.run() }
}
