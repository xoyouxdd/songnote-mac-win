import AppKit

// Side-by-side view of a conflict copy and its original, with one-click resolution.
// The discarded version goes to 最近删除, so every choice can be undone for 7 days.
@MainActor final class CompareWindow: NSObject, NSWindowDelegate {
    let store: Store
    let copyID: String
    let window: NSWindow
    var onClose: (() -> Void)?
    var onOpenOriginal: (() -> Void)?
    let originalText = NSTextView()
    let copyText = NSTextView()
    init(store: Store, copyID: String) {
        self.store = store; self.copyID = copyID
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "对比冲突内容"; window.delegate = self; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 300); window.backgroundColor = Theme.paper
        window.appearance = NSAppearance(named: .aqua)
        let copy = store.state.notes[copyID]!, original = store.state.notes[copy.conflict_of!]!
        let left = column("原便签 · " + Theme.timestamp(original.updated_at), text: original.text, color: original.color, view: originalText)
        let right = column("冲突副本 · " + Theme.timestamp(copy.updated_at), text: copy.text, color: copy.color, view: copyText)
        let columns = NSStackView(views: [left, right]); columns.distribution = .fillEqually; columns.spacing = 12
        let hint = NSTextField(labelWithString: "另一台电脑同时改了这条便签。选择要保留的内容，另一份会移到「最近删除」，7 天内可恢复。")
        hint.font = .systemFont(ofSize: 12); hint.textColor = Theme.muted; hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keepOriginal = NSButton(title: "保留原便签", target: self, action: #selector(chooseOriginal))
        let keepCopy = NSButton(title: "保留副本内容", target: self, action: #selector(chooseCopy))
        let both = NSButton(title: "两份都保留", target: self, action: #selector(keepBoth))
        let open = NSButton(title: "打开原便签", target: self, action: #selector(openOriginal))
        for button in [keepOriginal, keepCopy, both, open] { Theme.button(button); Theme.padded(button, height: 28) }
        keepOriginal.setAccessibilityHelp("删除冲突副本，原便签保持不变")
        keepCopy.setAccessibilityHelp("把副本内容写回原便签，然后删除副本")
        let actions = NSStackView(views: [open, NSView(), both, keepOriginal, keepCopy]); actions.spacing = 8
        let root = NSStackView(views: [hint, columns, actions]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [columns, actions] { view.translatesAutoresizingMaskIntoConstraints = false }
        window.contentView = root
        NSLayoutConstraint.activate([
            columns.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32), actions.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            hint.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32)])
        window.center()
    }
    func column(_ title: String, text: String, color: String, view: NSTextView) -> NSView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = Theme.ink
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = true
        scroll.backgroundColor = Theme.palette[color] ?? Theme.palette["yellow"]!; scroll.wantsLayer = true; scroll.layer?.cornerRadius = 8
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false; view.string = text
        view.font = NoteWindow.bodyFont; view.textColor = Theme.ink; view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        let stack = NSStackView(views: [label, scroll]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
    @objc func chooseOriginal() { store.keepOriginal(copyID); window.close() }
    @objc func chooseCopy() { store.keepConflictCopy(copyID); window.close() }
    @objc func keepBoth() { window.close() }
    @objc func openOriginal() { onOpenOriginal?() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
