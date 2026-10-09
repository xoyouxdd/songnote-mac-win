import AppKit

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
    var compare: ((String) -> Void)?
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
        // The titlebar pin keeps this window above other apps (this Mac only); "固定在列表顶部" lives in the menu.
        pinButton = Theme.iconButton("pin", label: "总在最前", target: self, action: #selector(setTop))
        moreButton = Theme.iconButton("ellipsis", label: "更多：新建、列表、固定、颜色、附件、删除", target: self, action: #selector(showMore))
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
        lastPinned = window.level == .floating
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
        // Always on top: filled pin on a tint of the note colour, not a heavy dark block on pastel paper.
        let floating = window.level == .floating
        pinButton.image = Theme.symbol(floating ? "pin.fill" : "pin")
        Theme.button(pinButton, tint: floating ? (Theme.accents[note.color] ?? Theme.ink).withAlphaComponent(0.3) : nil)
        let toolTint = (Theme.accents[note.color] ?? Theme.ink).blended(withFraction: 0.65, of: Theme.ink) ?? Theme.ink
        pinButton.contentTintColor = toolTint; moreButton.contentTintColor = toolTint
        pinButton.setAccessibilityLabel(floating ? "取消总在最前" : "总在最前"); pinButton.toolTip = floating ? "总在最前（仅本机，点击取消）" : "总在最前（仅本机）"
        if lastPinned != floating { Theme.bounce(pinButton) }; lastPinned = floating
        if store.state.deleteConflictIDs?.contains(id) == true {
            showNotice(warning: true, "删除未执行：另一端有新内容" + (note.conflict_of == nil ? "" : "（副本）"), action: "知道了", enabled: true)
        } else if let originalID = note.conflict_of {
            let original = store.state.notes[originalID]
            let available = original != nil && original?.deleted == false
            showNotice(warning: false, available ? "冲突副本 · 两份内容都已保留" : "冲突副本 · 原便签已删除", action: "对比", enabled: available)
        } else { banner.isHidden = true; bannerHeight.constant = 0 }
        Theme.button(noticeButton)
        // Footer is quiet: the edit time when everything is synced, otherwise the state that needs attention.
        let sync = store.remote.status(for: id)
        let quiet = store.lastSaved && store.remote.syncError == nil && sync.hasPrefix("已同步")
        let message = store.remote.attachmentStatus ?? (localAttachmentMessage.isEmpty ? nil : localAttachmentMessage)
        statusLabel.stringValue = !store.lastSaved ? Texts.saveFailed : (message ?? (Theme.timestamp(note.updated_at) + (quiet ? "" : " · " + sync)))
        statusLabel.textColor = !store.lastSaved ? .systemRed : (store.remote.syncError == nil ? Theme.faint : .systemOrange)
        statusLabel.toolTip = store.saveError ?? (store.saveStatus + "；" + sync + "。已同步表示服务器已接收，另一台电脑须运行应用并联网。")
        syncButton.isEnabled = !store.remote.syncing; syncButton.isHidden = quiet && message == nil
        refreshAttachments(note)
        Theme.spin(syncButton, active: store.remote.syncing && store.remote.showSyncProgress)
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
    @objc func syncNow() { saveCommittedText(); store.remote.sync(force: true) }
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
        UserDefaults.standard.set(top, forKey: "top-" + id); refresh()
    }
    @objc func handleNotice() {
        if store.state.deleteConflictIDs?.contains(id) == true { store.acknowledgeDeleteConflict(id) }
        else if store.state.notes[id]?.conflict_of != nil { compare?(id) }
    }
    @objc func showMore() {
        guard let note = store.state.notes[id] else { return }
        let menu = NSMenu()
        let create = menu.addItem(withTitle: "新建便签", action: #selector(createNote), keyEquivalent: "n"); create.target = self
        let list = menu.addItem(withTitle: "便签列表", action: #selector(returnToList), keyEquivalent: "l"); list.target = self
        menu.addItem(.separator())
        let fix = menu.addItem(withTitle: "固定在列表顶部", action: #selector(setPin), keyEquivalent: ""); fix.target = self
        fix.state = note.pinned ? .on : .off
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
        let alert = NSAlert(); alert.messageText = "删除这条便签？"; alert.informativeText = "删除会同步到另一台电脑，7 天内可在列表的「最近删除」中恢复。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.store.state.notes[self.id] != nil else { return }
            let composing = self.editor.hasMarkedText() || self.compositionBase != nil
            self.store.delete(self.id)
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
