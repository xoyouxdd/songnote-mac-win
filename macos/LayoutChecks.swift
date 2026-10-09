import AppKit

// Build native windows from synthetic in-memory notes. No private configuration,
// disk persistence, displayed windows, login-item registration, or network calls.
@MainActor enum LayoutChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func checkControls(_ view: NSView) throws {
        if view is NSScrollView { return }
        for child in view.subviews where !child.isHidden {
            if child is NSButton || child is NSTextField || child is NSImageView {
                let frame = child.alignmentRect(forFrame: child.frame)
                try require(frame.minX >= -1 && frame.minY >= -1 && frame.maxX <= view.bounds.width + 1 && frame.maxY <= view.bounds.height + 1,
                            "\(type(of: child)) overflows \(type(of: view)): \(frame), parent \(view.bounds)")
                if let button = child as? NSButton { try require(button.title != "Button", "Default button label still visible") }
                if let field = child as? NSTextField, let font = field.font { try require(font.pointSize >= 11, "Text below 11pt") }
            }
            try checkControls(child)
        }
    }
    static func fixture() -> LocalState {
        var state = LocalState()
        for index in 0..<7 {
            var note = Note.blank()
            let newline = ["\r\n", "\n", "\r", "\u{2028}"][index % 4]
            let title = "布局便签 \(index + 1) 中文 📝 " + String(repeating: "很长的标题", count: 30)
            note.text = (index == 1 ? "  \(newline)\(newline)" : "") + title + newline + newline + String(repeating: "正文预览 长段落 📝 ", count: 80) + newline + "最后一段"
            note.color = colorOrder[index % colorOrder.count]; note.pinned = index < 2
            note.updated_at = "2026-10-01T02:00:00Z"
            if index == 5 { note.conflict_of = "missing-original" }
            if index == 6 { state.deleteConflictIDs = [note.id] }
            state.notes[note.id] = note
        }
        return state
    }
    static func checkTitlebar(_ window: NSWindow) throws {
        for accessory in window.titlebarAccessoryViewControllers {
            accessory.view.layoutSubtreeIfNeeded(); try checkControls(accessory.view)
        }
    }
    static func run() throws {
        let delegate = AppDelegate(); delegate.checkingLayout = true; delegate.store = Store(previewState: fixture())
        delegate.buildList(); delegate.refresh()
        var cases = 0
        for size in [NSSize(width: 360, height: 360), NSSize(width: 460, height: 710), NSSize(width: 650, height: 710), NSSize(width: 680, height: 710), NSSize(width: 720, height: 760)] {
            delegate.window.setContentSize(size); delegate.window.contentView!.layoutSubtreeIfNeeded()
            let scroll = delegate.list.enclosingScrollView!; scroll.layoutSubtreeIfNeeded()
            delegate.list.layoutSubtreeIfNeeded()
            try checkControls(delegate.window.contentView!); try checkTitlebar(delegate.window)
            let list = delegate.list
            let width = (scroll.contentSize.width - CGFloat(list.columns - 1) * NotesListView.gap) / CGFloat(list.columns)
            try require(list.cards.count == 7, "Synthetic cards not covered")
            for (index, card) in list.cards.enumerated() {
                card.layoutSubtreeIfNeeded()
                try require(abs(card.frame.width - width) < 1, "Card width does not match column")
                try require(card.frame.minX >= 0 && card.frame.maxX <= scroll.contentSize.width + 1, "Card clipped horizontally")
                try require(card.frame.maxY <= list.bounds.height + 1, "Last card cannot scroll into view")
                try require(card.frame.height == NotesListView.cardHeight, "Card height changed unexpectedly")
                for earlier in list.cards.prefix(index) { try require(!card.frame.intersects(earlier.frame), "Cards overlap") }
                for header in list.headers.values { try require(!card.frame.intersects(header.frame), "Section header overlaps a row") }
                try checkControls(card)
                let lines = [card.title, card.preview, card.hint]
                let title = card.title.alignmentRect(forFrame: card.title.frame), preview = card.preview.alignmentRect(forFrame: card.preview.frame)
                let hint = card.hint.alignmentRect(forFrame: card.hint.frame)
                try require((card.isFlipped ? preview.minY - title.maxY : title.minY - preview.maxY) >= 2, "Title and preview overlap")
                try require(hint.minX - title.maxX >= 6 && hint.width > 20, "Title runs into the timestamp")
                for field in lines {
                    try require(field.maximumNumberOfLines == 1 && field.cell?.usesSingleLineMode == true, "Card label can wrap")
                    try require(field.stringValue.components(separatedBy: .newlines).count == 1, "Newline leaked into card label")
                }
                try require(!card.preview.stringValue.isEmpty, "Long multiline note lost its preview")
            }
            try require(Set(list.headers.keys) == ["已固定", "更早"], "Pinned and dated sections missing")
            if size.width == 460 { try require(scroll.contentSize.height >= 9 * (NotesListView.cardHeight + NotesListView.rowGap), "Default window cannot show nine rows") }
            if size.width == 720 { try require(list.columns == 2, "Wide window did not switch to two columns") }
            cases += 1
        }
        let original = delegate.store.visible.first!
        let editor = NoteWindow(note: original, store: delegate.store, present: false)
        for mode in 0..<4 {
            var note = original
            delegate.store.state.deleteConflictIDs = nil; delegate.store.lastSaved = mode != 1
            delegate.store.saveError = mode == 1 ? "只读文件系统：无法写入本地便签" : nil
            note.conflict_of = mode == 2 ? "missing-original" : nil
            if mode == 3 { delegate.store.state.deleteConflictIDs = [note.id] }
            delegate.store.state.notes[note.id] = note; editor.refresh()
            for size in [NSSize(width: 280, height: 240), NSSize(width: 380, height: 420), NSSize(width: 640, height: 640)] {
                editor.window.setContentSize(size); editor.window.contentView!.layoutSubtreeIfNeeded()
                let root = editor.window.contentView!
                try checkControls(root); try checkTitlebar(editor.window)
                if !editor.syncButton.isHidden {
                    let button = editor.syncButton.convert(editor.syncButton.bounds, to: root)
                    try require(abs(root.bounds.maxX - button.maxX - 12) < 1, "Sync button is not right aligned")
                }
                try require(editor.editor.enclosingScrollView!.frame.height >= size.height * 0.6, "Editor is squeezed by controls")
                if mode == 1 { try require(editor.statusLabel.stringValue.contains("保存失败"), "Save failure hidden by sync status") }
                if mode >= 2 { try require(!editor.banner.isHidden, "Persistent conflict notice hidden") }
                // Always-on-top shows a tinted pin, never the solid ink block that read as a stuck button.
                editor.window.level = mode == 0 ? .floating : .normal; editor.refresh()
                let tinted = (editor.pinButton as? ToolButton).map { $0.baseColor != Theme.ink && $0.baseColor != .clear } == true
                try require(tinted == (mode == 0), "Always-on-top state should be a colour tint only while floating")
                cases += 1
            }
        }
        var withFiles = original; withFiles.conflict_of = nil
        withFiles.attachments = (0..<8).map { Attachment(id: UUID().uuidString, name: "很长的虚构附件名称检查窄窗-\($0).pdf", size: 1024, sha256: String(repeating: "a", count: 64)) }
        delegate.store.state.deleteConflictIDs = nil; delegate.store.lastSaved = true
        delegate.store.state.notes[original.id] = withFiles
        editor.refresh()
        for size in [NSSize(width: 280, height: 240), NSSize(width: 380, height: 420), NSSize(width: 640, height: 640)] {
            editor.window.setContentSize(size); editor.window.contentView!.layoutSubtreeIfNeeded()
            let strip = editor.attachments; strip.layoutSubtreeIfNeeded()
            try checkControls(editor.window.contentView!)
            try require(!strip.isHidden && strip.frame.height == 24, "Attachment chips missing or unbounded")
            try require(editor.editor.enclosingScrollView!.frame.height >= 60, "Attachment chips squeeze the editor")
            let shown = strip.chips.filter { !$0.isHidden }
            try require(!shown.isEmpty && shown.count < 8 && !strip.overflow.isHidden, "Overflowing chips are not collapsed into +N")
            try require(strip.overflow.title == "+\(8 - shown.count)", "Overflow count is wrong")
            for chip in shown + [strip.overflow] {
                try require(chip.frame.minX >= 0 && chip.frame.maxX <= strip.bounds.width + 1, "Attachment chip clipped horizontally")
                for other in shown + [strip.overflow] where other !== chip { try require(!chip.frame.intersects(other.frame), "Attachment chips overlap") }
            }
            cases += 1
        }
        // The first non-empty line is displayed as the title without changing the saved plain text.
        let storage = editor.editor.textStorage!
        let titleAt = (storage.string as NSString).range(of: "布局便签").location
        let font = storage.attribute(.font, at: titleAt, effectiveRange: nil) as? NSFont
        try require(font?.pointSize == NoteWindow.titleFont.pointSize, "First line is not styled as the title")
        let body = (storage.string as NSString).range(of: "正文预览")
        try require((storage.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont)?.pointSize == NoteWindow.bodyFont.pointSize, "Body text styled as the title")
        try require(editor.editor.string == withFiles.text, "Display styling changed the note text")
        // Undo offer and 最近删除 fit the narrowest list footer.
        let victim = delegate.store.visible.last!
        delegate.store.state.notes[victim.id]?.deleted = true; delegate.store.lastDeleted = (victim.id, Date())
        delegate.window.setContentSize(NSSize(width: 360, height: 360)); delegate.refresh(forceOrder: true); delegate.window.contentView!.layoutSubtreeIfNeeded()
        try require(!delegate.undoButton.isHidden && delegate.status.stringValue.hasPrefix("已删除"), "Undo offer missing after delete")
        try checkControls(delegate.window.contentView!); cases += 1
        delegate.store.lastDeleted = nil; delegate.store.state.notes[victim.id]?.deleted = false
        // Conflict comparison: both texts side by side at default and minimum sizes.
        var copy = original; copy.id = "compare-copy-check"; copy.conflict_of = original.id; copy.text = "冲突副本的虚构内容"
        delegate.store.state.notes[copy.id] = copy; delegate.store.state.notes[original.id]?.deleted = false
        let compare = CompareWindow(store: delegate.store, copyID: copy.id)
        for size in [NSSize(width: 680, height: 440), NSSize(width: 480, height: 300)] {
            compare.window.setContentSize(size); compare.window.contentView!.layoutSubtreeIfNeeded()
            try checkControls(compare.window.contentView!)
            try require(compare.copyText.string == copy.text && compare.originalText.string == delegate.store.state.notes[original.id]!.text, "Comparison shows the wrong texts")
            try require(compare.originalText.enclosingScrollView!.frame.height >= 120, "Comparison texts squeezed")
            cases += 1
        }
        delegate.store.state.notes.removeValue(forKey: copy.id)
        // An idle delta poll changes nothing, so nothing is written or refreshed.
        let store = Store(previewState: delegate.store.state)
        try? FileManager.default.removeItem(at: store.file)
        let idle = SyncResponse(protocol: 1, sequence: store.state.sequence ?? 0, notes: [], results: [], delta: true)
        var probe = store.state; probe.sequence = idle.sequence; store.state = probe
        try require(store.apply(idle, sent: []) == .unchanged && !FileManager.default.fileExists(atPath: store.file.path), "Idle poll rewrote the state file")
        cases += 1
        print("LAYOUT_CHECK_OK: \(cases) native cases, multiline cards, one/two columns, notices, title styling, attachment chips, undo, comparison and idle polls")
    }
}
