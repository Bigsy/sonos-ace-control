import AppKit

/// Menu actions keep their closures alive for exactly as long as the menu item.
final class ActionMenuItem: NSMenuItem {
    private let perform: () -> Void
    init(_ title: String, enabled: Bool = true, checked: Bool = false, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func invoke() { perform() }
}

final class MenuSliderView: NSView {
    private let slider: NSSlider
    private let commit: (Int) -> Void
    init(title: String, value: Int, range: ClosedRange<Int>, enabled: Bool, commit: @escaping (Int) -> Void) {
        self.commit = commit
        slider = NSSlider(value: Double(value), minValue: Double(range.lowerBound), maxValue: Double(range.upperBound), target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 265, height: 48))
        let label = NSTextField(labelWithString: "\(title)   \(value)")
        label.font = .menuFont(ofSize: 12)
        label.frame = NSRect(x: 18, y: 27, width: 230, height: 17)
        addSubview(label)
        slider.frame = NSRect(x: 18, y: 4, width: 230, height: 23)
        slider.isContinuous = false
        slider.isEnabled = enabled
        slider.setAccessibilityLabel(title)
        slider.target = self; slider.action = #selector(changed)
        addSubview(slider)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func changed() {
        // Close before writing; reopening always shows verified headphone state.
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        commit(Int(slider.doubleValue.rounded()))
    }
}

enum HeadphoneStatusImage {
    static func make(battery: UInt8?) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            NSColor.black.set()
            let band = NSBezierPath()
            band.lineWidth = 1.6
            band.lineCapStyle = .round
            band.move(to: NSPoint(x: 3, y: 9))
            band.curve(to: NSPoint(x: 19, y: 9), controlPoint1: NSPoint(x: 3, y: 24), controlPoint2: NSPoint(x: 19, y: 24))
            band.stroke()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 3, height: 10), xRadius: 2, yRadius: 2).fill()
            NSBezierPath(roundedRect: NSRect(x: 18, y: 3, width: 3, height: 10), xRadius: 2, yRadius: 2).fill()
            let text = battery.map { $0 == 100 ? "F" : "\($0)" } ?? "—"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold), .foregroundColor: NSColor.black]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: (22 - size.width) / 2, y: 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}
