import AppKit
import ServiceManagement

let colorNames = ["yellow": "黄色", "green": "绿色", "blue": "蓝色", "pink": "粉色", "purple": "紫色", "gray": "灰色"]
let colorOrder = ["yellow", "green", "blue", "pink", "purple", "gray"]

final class AttachmentButton: NSButton { var attachment: Attachment? }

// One line of file chips under the text; chips that do not fit collapse into a "+N" chip.
final class AttachmentStrip: NSView {
    var chips: [AttachmentButton] = []
    let overflow = AttachmentButton(title: "", target: nil, action: nil)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); addSubview(overflow) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setChips(_ next: [AttachmentButton]) {
        for chip in chips { chip.removeFromSuperview() }
        chips = next; for chip in chips { addSubview(chip, positioned: .below, relativeTo: overflow) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let gap: CGFloat = 6
        func width(_ button: NSButton) -> CGFloat { min(150, ceil(button.fittingSize.width) + 12) }
        var x: CGFloat = 0; var shown = 0
        for (index, chip) in chips.enumerated() {
            let remaining = chips.count - index - 1
            overflow.title = "+\(remaining)"
            let reserve = remaining > 0 ? width(overflow) + gap : 0
            let w = width(chip)
            guard x + w + reserve <= bounds.width || (index == 0 && remaining == 0) else { break }
            chip.isHidden = false; chip.frame = NSRect(x: x, y: 0, width: min(w, bounds.width), height: 24); x += w + gap; shown += 1
        }
        for chip in chips.dropFirst(shown) { chip.isHidden = true }
        overflow.isHidden = shown == chips.count
        overflow.title = "+\(chips.count - shown)"; Theme.button(overflow)
        overflow.setAccessibilityLabel("另外 \(chips.count - shown) 个附件")
        overflow.frame = NSRect(x: x, y: 0, width: width(overflow), height: 24)
    }
}

