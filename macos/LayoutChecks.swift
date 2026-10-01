import AppKit

// Read-only native geometry checks: use the real window builders, do not present
// windows, save window positions, edit notes, or issue network requests.
@MainActor enum LayoutChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }
    static func checkControls(_ view: NSView) throws {
        if view is NSScrollView { return }
        for child in view.subviews {
            if child is NSButton || child is NSTextField || child is NSImageView {
                // Native text fields extend their paint frame by two pixels for
                // optical alignment. Check the same alignment rect Auto Layout uses.
                let frame = child.alignmentRect(forFrame: child.frame)
                try require(frame.minX >= -1 && frame.minY >= -1 && frame.maxX <= view.bounds.width + 1 && frame.maxY <= view.bounds.height + 1,
                            "\(type(of: child)) overflows \(type(of: view)): \(frame), parent \(view.bounds)")
                if let button = child as? NSButton { try require(button.title != "Button", "Default button label still visible") }
            }
            try checkControls(child)
        }
    }
    static func run() throws {
        let delegate = AppDelegate(); delegate.checkingLayout = true; delegate.store = try Store()
        delegate.buildList(); delegate.refresh()
        var cases = 0
        for size in [NSSize(width: 400, height: 420), NSSize(width: 430, height: 660), NSSize(width: 720, height: 760)] {
            delegate.window.setContentSize(size)
            delegate.window.contentView!.layoutSubtreeIfNeeded()
            delegate.list.enclosingScrollView!.layoutSubtreeIfNeeded()
            delegate.list.layoutSubtreeIfNeeded()
            try checkControls(delegate.window.contentView!)
            let available = delegate.list.enclosingScrollView!.contentSize.width
            for card in delegate.list.subviews {
                try require(abs(card.frame.width - available) < 1, "List card clipped: \(card.frame.width), available \(available)")
                try checkControls(card)
            }
            cases += 1
        }
        let note = delegate.store.visible.first ?? Note.blank()
        let editor = NoteWindow(note: note, store: delegate.store, present: false)
        for size in [NSSize(width: 360, height: 280), NSSize(width: 380, height: 420), NSSize(width: 640, height: 640)] {
            editor.window.setContentSize(size)
            editor.window.contentView!.layoutSubtreeIfNeeded()
            try checkControls(editor.window.contentView!)
            let root = editor.window.contentView!
            let button = editor.syncButton.convert(editor.syncButton.bounds, to: root)
            try require(abs(root.bounds.maxX - button.maxX - 12) < 1, "Sync button is not right aligned")
            try require(editor.editor.enclosingScrollView!.frame.height > 60, "Editor is squeezed by controls")
            cases += 1
        }
        print("LAYOUT_CHECK_OK: \(cases) native window sizes, controls contained, complete cards, right-aligned sync, no default labels")
    }
}
