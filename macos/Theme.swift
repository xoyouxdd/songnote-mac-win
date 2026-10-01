import AppKit
import QuartzCore

@MainActor enum Theme {
    static let ink = NSColor(hex: 0x303633)
    static let muted = NSColor(hex: 0x596159)
    static let paper = NSColor(hex: 0xF6F5F0)
    static let green = NSColor(hex: 0x457A63)
    static let palette: [String: NSColor] = ["yellow": NSColor(hex: 0xFFF5C9), "green": NSColor(hex: 0xE0F0D6),
        "blue": NSColor(hex: 0xDBEBFA), "pink": NSColor(hex: 0xFAE0E8), "purple": NSColor(hex: 0xEDE0FA), "gray": NSColor(hex: 0xEDEDE8)]
    static let accents: [String: NSColor] = ["yellow": NSColor(hex: 0xE8B931), "green": NSColor(hex: 0x5BAE6E),
        "blue": NSColor(hex: 0x4A90D9), "pink": NSColor(hex: 0xE07597), "purple": NSColor(hex: 0x9B7BD8), "gray": NSColor(hex: 0x92928A)]
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var presentationFrames: [Int: NSRect] = [:]
    // primary: dark filled action. tint: selected state on paper (for example the pinned note).
    // Tool buttons stay transparent and only show a wash on hover; other buttons are soft outlined chips.
    static func button(_ button: NSButton, primary: Bool = false, tint: NSColor? = nil) {
        button.isBordered = false; button.wantsLayer = true; button.layer?.cornerRadius = 6
        let tool = button as? ToolButton
        let fill: NSColor = primary ? ink : (tint ?? (tool != nil ? .clear : NSColor.white.withAlphaComponent(0.7)))
        if let tool {
            tool.hoverColor = primary ? (ink.blended(withFraction: 0.15, of: .white) ?? ink) : (tint.flatMap { $0.blended(withFraction: 0.12, of: ink) } ?? ink.withAlphaComponent(0.09))
            tool.baseColor = fill
        } else {
            button.layer?.backgroundColor = fill.cgColor
            button.layer?.borderWidth = primary ? 0 : 1; button.layer?.borderColor = ink.withAlphaComponent(0.2).cgColor
        }
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.imageHugsTitle = true; button.contentTintColor = primary ? .white : ink
        if button.imagePosition == .imageOnly || (button.image != nil && button.title == "Button") {
            button.title = ""; button.imagePosition = .imageOnly
        }
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: button.font!, .foregroundColor: primary ? NSColor.white : ink])
    }
    static func iconButton(_ name: String, label: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = ToolButton(image: symbol(name)!, target: target, action: action)
        button.setAccessibilityLabel(label); button.toolTip = label; button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false; Theme.button(button)
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
    static func symbol(_ name: String, size: CGFloat = 14) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }
    static func dotImage(_ color: String) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            (accents[color] ?? ink).setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill(); return true
        }
    }
    static func animate(_ duration: TimeInterval = 0.18, changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : duration; context.allowsImplicitAnimation = !reduceMotion
            changes()
        }, completionHandler: completion)
    }
    static func background(_ layer: CALayer?, color: NSColor) {
        guard let layer else { return }
        let old = layer.backgroundColor
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.backgroundColor = color.cgColor; CATransaction.commit()
        if !reduceMotion, let old, old != color.cgColor {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = old; animation.toValue = color.cgColor; animation.duration = 0.18
            layer.add(animation, forKey: "color")
        }
    }
    static func spin(_ button: NSButton, active: Bool) {
        guard active, !reduceMotion else { button.layer?.removeAnimation(forKey: "sync-spin"); return }
        guard button.layer?.animation(forKey: "sync-spin") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0; animation.toValue = 2 * Double.pi; animation.duration = 1
        animation.repeatCount = .infinity; button.layer?.add(animation, forKey: "sync-spin")
    }
    static func pulse(_ view: NSView) {
        guard !reduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 0.35, 1]; animation.duration = 0.35; view.layer?.add(animation, forKey: "synced")
    }
    static func bounce(_ view: NSView) {
        guard !reduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1, 1.10, 0.97, 1]; animation.duration = 0.22; view.layer?.add(animation, forKey: "pin")
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
    static func restore(_ window: NSWindow, name: String, cascadeFrom: NSWindow? = nil) {
        let restored = window.setFrameUsingName(name)
        if !restored {
            if let previous = cascadeFrom { window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24)) }
            else { window.center() }
        }
        keepVisible(window); window.setFrameAutosaveName(name)
    }
    static func keepVisible(_ window: NSWindow) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let screen = screens.max(by: { a, b in
            let ia = a.intersection(window.frame), ib = b.intersection(window.frame)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }) else { return }
        var frame = window.frame; frame.size.width = min(frame.width, screen.width); frame.size.height = min(frame.height, screen.height)
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        window.setFrame(frame, display: false)
    }
    static func presentNew(_ window: NSWindow) {
        guard !reduceMotion else { window.makeKeyAndOrderFront(nil); return }
        let frame = window.frame
        presentationFrames[window.windowNumber] = frame
        window.alphaValue = 0; window.setFrame(frame.insetBy(dx: 6, dy: 6), display: false)
        window.makeKeyAndOrderFront(nil)
        animate(changes: { window.animator().alphaValue = 1; window.animator().setFrame(frame, display: true) }, completion: {
            presentationFrames.removeValue(forKey: window.windowNumber)
        })
    }
    static func finishPresentations() {
        for window in NSApp.windows {
            if let frame = presentationFrames[window.windowNumber] {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0; window.animator().alphaValue = 1; window.animator().setFrame(frame, display: true)
                })
            }
        }
        presentationFrames.removeAll()
    }
    static func titlebar(_ window: NSWindow, view: NSView, width: CGFloat, side: NSLayoutConstraint.Attribute) {
        let accessory = NSTitlebarAccessoryViewController()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 22)
        accessory.view = view; accessory.layoutAttribute = side; window.addTitlebarAccessoryViewController(accessory)
    }
    static func addColorPicker(to menu: NSMenu, id: String, selected: String, target: AnyObject, action: Selector) {
        let header = NSMenuItem(title: "便签颜色", action: nil, keyEquivalent: ""); header.isEnabled = false; menu.addItem(header)
        let swatches = NSMenuItem()
        swatches.view = ColorPickerView(selected: selected) { [weak menu] color in
            let sender = NSMenuItem(); sender.representedObject = ["id": id, "color": color]
            NSApp.sendAction(action, to: target, from: sender); menu?.cancelTracking()
        }
        menu.addItem(swatches)
        let names = NSMenuItem(title: "按名称选择颜色", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for color in colorOrder {
            let item = NSMenuItem(title: colorNames[color]!, action: action, keyEquivalent: "")
            item.image = dotImage(color); item.state = color == selected ? .on : .off
            item.target = target; item.representedObject = ["id": id, "color": color]; colors.addItem(item)
        }
        names.submenu = colors; menu.addItem(names)
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

final class ColorPickerView: NSView {
    let onPick: (String) -> Void
    init(selected: String, onPick: @escaping (String) -> Void) {
        self.onPick = onPick; super.init(frame: NSRect(x: 0, y: 0, width: 208, height: 34))
        for (index, color) in colorOrder.enumerated() {
            let button = NSButton(frame: NSRect(x: CGFloat(12 + index * 32), y: 5, width: 24, height: 24))
            button.tag = index; button.title = ""; button.isBordered = false; button.wantsLayer = true
            button.layer?.cornerRadius = 12; button.layer?.backgroundColor = Theme.accents[color]!.cgColor
            button.layer?.borderWidth = color == selected ? 2 : 0; button.layer?.borderColor = Theme.ink.cgColor
            button.image = color == selected ? Theme.symbol("checkmark", size: 11) : nil
            button.contentTintColor = Theme.ink; button.toolTip = colorNames[color]
            button.setAccessibilityLabel(colorNames[color]! + (color == selected ? "，已选中" : ""))
            button.target = self; button.action = #selector(pick(_:)); addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func pick(_ sender: NSButton) { onPick(colorOrder[sender.tag]) }
}

// Transparent titlebar/footer icon: a light wash on hover instead of a permanent white box.
final class ToolButton: NSButton {
    var baseColor: NSColor = .clear { didSet { paint() } }
    var hoverColor: NSColor = Theme.ink.withAlphaComponent(0.09)
    private var hovering = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; paint() }
    override func mouseExited(with event: NSEvent) { hovering = false; paint() }
    func paint() { layer?.backgroundColor = (hovering && isEnabled ? hoverColor : baseColor).cgColor }
}

// Some IMEs unmark without another textDidChange notification.
final class CommittedTextView: NSTextView {
    var onCommit: (() -> Void)?
    override func unmarkText() {
        super.unmarkText(); DispatchQueue.main.async { [weak self] in self?.onCommit?() }
    }
}

final class NoteCardView: NSView {
    let title = NSTextField(labelWithString: "")
    let preview = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")
    let stripe = NSView()
    var id = ""
    var accent = Theme.ink
    var paper = Theme.paper
    var selected = false { didSet { updateBorder() } }
    var hovered = false
    var pressed = false
    var interactive = true
    var onOpen: (() -> Void)?
    var onSelect: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var contextMenu: (() -> NSMenu)?
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.cornerRadius = 8; layer?.borderWidth = 1; layer?.masksToBounds = true; stripe.wantsLayer = true
        title.font = .systemFont(ofSize: 15, weight: .semibold); title.textColor = Theme.ink
        preview.font = .systemFont(ofSize: 13); preview.textColor = Theme.muted
        hint.font = .systemFont(ofSize: 11); hint.textColor = Theme.muted
        for label in [title, preview, hint] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
            label.cell?.wraps = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [stripe, title, preview, hint] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor), stripe.widthAnchor.constraint(equalToConstant: 4), stripe.topAnchor.constraint(equalTo: topAnchor), stripe.bottomAnchor.constraint(equalTo: bottomAnchor),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 9), title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            title.heightAnchor.constraint(equalToConstant: 20),
            preview.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3), preview.leadingAnchor.constraint(equalTo: title.leadingAnchor), preview.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            preview.heightAnchor.constraint(equalToConstant: 18),
            hint.heightAnchor.constraint(equalToConstant: 16),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8), hint.leadingAnchor.constraint(equalTo: title.leadingAnchor), hint.trailingAnchor.constraint(equalTo: title.trailingAnchor)])
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityHelp("打开便签；方向键移动，回车打开，右键管理")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ note: Note, pending: Bool, deleteConflict: Bool, query: String = "") {
        id = note.id; paper = Theme.palette[note.color] ?? Theme.palette["yellow"]!; accent = Theme.accents[note.color] ?? Theme.ink
        Theme.background(layer, color: hovered ? paper.blended(withFraction: 0.14, of: .white)! : paper)
        stripe.layer?.backgroundColor = accent.cgColor; updateBorder()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        showMatch(title, String(note.title.prefix(90)), query: trimmed, font: .systemFont(ofSize: 15, weight: .semibold), color: Theme.ink)
        showMatch(preview, String(note.preview.prefix(130)), query: trimmed, font: .systemFont(ofSize: 13), color: Theme.muted)
        hint.stringValue = (deleteConflict ? "删除未执行 · " : "") + (note.conflict_of != nil ? "冲突副本 · " : (note.pinned ? "置顶 · " : "")) + Theme.timestamp(note.updated_at) + (pending ? " · 待同步" : "")
        hint.toolTip = hint.stringValue; setAccessibilityLabel(String(note.title.prefix(90)) + "，" + hint.stringValue)
    }
    func showMatch(_ label: NSTextField, _ text: String, query: String, font: NSFont, color: NSColor) {
        guard !query.isEmpty else { label.stringValue = text; return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let styled = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let ns = text as NSString
        let hit = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let wash = NSColor(hex: 0xE8B931).withAlphaComponent(0.45)
        var span = NSRange(location: 0, length: ns.length)
        while span.length > 0 {
            let found = ns.range(of: query, options: .caseInsensitive, range: span)
            if found.location == NSNotFound || found.length == 0 { break }
            styled.addAttributes([.font: hit, .backgroundColor: wash], range: found)
            let next = found.location + found.length
            span = NSRange(location: next, length: ns.length - next)
        }
        label.attributedStringValue = styled
    }
    func updateBorder() {
        layer?.borderWidth = selected ? 1.5 : 1
        let selectedColor = accent.blended(withFraction: 0.5, of: Theme.ink) ?? Theme.ink
        layer?.borderColor = (selected ? selectedColor : accent.withAlphaComponent(hovered ? 0.6 : 0.25)).cgColor
    }
    override func becomeFirstResponder() -> Bool { onSelect?(); return true }
    override func mouseDown(with event: NSEvent) { guard interactive else { return }; pressed = true; window?.makeFirstResponder(self) }
    override func mouseUp(with event: NSEvent) {
        let activate = interactive && pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false; if activate { onOpen?() }
    }
    override func keyDown(with event: NSEvent) {
        guard interactive else { return }
        switch event.keyCode {
        case 36, 49: onOpen?()
        case 123: onMove?(-1)
        case 124: onMove?(1)
        case 125: onMove?((superview as? NotesListView)?.columns ?? 1)
        case 126: onMove?(-((superview as? NotesListView)?.columns ?? 1))
        default: super.keyDown(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? { guard interactive else { return nil }; pressed = false; window?.makeFirstResponder(self); return contextMenu?() }
    override func accessibilityPerformPress() -> Bool { guard interactive else { return false }; onOpen?(); return true }
    override func hitTest(_ point: NSPoint) -> NSView? { interactive && bounds.contains(convert(point, from: superview)) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateBorder(); Theme.background(layer, color: paper.blended(withFraction: 0.14, of: .white)!) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateBorder(); Theme.background(layer, color: paper) }
}

final class NotesListView: NSView {
    static let cardHeight: CGFloat = 84
    static let gap: CGFloat = 8
    var cards: [NoteCardView] = []
    var animateNextLayout = false
    var columns: Int { bounds.width >= 620 ? 2 : 1 }
    override var isFlipped: Bool { true }
    func setCards(_ next: [NoteCardView], animated: Bool = true) {
        let removed = cards.filter { card in !next.contains(where: { $0 === card }) }; cards = next
        for card in removed {
            card.interactive = false; card.setAccessibilityElement(false)
            if animated && !Theme.reduceMotion {
                Theme.animate(0.14, changes: { card.animator().alphaValue = 0 }, completion: { [weak self, weak card] in
                    guard let self, let card, !self.cards.contains(where: { $0 === card }) else { return }; card.removeFromSuperview()
                })
            } else { card.removeFromSuperview() }
        }
        for card in next {
            card.interactive = true; card.setAccessibilityElement(true)
            if card.superview == nil { card.alphaValue = animated && !Theme.reduceMotion ? 0 : 1; addSubview(card) }
        }
        animateNextLayout = animated; needsLayout = true
    }
    override func layout() {
        super.layout()
        let count = (cards.count + columns - 1) / columns
        let height = max(0, CGFloat(count) * (Self.cardHeight + Self.gap) - Self.gap)
        if frame.height != height { frame.size.height = height }
        let width = (bounds.width - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)
        let animated = animateNextLayout && !Theme.reduceMotion; animateNextLayout = false
        for (index, card) in cards.enumerated() {
            let target = NSRect(x: CGFloat(index % columns) * (width + Self.gap), y: CGFloat(index / columns) * (Self.cardHeight + Self.gap), width: width, height: Self.cardHeight)
            if animated {
                if card.frame.isEmpty { card.frame = target }
                Theme.animate(changes: { card.animator().frame = target; card.animator().alphaValue = 1 })
            } else { card.frame = target; card.alphaValue = 1 }
        }
    }
}

final class NotesScrollView: NSScrollView {
    override func layout() {
        super.layout()
        if let documentView, documentView.frame.width != contentSize.width {
            documentView.frame.size.width = contentSize.width; documentView.needsLayout = true
        }
    }
}