@MainActor final class NoteWindow: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextStorageDelegate {
    var id: String
    let store: Store
    let window: NSWindow
    let editor = CommittedTextView()
    let tools = NSStackView()
    let statusLabel = NSTextField(labelWithString: "已保存到本机")
    let conflictLabel = NSTextField(wrappingLabelWithString: "")
    let noticeButton = NSButton(title: "", target: nil, action: nil)
    let bannerIcon = NSImageView()
    let banner = NSStackView()
    let syncButton = ToolButton()
    var pinButton: NSButton!
    var moreButton: NSButton!
    var bannerHeight: NSLayoutConstraint!
    var showList: (() -> Void)?
    var newNote: (() -> Void)?
    var openOriginal: ((String) -> Void)?
    var didClose: ((String) -> Void)?
    var didFinishEditing: (() -> Void)?
    var lastPinned = false
    var closing = false
    let attachments = AttachmentStrip()
    var attachmentHeight: NSLayoutConstraint!
    var displayedAttachments: [Attachment] = []
    var downloading = Set<String>()
    var localAttachmentMessage = ""
    var composition: NoteComposition?
    var compositionBase: Note? {
        get { composition?.note }
        set { composition = newValue.map { NoteComposition($0) } }
    }
    init(note: Note, store: Store, present: Bool = true, cascadeFrom: NSWindow? = nil) {
        id = note.id; self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.delegate = self; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 280, height: 240)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .aqua)
        if present { Theme.restore(window, name: "note-" + id, cascadeFrom: cascadeFrom) }
        // Only pin and "more" stay in the titlebar; new note and the list live in the menu and ⌘N / ⌘L.
        pinButton = Theme.iconButton("pin", label: "列表置顶", target: self, action: #selector(setPin))
        moreButton = Theme.iconButton("ellipsis", label: "更多：新建、列表、颜色、附件、总在最前、删除", target: self, action: #selector(showMore))
        for button in [pinButton!, moreButton!] { tools.addArrangedSubview(button) }
        tools.spacing = 6; tools.alignment = .centerY
        Theme.titlebar(window, view: tools, width: 58, side: .right)
        window.level = UserDefaults.standard.bool(forKey: "top-" + id) ? .floating : .normal
        let root = NSView(); root.wantsLayer = true; window.contentView = root
        conflictLabel.font = .systemFont(ofSize: 11); conflictLabel.textColor = Theme.ink
        conflictLabel.maximumNumberOfLines = 2
        conflictLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeButton.target = self; noticeButton.action = #selector(handleNotice); Theme.button(noticeButton)
        noticeButton.setContentHuggingPriority(.required, for: .horizontal)
        noticeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        banner.orientation = .horizontal; banner.spacing = 8; banner.alignment = .centerY
        banner.wantsLayer = true; banner.layer?.cornerRadius = 6; banner.layer?.borderWidth = 1
        banner.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 5)
        bannerIcon.setContentHuggingPriority(.required, for: .horizontal)
        banner.addArrangedSubview(bannerIcon); banner.addArrangedSubview(conflictLabel); banner.addArrangedSubview(noticeButton)
        banner.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(banner)
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        editor.isRichText = false; editor.allowsUndo = true; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = NoteWindow.bodyFont; editor.textColor = Theme.ink; editor.drawsBackground = false
        editor.defaultParagraphStyle = NoteWindow.bodyParagraph; editor.typingAttributes[.paragraphStyle] = NoteWindow.bodyParagraph
        editor.textContainerInset = NSSize(width: 14, height: 6); editor.textStorage?.delegate = self
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self; editor.onCommit = { [weak self] in self?.saveCommittedText() }
        scroll.documentView = editor; root.addSubview(scroll)
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = Theme.faint
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        syncButton.image = Theme.symbol("arrow.triangle.2.circlepath", size: 12); syncButton.imagePosition = .imageOnly
        syncButton.target = self; syncButton.action = #selector(syncNow); Theme.button(syncButton); syncButton.contentTintColor = Theme.muted
        syncButton.setAccessibilityLabel("立即同步"); syncButton.toolTip = "立即同步（⌘R）；保存失败时先重试本地保存"
        syncButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        syncButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let footer = NSStackView(views: [statusLabel, NSView(), syncButton]); footer.spacing = 8
        footer.alignment = .centerY; footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        attachments.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(attachments)
        attachments.overflow.target = self; attachments.overflow.action = #selector(showAllAttachments(_:))
        attachmentHeight = attachments.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            attachments.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), attachments.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            attachments.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6), attachmentHeight])
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            banner.topAnchor.constraint(equalTo: root.topAnchor, constant: 6), bannerHeight,
            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: attachments.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)])
        lastPinned = note.pinned
        refresh()
        if present { Theme.presentNew(window); window.makeFirstResponder(editor) }
    }
    func refresh() {
        guard let note = store.state.notes[id] else { return }
        // Do not close or replace an editor during marked text composition.
        // The committed text will be saved against the current revision next.
        if note.deleted {
            closeIfDeleted()
            if closing { return }
        }
        window.title = String(note.title.prefix(40)) + (note.conflict_of == nil ? "" : " · 冲突副本")
        if !editor.hasMarkedText(), compositionBase == nil, editor.string != note.text {
            let selected = editor.selectedRange(); editor.string = note.text; styleText()
            editor.setSelectedRange(NSRange(location: min(selected.location, (note.text as NSString).length), length: 0))
            editor.undoManager?.removeAllActions()
        }
        let background = Theme.palette[note.color] ?? Theme.palette["yellow"]!
        window.backgroundColor = background; Theme.background(window.contentView?.layer, color: background)
        // Pinned: filled pin on a tint of the note colour, not a heavy dark block on pastel paper.
        pinButton.image = Theme.symbol(note.pinned ? "pin.fill" : "pin")
        Theme.button(pinButton, tint: note.pinned ? (Theme.accents[note.color] ?? Theme.ink).withAlphaComponent(0.3) : nil)
        let toolTint = (Theme.accents[note.color] ?? Theme.ink).blended(withFraction: 0.65, of: Theme.ink) ?? Theme.ink
        pinButton.contentTintColor = toolTint; moreButton.contentTintColor = toolTint
        pinButton.setAccessibilityLabel(note.pinned ? "取消列表置顶" : "列表置顶"); pinButton.toolTip = note.pinned ? "已列表置顶（点击取消）" : "列表置顶"
        if lastPinned != note.pinned { Theme.bounce(pinButton) }; lastPinned = note.pinned
        if store.state.deleteConflictIDs?.contains(id) == true {
            showNotice(warning: true, "删除未执行：另一端有新内容" + (note.conflict_of == nil ? "" : "（副本）"), action: "知道了", enabled: true)
        } else if let originalID = note.conflict_of {
            let original = store.state.notes[originalID]
            let available = original != nil && original?.deleted == false
            showNotice(warning: false, available ? "冲突副本 · 两份内容都已保留" : "冲突副本 · 原便签已删除", action: "查看原件", enabled: available)
        } else { banner.isHidden = true; bannerHeight.constant = 0 }
        Theme.button(noticeButton)
        // Footer is quiet: the edit time when everything is synced, otherwise the state that needs attention.
        let sync = store.syncStatus(for: id)
        let quiet = store.lastSaved && store.syncError == nil && sync.hasPrefix("已同步")
        let message = store.attachmentStatus ?? (localAttachmentMessage.isEmpty ? nil : localAttachmentMessage)
        statusLabel.stringValue = !store.lastSaved ? "本地保存失败，请勿退出" : (message ?? (Theme.timestamp(note.updated_at) + (quiet ? "" : " · " + sync)))
        statusLabel.textColor = !store.lastSaved ? .systemRed : (store.syncError == nil ? Theme.faint : .systemOrange)
        statusLabel.toolTip = store.saveError ?? (store.saveStatus + "；" + sync + "。已同步表示服务器已接收，另一台电脑须运行应用并联网。")
        syncButton.isEnabled = !store.syncing; syncButton.isHidden = quiet && message == nil
        refreshAttachments(note)
        Theme.spin(syncButton, active: store.syncing && store.showSyncProgress)
    }
    // Persistent banner above the text: tinted box, icon, short copy; the long explanation is the tooltip.
    func showNotice(warning: Bool, _ text: String, action: String, enabled: Bool) {
        bannerIcon.image = Theme.symbol(warning ? "exclamationmark.triangle" : "doc.on.doc", size: 12)
        bannerIcon.contentTintColor = warning ? NSColor(hex: 0x8A5A00) : Theme.ink
        banner.layer?.backgroundColor = (warning ? NSColor(hex: 0xFDF1DA) : NSColor.white.withAlphaComponent(0.7)).cgColor
        banner.layer?.borderColor = (warning ? NSColor(hex: 0xE7CA8A) : Theme.ink.withAlphaComponent(0.2)).cgColor
        conflictLabel.stringValue = text; conflictLabel.font = .systemFont(ofSize: 12)
        conflictLabel.toolTip = warning ? "你删除了这条便签，但另一台电脑在此之前改过它，所以保留了新内容。点「知道了」关闭提示。"
            : "两台电脑同时改了同一条便签，这是另存的一份；两份内容都在，可以对照后删掉不需要的。"
        noticeButton.title = action; noticeButton.isEnabled = enabled
        banner.isHidden = false; bannerHeight.constant = 38
    }
    func closeIfDeleted() {
        if closing || editor.hasMarkedText() || compositionBase != nil { return }
        guard store.state.notes[id]?.deleted == true else { return }
        closing = true
        window.close()
    }
    func remap(to newID: String) {
        let oldID = id; id = newID
        composition?.remap(to: newID, revision: store.state.notes[newID]?.revision,
                           conflictOf: store.state.notes[newID]?.conflict_of)
        let defaults = UserDefaults.standard
        defaults.set(defaults.bool(forKey: "top-" + oldID), forKey: "top-" + newID)
        window.setFrameAutosaveName("note-" + newID); window.saveFrame(usingName: "note-" + newID)
    }
    func accept(_ receipts: [Receipt], sent: [Change]) {
        composition?.accept(receipts, sent: sent)
    }
    @objc func returnToList() { showList?() }
    @objc func createNote() { newNote?() }
    @objc func syncNow() { saveCommittedText(); store.sync(force: true) }
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let titleFont = NSFont.systemFont(ofSize: 19, weight: .semibold)
    static let bodyParagraph: NSParagraphStyle = { let style = NSMutableParagraphStyle(); style.lineSpacing = 6; return style }()
    static let titleParagraph: NSParagraphStyle = { let style = NSMutableParagraphStyle(); style.lineSpacing = 4; style.paragraphSpacing = 6; return style }()
    // The first non-empty line reads as the title. Only display attributes change; the saved text stays plain.
    func styleText(_ storage: NSTextStorage? = nil, edited: NSRange? = nil) {
        guard let storage = storage ?? editor.textStorage else { return }
        let text = storage.string as NSString
        guard text.length > 0 else { editor.typingAttributes[.font] = NoteWindow.titleFont; editor.typingAttributes[.paragraphStyle] = NoteWindow.titleParagraph; return }
        var title = NSRange(location: 0, length: 0); var location = 0
        while location < text.length {
            let line = text.paragraphRange(for: NSRange(location: location, length: 0))
            if !text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = line; break }
            location = NSMaxRange(line)
        }
        var range = NSRange(location: 0, length: text.length)
        if let edited, title.length > 0 { range = NSUnionRange(text.paragraphRange(for: NSRange(location: min(edited.location, text.length), length: min(edited.length, text.length - min(edited.location, text.length)))), NSRange(location: 0, length: NSMaxRange(title))) }
        storage.addAttributes([.font: NoteWindow.bodyFont, .paragraphStyle: NoteWindow.bodyParagraph], range: range)
        if title.length > 0 { storage.addAttributes([.font: NoteWindow.titleFont, .paragraphStyle: NoteWindow.titleParagraph], range: title) }
    }
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { styleText(textStorage, edited: editedRange) }
    }
    func refreshAttachments(_ note: Note) {
        let values = note.attachments ?? []
        attachments.isHidden = values.isEmpty
        attachmentHeight.constant = values.isEmpty ? 0 : 24
        if values != displayedAttachments {
            displayedAttachments = values
            attachments.setChips(values.map { value in
                let chip = AttachmentButton(title: value.name, image: Theme.symbol(Self.fileSymbol(value.name), size: 11)!, target: self, action: #selector(showAttachment(_:)))
                chip.attachment = value; chip.imagePosition = .imageLeading; Theme.button(chip); chip.contentTintColor = Theme.muted
                chip.font = .systemFont(ofSize: 12); chip.lineBreakMode = .byTruncatingMiddle
                chip.attributedTitle = NSAttributedString(string: value.name, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.ink])
                (chip.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
                chip.toolTip = value.name + " · " + ByteCountFormatter.string(fromByteCount: Int64(value.size), countStyle: .file) + "（点击下载或移除）"
                chip.setAccessibilityLabel("附件 " + value.name); return chip
            })
        }
    }
    static func fileSymbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "gz": return "doc.zipper"
        default: return "doc"
        }
    }
    func attachmentMenu(_ value: Attachment, into menu: NSMenu) {
        let size = ByteCountFormatter.string(fromByteCount: Int64(value.size), countStyle: .file)
        let header = menu.addItem(withTitle: value.name + " · " + size, action: nil, keyEquivalent: ""); header.isEnabled = false
        let download = menu.addItem(withTitle: downloading.contains(value.id) ? "正在下载…" : "下载…", action: #selector(downloadAttachment(_:)), keyEquivalent: "")
        download.target = self; download.representedObject = value; download.isEnabled = !downloading.contains(value.id)
        let remove = menu.addItem(withTitle: "移除…", action: #selector(removeAttachment(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = value; remove.isEnabled = store.state.notes[id]?.deleted == false
    }
    @objc func showAttachment(_ sender: AttachmentButton) {
        guard let value = sender.attachment else { return }
        let menu = NSMenu(); menu.autoenablesItems = false; attachmentMenu(value, into: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
    @objc func showAllAttachments(_ sender: NSButton) {
        let menu = NSMenu(); menu.autoenablesItems = false
        for value in displayedAttachments {
            let item = menu.addItem(withTitle: value.name, action: nil, keyEquivalent: ""); item.image = Theme.symbol(Self.fileSymbol(value.name), size: 12)
            let sub = NSMenu(); sub.autoenablesItems = false; attachmentMenu(value, into: sub); item.submenu = sub
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
    func showAttachmentError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "附件操作失败"; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    @objc func addAttachments() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "添加便签附件（单文件最多 20 MiB，每条最多 20 个）"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            Task { @MainActor in
                do {
                    for source in panel.urls {
                        let value = try await self.store.files.importFile(source)
                        guard var note = self.store.state.notes[self.id], !note.deleted else { throw AttachmentFiles.failure("便签已删除。") }
                        let values = (note.attachments ?? []) + [value]
                        guard Attachment.validList(values) else { throw AttachmentFiles.failure("每条便签最多 20 个附件。") }
                        note.attachments = values; self.composition?.update(attachments: values); self.store.update(note)
                        guard self.store.lastSaved else { throw AttachmentFiles.failure("附件信息保存失败，请先重试本地保存。文件已保留。") }
                    }
                } catch { self.showAttachmentError(error.localizedDescription) }
            }
        }
    }
    @objc func removeAttachment(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Attachment else { return }
        let alert = NSAlert(); alert.messageText = "从这条便签移除附件？"; alert.informativeText = value.name + "\n移除会同步到另一台电脑。"
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, var note = self.store.state.notes[self.id], !note.deleted else { return }
            note.attachments = (note.attachments ?? []).filter { $0.id != value.id }
            self.composition?.update(attachments: note.attachments ?? []); self.store.update(note)
        }
    }
    @objc func downloadAttachment(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Attachment, !downloading.contains(value.id) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = value.name; panel.title = "附件另存为"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.downloading.insert(value.id); self.localAttachmentMessage = "正在下载 · " + value.name; self.refresh()
            Task { @MainActor in
                defer { self.downloading.remove(value.id) }
                do { try await self.store.files.download(value, to: destination); self.localAttachmentMessage = "已下载 · " + value.name; self.refresh() }
                catch { self.localAttachmentMessage = "下载失败 · 可重试"; self.refresh(); self.showAttachmentError(error.localizedDescription) }
            }
        }
    }
    func textDidChange(_ notification: Notification) { saveCommittedText() }
    func saveCommittedText() {
        if editor.hasMarkedText() {
            if compositionBase == nil { compositionBase = store.state.notes[id] }; return
        }
        guard var note = compositionBase ?? store.state.notes[id] else { return }
        compositionBase = nil
        guard editor.string != note.text else { refresh(); return }
        if editor.string.utf16.count > 100000 { editor.string = note.text; NSSound.beep(); refresh(); return }
        // Editing a remote tombstone is submitted as a stale edit and preserved
        // by the server as a conflict copy instead of losing newly committed text.
        note.text = editor.string; note.deleted = false; store.update(note)
    }
    func prepareForClose() {
        guard editor.hasMarkedText() else { saveCommittedText(); return }
        // Closing cancels an unconfirmed candidate instead of persisting raw
        // pinyin. Preserve all text already committed and saved in LocalState.
        let committed = store.state.notes[id]?.text ?? compositionBase?.text ?? ""
        editor.inputContext?.discardMarkedText(); editor.unmarkText()
        compositionBase = nil; editor.string = committed
    }
    func writeComposition(pinned: Bool? = nil, color: String? = nil) {
        composition?.update(pinned: pinned, color: color)
    }
    @objc func setPin() {
        guard var note = store.state.notes[id] else { return }; note.pinned.toggle()
        writeComposition(pinned: note.pinned); store.update(note)
    }
    @objc func setColor(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? [String: String], let value = data["color"], var note = store.state.notes[id], note.color != value else { return }
        note.color = value; writeComposition(color: value); store.update(note)
    }
    @objc func setTop() {
        let top = window.level != .floating; window.level = top ? .floating : .normal
        UserDefaults.standard.set(top, forKey: "top-" + id)
    }
    @objc func handleNotice() {
        if store.state.deleteConflictIDs?.contains(id) == true { store.acknowledgeDeleteConflict(id) }
        else if let original = store.state.notes[id]?.conflict_of { openOriginal?(original) }
    }
    @objc func showMore() {
        guard let note = store.state.notes[id] else { return }
        let menu = NSMenu()
        let create = menu.addItem(withTitle: "新建便签", action: #selector(createNote), keyEquivalent: "n"); create.target = self
        let list = menu.addItem(withTitle: "便签列表", action: #selector(returnToList), keyEquivalent: "l"); list.target = self
        menu.addItem(.separator())
        Theme.addColorPicker(to: menu, id: id, selected: note.color, target: self, action: #selector(setColor(_:)))
        menu.addItem(.separator())
        let attachment = menu.addItem(withTitle: "添加附件…", action: #selector(addAttachments), keyEquivalent: ""); attachment.target = self
        menu.addItem(.separator())
        let top = menu.addItem(withTitle: "总在最前（仅本机窗口）", action: #selector(setTop), keyEquivalent: "")
        top.target = self; top.state = window.level == .floating ? .on : .off
        menu.addItem(.separator())
        let remove = menu.addItem(withTitle: "删除便签…", action: #selector(deleteNote), keyEquivalent: ""); remove.target = self
        remove.attributedTitle = NSAttributedString(string: "删除便签…", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)])
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.minY), in: moreButton)
    }
    @objc func deleteNote() {
        let alert = NSAlert(); alert.messageText = "删除这条便签？"; alert.informativeText = "删除会同步到另一台电脑。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, var note = self.store.state.notes[self.id] else { return }
            let composing = self.editor.hasMarkedText() || self.compositionBase != nil
            note.deleted = true; self.store.update(note)
            if composing, self.window.isVisible { self.window.close() }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closing = true
        prepareForClose()
        guard store.lastSaved else {
            let alert = NSAlert(); alert.messageText = "本地保存失败，请先重试保存"
            alert.informativeText = store.saveError ?? "内容尚未安全保存。"; alert.runModal()
            closing = false; return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) { store.discardDraft(id); didClose?(id) }
    func windowDidBecomeKey(_ notification: Notification) { Theme.animate(changes: { self.tools.animator().alphaValue = 1 }) }
    func windowDidResignKey(_ notification: Notification) {
        Theme.animate(changes: { self.tools.animator().alphaValue = 0.35 }); didFinishEditing?()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate {
    var store: Store!
    var window: NSWindow!
    let search = NSTextField()
    let clearSearch = ToolButton()
    let list = NotesListView()
    let status = NSTextField(labelWithString: "正在连接…")
    let empty = NSTextField(labelWithString: "还没有便签\n点右上角 +，记下第一件事")
    let emptyAction = NSButton(title: "新建便签", target: nil, action: nil)
    let emptyContainer = NSStackView()
    let searchBox = NSView()
    let connectionDot = NSView()
    let syncButton = ToolButton()
    let noticeButton = ToolButton()
    var rows: [Note] = []
    var cards: [String: NoteCardView] = [:]
    var selectedID: String?
    var groupKeys: [String: String] = [:]
    var editors: [String: NoteWindow] = [:]
    var statusItem: NSStatusItem!
    var quitting = false
    var checkingLayout = false
    var clockTimer: Timer?
    var lastSyncAt: Date?
    var motionObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { store = try Store() }
        catch {
            let alert = NSAlert(); alert.messageText = "无法读取便签数据或同步配置"
            alert.informativeText = "原文件已保留，未创建空数据覆盖。\n\(error.localizedDescription)"
            alert.runModal(); NSApp.terminate(nil); return
        }
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { NSApp.applicationIconImage = NSImage(contentsOf: icon) }
        buildMenu(); buildList()
        store.onChange = { [weak self] in self?.refresh() }
        store.onAccepted = { [weak self] receipts, sent in
            guard let self else { return }
            for editor in Array(self.editors.values) { editor.accept(receipts, sent: sent) }
        }
        store.onRemap = { [weak self] mappings in
            guard let self else { return }
            for (old, new) in mappings {
                if let editor = self.editors.removeValue(forKey: old) { editor.remap(to: new); self.editors[new] = editor }
                if self.selectedID == old { self.selectedID = new }
            }
            self.saveOpenWindows()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "SongNote 便签")
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu; menuNeedsUpdate(menu)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Theme.reduceMotion {
                    Theme.finishPresentations()
                    @MainActor func clear(_ view: NSView) { view.layer?.removeAllAnimations(); for child in view.subviews { clear(child) } }
                    if let root = self.window.contentView { clear(root) }
                    for editor in self.editors.values { clear(editor.tools); if let root = editor.window.contentView { clear(root) } }
                }
                self.refresh()
            }
        }
        refresh(); showList()
        for id in UserDefaults.standard.stringArray(forKey: "open-notes") ?? [] {
            if let note = store.state.notes[id], !note.deleted { open(note) }
        }
        store.start()
    }
    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(); appItem.submenu = appMenu; main.addItem(appItem)
        appMenu.addItem(withTitle: "关于 SongNote", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 SongNote", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 SongNote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let noteItem = NSMenuItem(); noteItem.title = "便签"; let noteMenu = NSMenu(title: "便签"); noteItem.submenu = noteMenu; main.addItem(noteItem)
        noteMenu.addItem(withTitle: "新建便签", action: #selector(newNote), keyEquivalent: "n").target = self
        noteMenu.addItem(withTitle: "便签列表", action: #selector(showList), keyEquivalent: "l").target = self
        noteMenu.addItem(withTitle: "立即同步", action: #selector(syncNow), keyEquivalent: "r").target = self
        let editItem = NSMenuItem(); editItem.title = "编辑"; let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu; main.addItem(editItem)
        for (name, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { editMenu.addItem(withTitle: name, action: Selector(action), keyEquivalent: key) }
        let redo = NSMenuItem(title: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; editMenu.insertItem(redo, at: 1)
        editMenu.addItem(.separator()); editMenu.addItem(withTitle: "搜索便签", action: #selector(focusSearch), keyEquivalent: "f").target = self
        let windowItem = NSMenuItem(); windowItem.title = "窗口"; let windowMenu = NSMenu(title: "窗口"); windowItem.submenu = windowMenu; main.addItem(windowItem)
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu; NSApp.mainMenu = main
    }
    func buildList() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 710), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SongNote · 便签列表"; window.contentMinSize = NSSize(width: 360, height: 360)
        window.backgroundColor = Theme.paper; window.appearance = NSAppearance(named: .aqua)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.isReleasedWhenClosed = false
        if !checkingLayout { Theme.restore(window, name: "note-list") }
        let title = NSTextField(labelWithString: "便签"); title.font = .systemFont(ofSize: 13, weight: .semibold); title.textColor = Theme.ink
        let heading = NSStackView(views: [title]); heading.alignment = .centerY
        Theme.titlebar(window, view: heading, width: 40, side: .left)
        let add = Theme.iconButton("plus", label: "新建便签（⌘N）", target: self, action: #selector(newNote))
        add.image = Theme.symbol("plus", size: 15); add.contentTintColor = Theme.muted
        let actions = NSStackView(views: [add]); Theme.titlebar(window, view: actions, width: 30, side: .right)
        let root = NSView(); window.contentView = root
        // Borderless search on a soft filled track instead of the outlined bezel.
        searchBox.wantsLayer = true; searchBox.layer?.cornerRadius = 7; searchBox.layer?.backgroundColor = Theme.field.cgColor
        searchBox.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(searchBox)
        search.placeholderAttributedString = NSAttributedString(string: "搜索", attributes: [.foregroundColor: Theme.faint, .font: NSFont.systemFont(ofSize: 13)])
        search.delegate = self; search.font = .systemFont(ofSize: 13); search.toolTip = "搜索标题或内容（⌘F），Esc 清空"
        search.isBezeled = false; search.isBordered = false; search.drawsBackground = false; search.focusRingType = .none
        search.cell?.usesSingleLineMode = true; search.cell?.isScrollable = true; search.setAccessibilityLabel("搜索便签")
        let magnifier = NSImageView(image: Theme.symbol("magnifyingglass", size: 12)!); magnifier.contentTintColor = Theme.faint
        clearSearch.image = Theme.symbol("xmark.circle.fill", size: 12); clearSearch.imagePosition = .imageOnly; clearSearch.isHidden = true
        clearSearch.target = self; clearSearch.action = #selector(clearQuery); clearSearch.setAccessibilityLabel("清除搜索"); clearSearch.toolTip = "清除搜索（Esc）"
        Theme.button(clearSearch); clearSearch.contentTintColor = Theme.faint
        for view in [magnifier, search, clearSearch] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; searchBox.addSubview(view) }
        let scroll = NotesScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        list.autoresizingMask = [.width]; scroll.documentView = list; root.addSubview(scroll)
        let rule = NSBox(); rule.boxType = .custom; rule.borderWidth = 0; rule.fillColor = Theme.hairline
        rule.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(rule)
        status.font = .systemFont(ofSize: 11); status.textColor = Theme.muted
        status.lineBreakMode = .byTruncatingTail; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        connectionDot.wantsLayer = true; connectionDot.layer?.cornerRadius = 3
        connectionDot.widthAnchor.constraint(equalToConstant: 6).isActive = true; connectionDot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        for (button, symbol, label, action) in [(syncButton, "arrow.triangle.2.circlepath", "立即同步（⌘R）", #selector(syncNow)), (noticeButton, "exclamationmark.bubble", "查看冲突提醒", #selector(openNextNotice))] {
            button.image = Theme.symbol(symbol); button.imagePosition = .imageOnly; button.target = self; button.action = action
            button.setAccessibilityLabel(label); button.toolTip = label; Theme.button(button); button.contentTintColor = Theme.muted
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true; button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let footer = NSStackView(views: [connectionDot, status, NSView(), noticeButton, syncButton]); footer.spacing = 8; footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        let emptyIcon = NSImageView(image: Theme.symbol("square.and.pencil", size: 32)!); emptyIcon.contentTintColor = Theme.muted
        empty.alignment = .center; empty.font = .systemFont(ofSize: 13); empty.textColor = Theme.muted; empty.maximumNumberOfLines = 3
        emptyAction.target = self; emptyAction.action = #selector(newNote); Theme.button(emptyAction, primary: true)
        emptyAction.translatesAutoresizingMaskIntoConstraints = false
        emptyAction.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        emptyAction.heightAnchor.constraint(equalToConstant: 28).isActive = true
        emptyContainer.orientation = .vertical; emptyContainer.alignment = .centerX; emptyContainer.spacing = 12
        emptyContainer.addArrangedSubview(emptyIcon); emptyContainer.addArrangedSubview(empty); emptyContainer.addArrangedSubview(emptyAction)
        emptyContainer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(emptyContainer)
        NSLayoutConstraint.activate([
            searchBox.topAnchor.constraint(equalTo: root.topAnchor, constant: 6), searchBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), searchBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), searchBox.heightAnchor.constraint(equalToConstant: 30),
            magnifier.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 9), magnifier.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            search.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 6), search.trailingAnchor.constraint(equalTo: clearSearch.leadingAnchor, constant: -4), search.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            clearSearch.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -5), clearSearch.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            clearSearch.widthAnchor.constraint(equalToConstant: 20), clearSearch.heightAnchor.constraint(equalToConstant: 20),
            scroll.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: rule.topAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor), rule.trailingAnchor.constraint(equalTo: root.trailingAnchor), rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -7),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -7),
            emptyContainer.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), emptyContainer.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)])
    }
    func refresh(forceOrder: Bool = false) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var nextRows = store.visible.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        let editing = editors.values.contains { $0.window.isKeyWindow && $0.window.firstResponder === $0.editor }
        let frozen = editing && !forceOrder
        if frozen {
            let oldOrder = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            let newOrder = Dictionary(uniqueKeysWithValues: nextRows.enumerated().map { ($0.element.id, $0.offset + rows.count) })
            nextRows.sort { (oldOrder[$0.id] ?? newOrder[$0.id]!) < (oldOrder[$1.id] ?? newOrder[$1.id]!) }
        }
        // While typing, rows keep their section as well as their position; headers settle after editing.
        var nextKeys: [String: String] = [:]
        for note in nextRows { nextKeys[note.id] = (frozen ? groupKeys[note.id] : nil) ?? (note.pinned ? "置顶" : Theme.dayGroup(note.updated_at)) }
        var groups: [NotesListView.Group] = []; var seen = Set<String>()
        for note in nextRows {
            let key = nextKeys[note.id]!
            if let last = groups.last, last.title == key || (last.title.isEmpty && seen.contains(key)) { groups[groups.count - 1] = .init(title: last.title, count: last.count + 1) }
            else { groups.append(.init(title: seen.contains(key) ? "" : key, count: 1)); seen.insert(key) }
        }
        let changedOrder = rows.map(\.id) != nextRows.map(\.id) || groupKeys != nextKeys; rows = nextRows; groupKeys = nextKeys
        for note in rows {
            if cards[note.id] == nil { cards[note.id] = makeCard(note) }
            cards[note.id]?.update(note, pending: store.state.pending[note.id] != nil, deleteConflict: store.state.deleteConflictIDs?.contains(note.id) == true, query: query)
        }
        if changedOrder {
            let previousSelection = selectedID
            let hadFocus = window.firstResponder is NoteCardView
            list.setCards(rows.compactMap { cards[$0.id] }, groups: groups, animated: !checkingLayout)
            cards = cards.filter { pair in rows.contains(where: { $0.id == pair.key }) }
            if !rows.contains(where: { $0.id == previousSelection }) { selectedID = rows.first?.id }
            if hadFocus, let id = selectedID, let card = cards[id] { window.makeFirstResponder(card) }
        }
        for (id, card) in cards { card.selected = id == selectedID }
        let notices = store.visible.filter { $0.conflict_of != nil || store.state.deleteConflictIDs?.contains($0.id) == true }.count
        status.stringValue = store.status + (notices > 0 ? " · \(notices) 条冲突提醒" : ""); status.toolTip = status.stringValue
        status.textColor = !store.lastSaved ? .systemRed : (store.syncError == nil ? Theme.muted : .systemOrange)
        noticeButton.isHidden = notices == 0; syncButton.isEnabled = !store.syncing
        connectionDot.layer?.backgroundColor = (!store.lastSaved ? NSColor.systemRed : (store.syncError == nil ? Theme.green : NSColor.systemOrange)).cgColor
        Theme.spin(syncButton, active: store.syncing && store.showSyncProgress)
        if lastSyncAt != store.lastSyncAt, store.lastSaved, store.showSyncProgress { Theme.pulse(connectionDot) }; lastSyncAt = store.lastSyncAt
        emptyContainer.isHidden = !rows.isEmpty
        empty.stringValue = !query.isEmpty ? "没有找到匹配的便签\n换个关键词试试" : "还没有便签\n随时按 ⌘N 新建一条"
        emptyAction.isHidden = !(rows.isEmpty && query.isEmpty)
        for editor in Array(editors.values) { editor.refresh() }
    }
    func makeCard(_ note: Note) -> NoteCardView {
        let id = note.id; let card = NoteCardView(frame: .zero)
        card.onOpen = { [weak self] in self?.openID(id) }
        card.onSelect = { [weak self] in self?.select(id) }
        card.onMove = { [weak self] delta in self?.moveSelection(from: id, by: delta) }
        card.contextMenu = { [weak self] in self?.cardMenu(id) ?? NSMenu() }
        return card
    }
    func select(_ id: String) { selectedID = id; for (key, card) in cards { card.selected = key == id } }
    func moveSelection(from id: String, by delta: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows.isEmpty, let current = cards[id] else { return }
        var next: String?
        if list.columns > 1 && abs(delta) == list.columns {
            // Up/down stays in the same column, even across section headers.
            let candidates = rows.compactMap { cards[$0.id] }.filter { abs($0.frame.minX - current.frame.minX) < 1 && (delta > 0 ? $0.frame.minY > current.frame.minY : $0.frame.minY < current.frame.minY) }
            next = (delta > 0 ? candidates.min { $0.frame.minY < $1.frame.minY } : candidates.max { $0.frame.minY < $1.frame.minY })?.id
        } else if index + delta >= 0 && index + delta < rows.count { next = rows[index + delta].id }
        guard let next else { return }
        guard let card = cards[next] else { return }; select(next); window.makeFirstResponder(card); card.scrollToVisible(card.bounds)
    }
    func cardMenu(_ id: String) -> NSMenu {
        let menu = NSMenu(); guard let note = store.state.notes[id] else { return menu }
        let pin = menu.addItem(withTitle: note.pinned ? "取消列表置顶" : "列表置顶", action: #selector(pinFromMenu(_:)), keyEquivalent: "")
        pin.target = self; pin.representedObject = id; pin.image = Theme.symbol(note.pinned ? "pin.fill" : "pin")
        menu.addItem(.separator()); Theme.addColorPicker(to: menu, id: id, selected: note.color, target: self, action: #selector(colorFromMenu(_:)))
        menu.addItem(.separator()); let remove = menu.addItem(withTitle: "删除便签…", action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = id; return menu
    }
    @objc func pinFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, var note = store.state.notes[id], !note.deleted else { return }
        note.pinned.toggle(); editors[id]?.writeComposition(pinned: note.pinned); store.update(note)
    }
    @objc func colorFromMenu(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? [String: String], let id = data["id"], let color = data["color"], var note = store.state.notes[id], !note.deleted, note.color != color else { return }
        note.color = color; editors[id]?.writeComposition(color: color); store.update(note)
    }
    @objc func deleteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let note = store.state.notes[id], !note.deleted else { return }
        let alert = NSAlert(); alert.messageText = "删除“\(String(note.title.prefix(24)))”？"; alert.informativeText = "删除会同步到另一台电脑。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, var current = self.store.state.notes[id], !current.deleted else { return }
            current.deleted = true; self.store.update(current)
        }
    }
    func controlTextDidChange(_ notification: Notification) { clearSearch.isHidden = search.stringValue.isEmpty; refresh(forceOrder: true) }
    @objc func clearQuery() { search.stringValue = ""; clearSearch.isHidden = true; refresh(forceOrder: true); window.makeFirstResponder(search) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === search, commandSelector == #selector(NSResponder.cancelOperation(_:)) { clearQuery(); return true }
        guard control === search, commandSelector == #selector(NSResponder.moveDown(_:)), let id = rows.first?.id, let card = cards[id] else { return false }
        window.makeFirstResponder(card); select(id); return true
    }
    func openID(_ id: String) {
        guard let note = store.state.notes[id], !note.deleted else { return }; open(note); NSApp.activate(ignoringOtherApps: true)
    }
    func open(_ note: Note) {
        if let existing = editors[note.id] { existing.window.makeKeyAndOrderFront(nil); return }
        let previous = editors.values.first(where: { $0.window.isKeyWindow })?.window ?? editors.values.max(by: { $0.window.windowNumber < $1.window.windowNumber })?.window
        let editor = NoteWindow(note: note, store: store, cascadeFrom: previous)
        editor.showList = { [weak self] in self?.showList() }; editor.newNote = { [weak self] in self?.newNote() }
        editor.openOriginal = { [weak self] id in self?.openID(id) }
        editor.didFinishEditing = { [weak self] in self?.refresh(forceOrder: true) }
        editor.didClose = { [weak self] id in
            guard let self else { return }; self.editors.removeValue(forKey: id); self.saveOpenWindows(); self.refresh(forceOrder: true)
        }
        editors[note.id] = editor; saveOpenWindows()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !checkingLayout else { return }; menu.removeAllItems()
        menu.addItem(withTitle: "便签列表", action: #selector(showList), keyEquivalent: "").target = self
        menu.addItem(withTitle: "新建便签", action: #selector(newNote), keyEquivalent: "").target = self
        menu.addItem(withTitle: "立即同步", action: #selector(syncNow), keyEquivalent: "").target = self
        let pinned = store.visible.filter(\.pinned)
        if !pinned.isEmpty {
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "置顶便签", action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
            for note in pinned {
                let item = menu.addItem(withTitle: String(note.title.prefix(32)), action: #selector(openPinned(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = note.id; item.image = Theme.dotImage(note.color)
            }
        }
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "开机启动", action: #selector(toggleLogin), keyEquivalent: ""); login.target = self
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed; login.title = "开机启动（等待系统批准）"
        default: login.state = .off
        }
        menu.addItem(.separator()); menu.addItem(withTitle: "退出 SongNote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }
    @objc func openPinned(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { openID(id) } }
    @objc func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "无法更改开机启动"
            alert.informativeText = error.localizedDescription + "\n可在系统设置 → 通用 → 登录项中管理 SongNote。"; alert.runModal()
        }
    }
    @objc func openNextNotice() {
        if let note = store.visible.first(where: { store.state.deleteConflictIDs?.contains($0.id) == true }) ?? store.visible.first(where: { $0.conflict_of != nil }) { open(note) }
    }
    func saveOpenWindows() { if !quitting { UserDefaults.standard.set(Array(editors.keys), forKey: "open-notes") } }
    @objc func newNote() { open(store.create()); NSApp.activate(ignoringOtherApps: true) }
    @objc func showList() { refresh(forceOrder: true); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func focusSearch() { showList(); window.makeFirstResponder(search) }
    @objc func syncNow() { for editor in Array(editors.values) { editor.saveCommittedText() }; store.sync(force: true) }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "SongNote", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版", .credits: NSAttributedString(string: "Windows / Mac 私人桌面便签\n自动保存 · 离线编辑 · 双向同步 · 文件附件")]) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showList(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil else { return .terminateNow }
        var discardedDrafts: [String: Note] = [:]
        for editor in Array(editors.values) {
            editor.prepareForClose()
            if store.state.draftIDs?.contains(editor.id) == true, let draft = store.state.notes[editor.id], draft.text.isEmpty { discardedDrafts[editor.id] = draft }
            store.discardDraft(editor.id)
        }
        if !store.persist() {
            let alert = NSAlert(); alert.messageText = "本地保存失败"; alert.informativeText = "退出可能丢失尚未保存的内容。"
            alert.addButton(withTitle: "继续使用"); alert.addButton(withTitle: "仍然退出")
            if alert.runModal() == .alertFirstButtonReturn {
                for (id, note) in discardedDrafts { store.state.notes[id] = note }
                store.state.draftIDs = (store.state.draftIDs ?? []).union(discardedDrafts.keys)
                refresh(); return .terminateCancel
            }
        }
        saveOpenWindows(); quitting = true; return .terminateNow
    }
}

@main struct SongNote {
    static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--check-layout") {
            application.setActivationPolicy(.prohibited)
            do { try LayoutChecks.run(); exit(0) }
            catch { fputs("LAYOUT_CHECK_FAILED: \(error)\n", stderr); exit(1) }
        }
        let delegate = AppDelegate(); application.delegate = delegate
        application.setActivationPolicy(.regular); application.run(); withExtendedLifetime(delegate) {}
    }
}
