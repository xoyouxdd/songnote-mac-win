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
                try require(card.frame.height == 84, "Card height changed unexpectedly")
                for earlier in list.cards.prefix(index) { try require(!card.frame.intersects(earlier.frame), "Cards overlap") }
                try checkControls(card)
                let lines = [card.title, card.preview, card.hint]
                let frames = lines.map { $0.alignmentRect(forFrame: $0.frame) }.sorted { $0.minY < $1.minY }
                for pair in zip(frames, frames.dropFirst()) {
                    try require(pair.1.minY - pair.0.maxY >= 2, "Title, preview or timestamp overlap")
                }
                for field in lines {
                    try require(field.maximumNumberOfLines == 1 && field.cell?.usesSingleLineMode == true, "Card label can wrap")
                    try require(field.stringValue.components(separatedBy: .newlines).count == 1, "Newline leaked into card label")
                }
                try require(!card.preview.stringValue.isEmpty, "Long multiline note lost its preview")
            }
            if size.width == 460 { try require(scroll.contentSize.height >= 6 * 84 + 5 * 8, "Default window cannot show six cards") }
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
                let button = editor.syncButton.convert(editor.syncButton.bounds, to: root)
                try require(abs(root.bounds.maxX - button.maxX - 12) < 1, "Sync button is not right aligned")
                try require(editor.editor.enclosingScrollView!.frame.height >= size.height * 0.6, "Editor is squeezed by controls")
                if mode == 1 { try require(editor.statusLabel.stringValue.contains("保存失败"), "Save failure hidden by sync status") }
                if mode >= 2 { try require(!editor.banner.isHidden, "Persistent conflict notice hidden") }
                // A pinned note shows a tinted pin, never the solid ink block that read as a stuck button.
                if note.pinned { try require((editor.pinButton as? ToolButton).map { $0.baseColor != Theme.ink && $0.baseColor != .clear } == true, "Pinned state should be a colour tint") }
                cases += 1
            }
        }
        var withFiles = original; withFiles.conflict_of = nil
        withFiles.attachments = (0..<8).map { Attachment(id: UUID().uuidString, name: "很长的虚构附件名称检查窄窗-\($0).pdf", size: 1024, sha256: String(repeating: "a", count: 64)) }
        delegate.store.state.deleteConflictIDs = nil; delegate.store.lastSaved = true
        delegate.store.state.notes[original.id] = withFiles
        for expanded in [false, true] {
            editor.attachmentsExpanded = expanded; editor.refresh()
            for size in [NSSize(width: 280, height: 240), NSSize(width: 380, height: 420)] {
                editor.window.setContentSize(size); editor.window.contentView!.layoutSubtreeIfNeeded()
                try checkControls(editor.window.contentView!)
                try require(editor.attachmentContainer.frame.height <= 114, "Attachment list has no height bound")
                try require(editor.editor.enclosingScrollView!.frame.height >= 60, "Attachment list squeezes the editor")
                try require(editor.attachmentScroll.isHidden == !expanded, "Attachment fold state is wrong")
                cases += 1
            }
        }
        print("LAYOUT_CHECK_OK: \(cases) native cases, multiline cards, one/two columns, notices and folded/expanded attachments")
    }
}
