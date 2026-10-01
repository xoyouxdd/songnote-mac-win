import AppKit

enum Theme {
    static let ink = NSColor(calibratedRed: 0.19, green: 0.21, blue: 0.20, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.47, green: 0.49, blue: 0.46, alpha: 1)
    static let paper = NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.96, alpha: 1)
    static let green = NSColor(calibratedRed: 0.27, green: 0.48, blue: 0.39, alpha: 1)
    static func button(_ button: NSButton, primary: Bool = false, active: Bool = false) {
        button.isBordered = false; button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = (primary ? ink : (active ? NSColor.white.withAlphaComponent(0.8) : NSColor.white.withAlphaComponent(0.35))).cgColor
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.imageHugsTitle = true
        button.contentTintColor = primary ? .white : ink
        if button.imagePosition == .imageOnly || (button.image != nil && button.title == "Button") {
            button.title = ""; button.imagePosition = .imageOnly
        }
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: button.font!, .foregroundColor: primary ? NSColor.white : ink])
    }
    static func symbol(_ name: String, size: CGFloat = 14) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }
    static func timestamp(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return "刚刚" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(date) { formatter.dateFormat = "今天 HH:mm" }
        else if Calendar.current.isDateInYesterday(date) { formatter.dateFormat = "昨天 HH:mm" }
        else { formatter.dateFormat = "M月d日 HH:mm" }
        return formatter.string(from: date)
    }
}

final class NoteCardView: NSView {
    var accent = Theme.ink
    var onOpen: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onOpen?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onOpen?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { layer?.borderColor = accent.withAlphaComponent(0.5).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.borderColor = accent.withAlphaComponent(0.14).cgColor }
}

final class NotesListView: NSView {
    override var isFlipped: Bool { true }
    func setCards(_ cards: [NoteCardView]) {
        for view in subviews { view.removeFromSuperview() }
        for card in cards { addSubview(card) }
        frame.size.height = CGFloat(cards.count) * 152
        needsLayout = true
    }
    override func layout() {
        super.layout()
        for (index, card) in subviews.enumerated() {
            card.frame = NSRect(x: 0, y: CGFloat(index) * 152, width: bounds.width, height: 140)
        }
    }
}

final class NotesScrollView: NSScrollView {
    override func layout() {
        super.layout()
        if let documentView, documentView.frame.width != contentSize.width {
            documentView.frame.size.width = contentSize.width
            documentView.needsLayout = true
        }
    }
}
