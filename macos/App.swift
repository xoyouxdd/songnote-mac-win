import AppKit
import ServiceManagement

let colorNames = ["yellow": "黄色", "green": "绿色", "blue": "蓝色", "pink": "粉色", "purple": "紫色", "gray": "灰色"]
let colorOrder = ["yellow", "green", "blue", "pink", "purple", "gray"]

@MainActor final class NoteWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    var id: String
    let store: Store
    let window: NSWindow
    let editor = CommittedTextView()
    let tools = NSStackView()
    let statusLabel = NSTextField(labelWithString: "已保存到本机")
    let conflictLabel = NSTextField(wrappingLabelWithString: "")
    let noticeButton = NSButton(title: "", target: nil, action: nil)
    let banner = NSStackView()
    let syncButton = NSButton()
    var pinButton: NSButton!
    var moreButton: NSButton!
    var bannerHeight: NSLayoutConstraint!
    var showList: (() -> Void)?
    var newNote: (() -> Void)?
    var openOriginal: ((String) -> Void)?
    var didClose: ((String) -> Void)?
    var didFinishEditing: (() -> Void)?
    var lastPinned = false
    var compositionBase: Note?
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
        let add = Theme.iconButton("plus", label: "新建便签（⌘N）", target: self, action: #selector(createNote))
        let list = Theme.iconButton("list.bullet", label: "便签列表（⌘L）", target: self, action: #selector(returnToList))
        pinButton = Theme.iconButton("pin", label: "列表置顶", target: self, action: #selector(setPin))
        moreButton = Theme.iconButton("ellipsis", label: "更多：颜色、总在最前、删除", target: self, action: #selector(showMore))
        for button in [add, list, pinButton!, moreButton!] { tools.addArrangedSubview(button) }
        tools.spacing = 6; tools.alignment = .centerY
        Theme.titlebar(window, view: tools, width: 116, side: .right)
        window.level = UserDefaults.standard.bool(forKey: "top-" + id) ? .floating : .normal
        let root = NSView(); root.wantsLayer = true; window.contentView = root
        conflictLabel.font = .systemFont(ofSize: 11); conflictLabel.textColor = Theme.ink
        conflictLabel.maximumNumberOfLines = 2
        conflictLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeButton.target = self; noticeButton.action = #selector(handleNotice); Theme.button(noticeButton)
        noticeButton.setContentHuggingPriority(.required, for: .horizontal)
        noticeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        banner.orientation = .horizontal; banner.spacing = 8; banner.alignment = .centerY
        banner.addArrangedSubview(conflictLabel); banner.addArrangedSubview(noticeButton)
        banner.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(banner)
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        editor.isRichText = false; editor.allowsUndo = true; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 16); editor.textColor = Theme.ink; editor.drawsBackground = false
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5; editor.defaultParagraphStyle = paragraph
        editor.textContainerInset = NSSize(width: 16, height: 12)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self; editor.onCommit = { [weak self] in self?.saveCommittedText() }
        scroll.documentView = editor; root.addSubview(scroll)
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = Theme.muted
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        syncButton.image = Theme.symbol("arrow.triangle.2.circlepath", size: 12); syncButton.imagePosition = .imageOnly
        syncButton.target = self; syncButton.action = #selector(syncNow); Theme.button(syncButton)
        syncButton.setAccessibilityLabel("立即同步"); syncButton.toolTip = "立即同步（⌘R）；保存失败时先重试本地保存"
        syncButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        syncButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let footer = NSStackView(views: [statusLabel, NSView(), syncButton]); footer.spacing = 8
        footer.alignment = .centerY; footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            banner.topAnchor.constraint(equalTo: root.topAnchor, constant: 6), bannerHeight,
            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)])
        refresh()
        if present { Theme.presentNew(window); window.makeFirstResponder(editor) }
    }
    func refresh() {
        guard let note = store.state.notes[id] else { return }
        // Do not close or replace an editor during marked text composition.
        // The committed text will be saved against the current revision next.
        if note.deleted && !editor.hasMarkedText() && compositionBase == nil { window.close(); return }
        window.title = String(note.title.prefix(40)) + (note.conflict_of == nil ? "" : " · 冲突副本")
        if !editor.hasMarkedText(), compositionBase == nil, editor.string != note.text {
            let selected = editor.selectedRange(); editor.string = note.text
            editor.setSelectedRange(NSRange(location: min(selected.location, (note.text as NSString).length), length: 0))
            editor.undoManager?.removeAllActions()
        }
        let background = Theme.palette[note.color] ?? Theme.palette["yellow"]!
        window.backgroundColor = background; Theme.background(window.contentView?.layer, color: background)
        pinButton.image = Theme.symbol(note.pinned ? "pin.fill" : "pin")
        Theme.button(pinButton, active: note.pinned); pinButton.setAccessibilityLabel(note.pinned ? "取消列表置顶" : "列表置顶")
        if lastPinned != note.pinned { Theme.bounce(pinButton) }; lastPinned = note.pinned
        if store.state.deleteConflictIDs?.contains(id) == true {
            conflictLabel.stringValue = "删除未执行：另一端有新内容，已保留" + (note.conflict_of == nil ? "" : "（冲突副本）")
            noticeButton.title = "知道了"; noticeButton.isEnabled = true
            banner.isHidden = false; bannerHeight.constant = 38
        } else if let originalID = note.conflict_of {
            let original = store.state.notes[originalID]
            let available = original != nil && original?.deleted == false
            conflictLabel.stringValue = available ? "这是冲突副本，已保留两份内容" : "这是冲突副本，原便签已删除或不可用"
            noticeButton.title = "查看原件"; noticeButton.isEnabled = available
            banner.isHidden = false; bannerHeight.constant = 38
        } else { banner.isHidden = true; bannerHeight.constant = 0 }
        Theme.button(noticeButton)
        statusLabel.stringValue = store.lastSaved ? store.syncStatus(for: id) : "本地保存失败，请勿退出"
        statusLabel.textColor = !store.lastSaved ? .systemRed : (store.syncError == nil ? Theme.muted : .systemOrange)
        statusLabel.toolTip = store.saveError ?? (store.saveStatus + "；" + store.syncStatus(for: id) + "。已同步表示服务器已接收，另一台电脑须运行应用并联网。")
        syncButton.isEnabled = !store.syncing
        Theme.spin(syncButton, active: store.syncing && store.showSyncProgress)
    }
    func remap(to newID: String) {
        let oldID = id; id = newID
        if var base = compositionBase {
            base.id = newID; base.revision = store.state.notes[newID]?.revision ?? base.revision
            base.conflict_of = store.state.notes[newID]?.conflict_of ?? base.conflict_of; compositionBase = base
        }
        let defaults = UserDefaults.standard
        defaults.set(defaults.bool(forKey: "top-" + oldID), forKey: "top-" + newID)
        window.setFrameAutosaveName("note-" + newID); window.saveFrame(usingName: "note-" + newID)
    }
    func accept(_ receipts: [Receipt], sent: [Change]) {
        guard var base = compositionBase else { return }
        for receipt in receipts where receipt.status == "applied" && receipt.note_id == base.id {
            guard let submitted = sent.first(where: { $0.op_id == receipt.op_id }),
                  submitted.note_id == base.id, submitted.text == base.text,
                  submitted.color == base.color, submitted.pinned == base.pinned, submitted.deleted == base.deleted else { continue }
            base.revision = receipt.revision
        }
        compositionBase = base
    }
    @objc func returnToList() { showList?() }
    @objc func createNote() { newNote?() }
    @objc func syncNow() { saveCommittedText(); store.sync(force: true) }
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
    @objc func setPin() {
        guard var note = store.state.notes[id] else { return }; note.pinned.toggle()
        compositionBase?.pinned = note.pinned; store.update(note)
    }
    @objc func setColor(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? [String: String], let value = data["color"], var note = store.state.notes[id], note.color != value else { return }
        note.color = value; compositionBase?.color = value; store.update(note)
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
        let menu = NSMenu(); Theme.addColorPicker(to: menu, id: id, selected: note.color, target: self, action: #selector(setColor(_:)))
        menu.addItem(.separator())
        let top = menu.addItem(withTitle: "总在最前（仅本机窗口）", action: #selector(setTop), keyEquivalent: "")
        top.target = self; top.state = window.level == .floating ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "删除便签…", action: #selector(deleteNote), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.minY), in: moreButton)
    }
    @objc func deleteNote() {
        let alert = NSAlert(); alert.messageText = "删除这条便签？"; alert.informativeText = "删除会同步到另一台电脑。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, var note = self.store.state.notes[self.id] else { return }
            note.deleted = true; self.store.update(note); self.window.close()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        prepareForClose()
        guard store.lastSaved else {
            let alert = NSAlert(); alert.messageText = "本地保存失败，请先重试保存"
            alert.informativeText = store.saveError ?? "内容尚未安全保存。"; alert.runModal(); return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) { store.discardDraft(id); didClose?(id) }
    func windowDidBecomeKey(_ notification: Notification) { Theme.animate(changes: { self.tools.animator().alphaValue = 1 }) }
    func windowDidResignKey(_ notification: Notification) {
        Theme.animate(changes: { self.tools.animator().alphaValue = 0.55 }); didFinishEditing?()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    var store: Store!
    var window: NSWindow!
    let search = NSSearchField()
    let list = NotesListView()
    let status = NSTextField(labelWithString: "正在连接…")
    let empty = NSTextField(labelWithString: "还没有便签\n点右上角 +，记下第一件事")
    let emptyContainer = NSStackView()
    let sectionLabel = NSTextField(labelWithString: "全部便签")
    let filter = NSSegmentedControl(labels: ["全部", "置顶"], trackingMode: .selectOne, target: nil, action: nil)
    let connectionDot = NSView()
    let syncButton = NSButton()
    let noticeButton = NSButton()
    var rows: [Note] = []
    var cards: [String: NoteCardView] = [:]
    var selectedID: String?
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
                    func clear(_ view: NSView) { view.layer?.removeAllAnimations(); for child in view.subviews { clear(child) } }
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
        let redo = NSMenuItem(title: "重做", action: Selector("redo:"), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; editMenu.insertItem(redo, at: 1)
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
        let title = NSTextField(labelWithString: "我的便签"); title.font = .systemFont(ofSize: 13, weight: .semibold); title.textColor = Theme.ink
        let heading = NSStackView(views: [title]); heading.alignment = .centerY
        Theme.titlebar(window, view: heading, width: 96, side: .left)
        let add = Theme.iconButton("plus", label: "新建便签（⌘N）", target: self, action: #selector(newNote)); Theme.button(add, primary: true)
        let actions = NSStackView(views: [add]); Theme.titlebar(window, view: actions, width: 34, side: .right)
        let root = NSView(); window.contentView = root
        search.placeholderString = "搜索标题或内容（⌘F）"; search.delegate = self; search.font = .systemFont(ofSize: 13)
        search.controlSize = .regular; search.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(search)
        sectionLabel.font = .systemFont(ofSize: 11, weight: .medium); sectionLabel.textColor = Theme.muted
        filter.selectedSegment = 0; filter.segmentStyle = .rounded; filter.controlSize = .small
        filter.target = self; filter.action = #selector(filterChanged)
        let section = NSStackView(views: [sectionLabel, NSView(), filter]); section.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(section)
        let scroll = NotesScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        list.autoresizingMask = [.width]; scroll.documentView = list; root.addSubview(scroll)
        status.font = .systemFont(ofSize: 11); status.textColor = Theme.muted
        status.lineBreakMode = .byTruncatingTail; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        connectionDot.wantsLayer = true; connectionDot.layer?.cornerRadius = 3
        connectionDot.widthAnchor.constraint(equalToConstant: 6).isActive = true; connectionDot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        for (button, symbol, label, action) in [(syncButton, "arrow.triangle.2.circlepath", "立即同步（⌘R）", #selector(syncNow)), (noticeButton, "exclamationmark.bubble", "查看冲突提醒", #selector(openNextNotice))] {
            button.image = Theme.symbol(symbol); button.imagePosition = .imageOnly; button.target = self; button.action = action
            button.setAccessibilityLabel(label); button.toolTip = label; Theme.button(button)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true; button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let footer = NSStackView(views: [connectionDot, status, NSView(), noticeButton, syncButton]); footer.spacing = 8; footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        let emptyIcon = NSImageView(image: Theme.symbol("square.and.pencil", size: 32)!); emptyIcon.contentTintColor = Theme.muted
        empty.alignment = .center; empty.font = .systemFont(ofSize: 13); empty.textColor = Theme.muted; empty.maximumNumberOfLines = 3
        emptyContainer.orientation = .vertical; emptyContainer.alignment = .centerX; emptyContainer.spacing = 12
        emptyContainer.addArrangedSubview(emptyIcon); emptyContainer.addArrangedSubview(empty)
        emptyContainer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(emptyContainer)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), search.heightAnchor.constraint(equalToConstant: 28),
            section.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8), section.leadingAnchor.constraint(equalTo: search.leadingAnchor), section.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: search.leadingAnchor), footer.trailingAnchor.constraint(equalTo: search.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            emptyContainer.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), emptyContainer.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)])
    }
    func refresh(forceOrder: Bool = false) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var nextRows = store.visible.filter { (filter.selectedSegment == 0 || $0.pinned) && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }
        let editing = editors.values.contains { $0.window.isKeyWindow && $0.window.firstResponder === $0.editor }
        if editing && !forceOrder {
            let oldOrder = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            let newOrder = Dictionary(uniqueKeysWithValues: nextRows.enumerated().map { ($0.element.id, $0.offset + rows.count) })
            nextRows.sort { (oldOrder[$0.id] ?? newOrder[$0.id]!) < (oldOrder[$1.id] ?? newOrder[$1.id]!) }
        }
        let changedOrder = rows.map(\.id) != nextRows.map(\.id); rows = nextRows
        for note in rows {
            if cards[note.id] == nil { cards[note.id] = makeCard(note) }
            cards[note.id]?.update(note, pending: store.state.pending[note.id] != nil, deleteConflict: store.state.deleteConflictIDs?.contains(note.id) == true)
        }
        if changedOrder {
            let previousSelection = selectedID
            let hadFocus = window.firstResponder is NoteCardView
            list.setCards(rows.compactMap { cards[$0.id] }, animated: !checkingLayout)
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
        sectionLabel.stringValue = "\(filter.selectedSegment == 0 ? "全部便签" : "置顶便签") · \(rows.count)"
        emptyContainer.isHidden = !rows.isEmpty
        empty.stringValue = !query.isEmpty ? "没有找到匹配的便签\n换个关键词试试" : (filter.selectedSegment == 1 ? "还没有置顶便签\n右键便签或点窗口的图钉" : "记下第一件小事\n点右上角 + 开始")
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
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows.isEmpty else { return }
        let target = index + delta
        guard target >= 0, target < rows.count else { return }
        let next = rows[target].id
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
        note.pinned.toggle(); store.update(note)
    }
    @objc func colorFromMenu(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? [String: String], let id = data["id"], let color = data["color"], var note = store.state.notes[id], !note.deleted, note.color != color else { return }
        note.color = color; store.update(note)
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
    func controlTextDidChange(_ notification: Notification) { refresh(forceOrder: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search, commandSelector == #selector(NSResponder.moveDown(_:)), let id = rows.first?.id, let card = cards[id] else { return false }
        window.makeFirstResponder(card); select(id); return true
    }
    @objc func filterChanged() { refresh(forceOrder: true) }
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
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "SongNote", .applicationVersion: "1.1.0", .credits: NSAttributedString(string: "Windows / Mac 私人桌面便签\n自动保存 · 离线编辑 · 双向同步")]) }
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
