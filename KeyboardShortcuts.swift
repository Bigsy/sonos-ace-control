import AppKit
import Carbon

private struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyName: String

    var description: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }
}

final class KeyboardShortcuts: NSObject {
    private struct Entry {
        let id: String
        let title: String
        let perform: () -> Void
    }

    private let defaultsKey = "AceControl.keyboardShortcuts.v1"
    private var entries: [Entry] = []
    private var selected = Set<String>()
    private var bindings: [String: ShortcutBinding] = [:]
    private var global = true
    private var checkboxes: [String: NSButton] = [:]
    private var registered: [String: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var monitor: Any?
    private var recording: String?
    private var issues: [String: String] = [:]
    private let rows = NSStackView()
    private let prompt = NSTextField(wrappingLabelWithString: "Tick a control to add it here.")
    private let scope = NSButton(checkboxWithTitle: "Shortcuts work anywhere on this Mac", target: nil, action: nil)

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            selected = Set(saved.selected)
            bindings = saved.bindings
            global = saved.global
        }
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        prompt.textColor = .secondaryLabelColor
        scope.state = global ? .on : .off
        scope.target = self
        scope.action = #selector(scopeChanged)
    }

    private struct Saved: Codable {
        var selected: [String]
        var bindings: [String: ShortcutBinding]
        var global: Bool
    }

    func add(_ id: String, title: String, perform: @escaping () -> Void) {
        guard !entries.contains(where: { $0.id == id }) else { return }
        entries.append(Entry(id: id, title: title, perform: perform))
    }

    func checkbox(for id: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Shortcut", target: self, action: #selector(selectionChanged(_:)))
        button.tag = entries.firstIndex(where: { $0.id == id }) ?? -1
        button.state = selected.contains(id) ? .on : .off
        button.setAccessibilityLabel("Add \(entries.first(where: { $0.id == id })?.title ?? id) to keyboard shortcuts")
        checkboxes[id] = button
        return button
    }

    func addTab(to tabs: NSTabView) {
        let note = NSTextField(wrappingLabelWithString:
            "Tick Shortcut beside a switch or Noise control. Record a combination for each selected control. Use ⌘, ⌥, ⌃ or a function key so normal typing still works.")
        note.textColor = .secondaryLabelColor
        let tab = NSTabViewItem(identifier: "Shortcuts")
        tab.label = "Shortcuts"
        tab.view = ExtraSettings.scroll([note, scope, prompt, rows])
        tabs.addTabViewItem(tab)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let id = self.recording {
                self.capture(event, for: id)
                return nil
            }
            guard !self.global else { return event }
            guard let binding = Self.binding(from: event) else { return event }
            if let entry = self.entries.first(where: { self.selected.contains($0.id) && self.bindings[$0.id].map { Self.sameKeys($0, binding) } == true }) {
                entry.perform()
                return nil
            }
            return event
        }
        installHandler()
        registerKeys()
        render()
    }

    func stop() {
        unregisterKeys()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func save() {
        let saved = Saved(selected: selected.sorted(), bindings: bindings, global: global)
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    @objc private func selectionChanged(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let id = entries[sender.tag].id
        if sender.state == .on { selected.insert(id) }
        else { selected.remove(id); if recording == id { recording = nil } }
        if !selected.isEmpty { prompt.stringValue = "Click Record shortcut to assign a key combination." }
        save(); registerKeys(); render()
    }

    @objc private func scopeChanged() {
        global = scope.state == .on
        save(); registerKeys(); render()
    }

    @objc private func record(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        recording = entries[sender.tag].id
        unregisterKeys()
        prompt.stringValue = "Press ⌘, ⌥ or ⌃ with a key, or a function key, for \(entries[sender.tag].title). Escape cancels."
        render()
    }

    @objc private func remove(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let id = entries[sender.tag].id
        selected.remove(id)
        bindings.removeValue(forKey: id)
        checkboxes[id]?.state = .off
        if recording == id { recording = nil }
        if !selected.isEmpty { prompt.stringValue = "Click Record shortcut to assign a key combination." }
        save(); registerKeys(); render()
    }

    private func capture(_ event: NSEvent, for id: String) {
        if event.keyCode == 53 { // Escape
            recording = nil
            prompt.stringValue = "Recording cancelled."
            registerKeys(); render()
            return
        }
        guard let binding = Self.binding(from: event) else {
            prompt.stringValue = "Use ⌘, ⌥ or ⌃ with a key, or press a function key."
            return
        }
        if binding.modifiers == UInt32(cmdKey) && ["Q", "W", "H", "M"].contains(binding.keyName) {
            prompt.stringValue = "That Mac shortcut is reserved for app controls. Choose another."
            return
        }
        if let duplicate = entries.first(where: { $0.id != id && selected.contains($0.id) && bindings[$0.id].map { Self.sameKeys($0, binding) } == true }) {
            prompt.stringValue = "\(binding.description) is already assigned to \(duplicate.title)."
            return
        }
        bindings[id] = binding
        recording = nil
        save(); registerKeys(); render()
        prompt.stringValue = issues[id] ?? "Saved \(binding.description) for \(entries.first(where: { $0.id == id })?.title ?? id)."
    }

    private static func binding(from event: NSEvent) -> ShortcutBinding? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let keyName: String
        switch event.keyCode {
        case 36: keyName = "Return"
        case 48: keyName = "Tab"
        case 49: keyName = "Space"
        case 51: keyName = "Delete"
        case 53: return nil
        case 123: keyName = "←"
        case 124: keyName = "→"
        case 125: keyName = "↓"
        case 126: keyName = "↑"
        case 122: keyName = "F1"
        case 120: keyName = "F2"
        case 99: keyName = "F3"
        case 118: keyName = "F4"
        case 96: keyName = "F5"
        case 97: keyName = "F6"
        case 98: keyName = "F7"
        case 100: keyName = "F8"
        case 101: keyName = "F9"
        case 109: keyName = "F10"
        case 103: keyName = "F11"
        case 111: keyName = "F12"
        default:
            guard let character = event.charactersIgnoringModifiers?.uppercased(),
                  character.count == 1, character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            keyName = character
        }
        guard modifiers & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) != 0 ||
              keyName.first == "F" && Int(keyName.dropFirst()) != nil else { return nil }
        return ShortcutBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyName: keyName)
    }

    private static func sameKeys(_ left: ShortcutBinding, _ right: ShortcutBinding) -> Bool {
        left.keyCode == right.keyCode && left.modifiers == right.modifiers
    }

    private func render() {
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        let included = entries.enumerated().filter { selected.contains($0.element.id) }
        if included.isEmpty { prompt.stringValue = "Tick a control to add it here." }
        for (index, entry) in included {
            let name = NSTextField(labelWithString: entry.title)
            name.widthAnchor.constraint(equalToConstant: 245).isActive = true
            let button = NSButton(title: recording == entry.id ? "Press keys…" : (bindings[entry.id]?.description ?? "Record shortcut"), target: self, action: #selector(record(_:)))
            button.tag = index
            button.widthAnchor.constraint(equalToConstant: 155).isActive = true
            let remove = NSButton(title: "Remove", target: self, action: #selector(remove(_:)))
            remove.tag = index
            let row = NSStackView(views: [name, button, remove])
            row.orientation = .horizontal
            row.spacing = 12
            rows.addArrangedSubview(row)
            if let issue = issues[entry.id] {
                let label = NSTextField(labelWithString: issue)
                label.textColor = .systemOrange
                rows.addArrangedSubview(label)
            }
        }
    }

    private func installHandler() {
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let manager = Unmanaged<KeyboardShortcuts>.fromOpaque(userData).takeUnretainedValue()
            manager.trigger(id.id)
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &kind,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func trigger(_ number: UInt32) {
        let index = Int(number) - 1
        guard entries.indices.contains(index), selected.contains(entries[index].id) else { return }
        entries[index].perform()
    }

    private func unregisterKeys() {
        for reference in registered.values { UnregisterEventHotKey(reference) }
        registered.removeAll()
        issues.removeAll()
    }

    private func registerKeys() {
        unregisterKeys()
        guard global, recording == nil else { return }
        for (index, entry) in entries.enumerated() where selected.contains(entry.id) {
            guard let binding = bindings[entry.id] else { continue }
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x41434543, id: UInt32(index + 1))
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id,
                                             GetEventDispatcherTarget(), 0, &reference)
            if status == noErr, let reference { registered[entry.id] = reference }
            else { issues[entry.id] = "\(binding.description) is unavailable in macOS. Record another combination." }
        }
    }
}
