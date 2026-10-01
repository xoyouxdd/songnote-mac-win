import AppKit

let palette: [String: NSColor] = [
    "yellow": NSColor(calibratedRed: 1, green: 0.96, blue: 0.79, alpha: 1),
    "green": NSColor(calibratedRed: 0.88, green: 0.94, blue: 0.84, alpha: 1),
    "blue": NSColor(calibratedRed: 0.86, green: 0.92, blue: 0.98, alpha: 1),
    "pink": NSColor(calibratedRed: 0.98, green: 0.88, blue: 0.91, alpha: 1),
    "purple": NSColor(calibratedRed: 0.93, green: 0.88, blue: 0.98, alpha: 1),
    "gray": NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.91, alpha: 1)]
let colorNames = ["yellow": "黄色", "green": "绿色", "blue": "蓝色", "pink": "粉色", "purple": "紫色", "gray": "灰色"]
let colorOrder = ["yellow", "green", "blue", "pink", "purple", "gray"]

@MainActor final class NoteWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    var id: String
    let store: Store
    let window: NSWindow
    let editor = NSTextView()
    let color = NSPopUpButton()
    let pin = NSButton(checkboxWithTitle: "列表置顶", target: nil, action: nil)
    let saveLabel = NSTextField(labelWithString: "已保存到本机")
    let syncLabel = NSTextField(labelWithString: "正在连接…")
    let countLabel = NSTextField(labelWithString: "")
    let syncButton = NSButton(title: "立即同步", target: nil, action: nil)
    let topButton = NSButton(title: "窗口置顶", target: nil, action: nil)
    var showList: (() -> Void)?
    var newNote: (() -> Void)?
    var didClose: ((String) -> Void)?
    init(note: Note, store: Store, present: Bool = true) {
        id = note.id; self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.delegate = self; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 280)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        if present {
            window.setFrameAutosaveName("note-" + id)
            if !window.setFrameUsingName("note-" + id) { window.center() }
        }
        let root = NSView(); window.contentView = root
        let listButton = NSButton(title: "便签列表", target: self, action: #selector(returnToList))
        listButton.image = Theme.symbol("list.bullet"); listButton.imagePosition = .imageLeading
        Theme.button(listButton)
        let addButton = NSButton(title: "＋新建", target: self, action: #selector(createNote))
        Theme.button(addButton, primary: true)
        countLabel.font = .systemFont(ofSize: 11); countLabel.textColor = Theme.muted
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        let navigation = NSStackView(views: [listButton, addButton, NSView(), countLabel])
        navigation.spacing = 8; navigation.translatesAutoresizingMaskIntoConstraints = false
        for (button, width) in [(listButton, 96.0), (addButton, 70.0)] {
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        root.addSubview(navigation)
        color.addItems(withTitles: colorOrder.map { colorNames[$0]! })
        color.target = self; color.action = #selector(setColor)
        color.isBordered = false; color.font = .systemFont(ofSize: 11, weight: .medium)
        color.contentTintColor = Theme.ink
        pin.target = self; pin.action = #selector(setPin)
        pin.setButtonType(.pushOnPushOff); pin.image = Theme.symbol("pin"); pin.imagePosition = .imageLeading
        topButton.target = self; topButton.action = #selector(setTop)
        topButton.setButtonType(.pushOnPushOff); topButton.image = Theme.symbol("rectangle.on.rectangle"); topButton.imagePosition = .imageLeading
        topButton.state = UserDefaults.standard.bool(forKey: "top-" + id) ? .on : .off
        Theme.button(pin); Theme.button(topButton, active: topButton.state == .on)
        window.level = topButton.state == .on ? .floating : .normal
        let remove = NSButton(image: Theme.symbol("trash")!, target: self, action: #selector(deleteNote))
        remove.setAccessibilityLabel("删除便签"); remove.toolTip = "删除便签"; Theme.button(remove)
        let toolbar = NSStackView(views: [color, pin, topButton, NSView(), remove]); toolbar.spacing = 6
        for (button, width) in [(pin, 86.0), (topButton, 86.0), (remove, 30.0)] {
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        toolbar.orientation = .horizontal; toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        editor.isRichText = false; editor.allowsUndo = true; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = NSFont.systemFont(ofSize: 16); editor.textColor = Theme.ink
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        editor.defaultParagraphStyle = paragraph
        editor.textContainerInset = NSSize(width: 18, height: 18)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.minSize = NSSize(width: 0, height: 0); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self; scroll.documentView = editor; root.addSubview(scroll)
        for label in [saveLabel, syncLabel] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = NSStackView(views: [saveLabel, syncLabel]); labels.orientation = .vertical
        labels.alignment = .leading; labels.spacing = 3
        syncButton.target = self; syncButton.action = #selector(syncNow)
        syncButton.image = Theme.symbol("arrow.triangle.2.circlepath", size: 12); syncButton.imagePosition = .imageLeading
        Theme.button(syncButton)
        syncButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        syncButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        syncButton.setContentHuggingPriority(.required, for: .horizontal)
        syncButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [labels, NSView(), syncButton]); footer.spacing = 12
        footer.alignment = .centerY; footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            navigation.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            navigation.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            toolbar.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)])
        refresh()
        if present { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor) }
    }
    func refresh() {
        guard let note = store.state.notes[id] else { return }
        if note.deleted { window.close(); return }
        window.title = String(note.title.prefix(40)) + (note.conflict_of == nil ? "" : " · 冲突副本")
        if editor.string != note.text {
            let selected = editor.selectedRange()
            editor.string = note.text
            editor.setSelectedRange(NSRange(location: min(selected.location, (note.text as NSString).length), length: 0))
            editor.undoManager?.removeAllActions()
        }
        let background = palette[note.color] ?? palette["yellow"]!
        window.backgroundColor = background; editor.backgroundColor = background
        window.appearance = NSAppearance(named: .aqua)
        color.selectItem(at: colorOrder.firstIndex(of: note.color) ?? 0)
        pin.state = note.pinned ? .on : .off
        Theme.button(pin, active: note.pinned)
        countLabel.stringValue = "\(store.visible.count) 条便签"
        saveLabel.stringValue = store.saveStatus
        saveLabel.textColor = store.lastSaved ? .secondaryLabelColor : .systemRed
        saveLabel.toolTip = store.saveError ?? "每次编辑自动保存到本机，关闭窗口不会删除内容。"
        syncLabel.stringValue = store.syncStatus(for: id)
        syncLabel.toolTip = "已同步表示服务器已确认接收。另一台电脑打开应用联网后自动获取。"
        syncLabel.textColor = store.syncError == nil ? .secondaryLabelColor : .systemOrange
        syncButton.isEnabled = !store.syncing
    }
    @objc func returnToList() { showList?() }
    @objc func createNote() { newNote?() }
    @objc func syncNow() { store.sync(force: true) }
    func textDidChange(_ notification: Notification) {
        guard var note = store.state.notes[id] else { return }
        if editor.string.utf16.count > 100000 {
            editor.string = note.text; NSSound.beep(); return
        }
        note.text = editor.string; store.update(note)
    }
    @objc func setColor() { guard var note = store.state.notes[id] else { return }; note.color = colorOrder[color.indexOfSelectedItem]; store.update(note) }
    @objc func setPin() { guard var note = store.state.notes[id] else { return }; note.pinned = pin.state == .on; store.update(note) }
    @objc func setTop(_ sender: NSButton) {
        window.level = sender.state == .on ? .floating : .normal
        Theme.button(sender, active: sender.state == .on)
        UserDefaults.standard.set(sender.state == .on, forKey: "top-" + id)
    }
    @objc func deleteNote() {
        let alert = NSAlert(); alert.messageText = "删除这条便签？"; alert.informativeText = "删除会同步到另一台电脑。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, var note = self.store.state.notes[self.id] else { return }
            note.deleted = true; self.store.update(note); self.window.close()
        }
    }
    func windowWillClose(_ notification: Notification) { didClose?(id) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSSearchFieldDelegate {
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
    var rows: [Note] = []
    var editors: [String: NoteWindow] = [:]
    var statusItem: NSStatusItem!
    var quitting = false
    var checkingLayout = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { store = try Store() }
        catch {
            let alert = NSAlert(); alert.messageText = "无法读取便签数据或同步配置"
            alert.informativeText = "原文件已保留，未创建空数据覆盖。\n\(error.localizedDescription)"
            alert.runModal(); NSApp.terminate(nil); return
        }
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        buildMenu(); buildList()
        store.onChange = { [weak self] in self?.refresh() }
        store.onRemap = { [weak self] mappings in
            guard let self else { return }
            for (old, new) in mappings {
                if let editor = self.editors.removeValue(forKey: old) { editor.id = new; self.editors[new] = editor }
            }
            self.saveOpenWindows()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "SongNote 便签")
        let menu = NSMenu(); menu.addItem(withTitle: "便签列表", action: #selector(showList), keyEquivalent: "")
        menu.addItem(withTitle: "新建便签", action: #selector(newNote), keyEquivalent: "")
        menu.addItem(withTitle: "立即同步", action: #selector(syncNow), keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: "退出 SongNote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
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
        for (name, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
        }
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; editMenu.insertItem(redo, at: 1)
        let windowItem = NSMenuItem(); windowItem.title = "窗口"; let windowMenu = NSMenu(title: "窗口"); windowItem.submenu = windowMenu; main.addItem(windowItem)
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu; NSApp.mainMenu = main
    }
    func buildList() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 710), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SongNote · 便签列表"; window.minSize = NSSize(width: 400, height: 440)
        window.backgroundColor = Theme.paper; window.appearance = NSAppearance(named: .aqua)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        if !checkingLayout {
            window.setFrameAutosaveName("note-list")
            if !window.setFrameUsingName("note-list") { window.center() }
        }
        let root = NSView(); window.contentView = root
        let logo = NSImageView()
        logo.image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.widthAnchor.constraint(equalToConstant: 48).isActive = true; logo.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let title = NSTextField(labelWithString: "我的便签"); title.font = .systemFont(ofSize: 25, weight: .semibold); title.textColor = Theme.ink
        let subtitle = NSTextField(labelWithString: "SongNote  ·  跨设备同步"); subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = Theme.muted
        let identity = NSStackView(views: [title, subtitle]); identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 4
        let add = NSButton(title: "新建便签", target: self, action: #selector(newNote))
        add.image = Theme.symbol("plus", size: 12); add.imagePosition = .imageLeading; Theme.button(add, primary: true)
        add.widthAnchor.constraint(equalToConstant: 100).isActive = true; add.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let head = NSStackView(views: [logo, identity, NSView(), add]); head.spacing = 12; head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(head)
        search.placeholderString = "搜索标题或内容"; search.delegate = self; search.font = .systemFont(ofSize: 13)
        search.controlSize = .large; search.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(search)
        sectionLabel.font = .systemFont(ofSize: 12, weight: .medium); sectionLabel.textColor = Theme.muted
        filter.selectedSegment = 0; filter.segmentStyle = .rounded; filter.controlSize = .small
        filter.target = self; filter.action = #selector(filterChanged)
        let section = NSStackView(views: [sectionLabel, NSView(), filter]); section.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(section)
        let scroll = NotesScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        list.autoresizingMask = [.width]
        scroll.documentView = list; root.addSubview(scroll)
        status.font = .systemFont(ofSize: 11); status.textColor = Theme.muted
        status.lineBreakMode = .byTruncatingTail; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        connectionDot.wantsLayer = true; connectionDot.layer?.cornerRadius = 3
        connectionDot.widthAnchor.constraint(equalToConstant: 6).isActive = true; connectionDot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let refresh = NSButton(image: Theme.symbol("arrow.triangle.2.circlepath")!, target: self, action: #selector(syncNow))
        refresh.setAccessibilityLabel("立即同步"); refresh.toolTip = "立即同步（⌘R）"; Theme.button(refresh)
        refresh.widthAnchor.constraint(equalToConstant: 30).isActive = true; refresh.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let footer = NSStackView(views: [connectionDot, status, NSView(), refresh]); footer.spacing = 9; footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
        let emptyIcon = NSImageView(image: Theme.symbol("square.and.pencil", size: 38)!)
        emptyIcon.contentTintColor = Theme.muted.withAlphaComponent(0.5)
        empty.alignment = .center; empty.font = .systemFont(ofSize: 13); empty.textColor = Theme.muted; empty.maximumNumberOfLines = 3
        emptyContainer.orientation = .vertical; emptyContainer.alignment = .centerX; emptyContainer.spacing = 18
        emptyContainer.addArrangedSubview(emptyIcon); emptyContainer.addArrangedSubview(empty)
        emptyContainer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(emptyContainer)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            search.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 22), search.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: head.trailingAnchor), search.heightAnchor.constraint(equalToConstant: 34),
            section.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 19), section.leadingAnchor.constraint(equalTo: head.leadingAnchor), section.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 14), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            footer.leadingAnchor.constraint(equalTo: head.leadingAnchor), footer.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            emptyContainer.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), emptyContainer.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)])
    }
    func refresh() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextRows = store.visible.filter { (filter.selectedSegment == 0 || $0.pinned) && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }
        if rows != nextRows { rows = nextRows; list.setCards(rows.map(makeCard)) }
        status.stringValue = store.status; status.toolTip = store.status
        connectionDot.layer?.backgroundColor = (!store.lastSaved ? NSColor.systemRed : (store.syncError == nil ? Theme.green : NSColor.systemOrange)).cgColor
        sectionLabel.stringValue = "\(filter.selectedSegment == 0 ? "全部便签" : "置顶便签")  ·  \(rows.count)"
        emptyContainer.isHidden = !rows.isEmpty
        empty.stringValue = !query.isEmpty ? "没有找到匹配的便签\n换个关键词试试" : (filter.selectedSegment == 1 ? "还没有置顶便签\n打开一条便签，点「列表置顶」" : "记下第一件小事\n点右上角「新建便签」开始")
        for editor in Array(editors.values) { editor.refresh() }
    }
    func makeCard(_ note: Note) -> NoteCardView {
        let color = palette[note.color] ?? palette["yellow"]!
        let cell = NoteCardView(); cell.wantsLayer = true; cell.accent = color.blended(withFraction: 0.28, of: Theme.ink)!
        cell.layer?.backgroundColor = color.blended(withFraction: 0.45, of: .white)?.cgColor
        cell.layer?.cornerRadius = 12; cell.layer?.borderWidth = 1; cell.layer?.borderColor = cell.accent.withAlphaComponent(0.14).cgColor
        cell.layer?.masksToBounds = true
        cell.onOpen = { [weak self] in
            guard let self, let current = self.store.state.notes[note.id], !current.deleted else { return }
            self.open(current)
        }
        cell.setAccessibilityElement(true); cell.setAccessibilityRole(.button)
        cell.setAccessibilityLabel(note.title + (note.pinned ? "，已置顶" : ""))
        cell.setAccessibilityHelp("打开这条便签")
        let stripe = NSView(); stripe.wantsLayer = true; stripe.layer?.backgroundColor = cell.accent.withAlphaComponent(0.5).cgColor
        stripe.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stripe)
        let title = NSTextField(labelWithString: String(note.title.prefix(90)))
        title.font = .systemFont(ofSize: 17, weight: .semibold); title.textColor = Theme.ink; title.lineBreakMode = .byTruncatingTail
        let preview = NSTextField(wrappingLabelWithString: String(note.text.dropFirst(note.title.count).trimmingCharacters(in: .whitespacesAndNewlines).prefix(130)))
        preview.font = .systemFont(ofSize: 13); preview.textColor = Theme.muted; preview.maximumNumberOfLines = 2
        let hint = NSTextField(labelWithString: (note.conflict_of != nil ? "冲突副本  ·  " : (note.pinned ? "置顶  ·  " : "")) + Theme.timestamp(note.updated_at) + (store.state.pending[note.id] == nil ? "" : "  ·  待同步"))
        hint.font = .systemFont(ofSize: 10); hint.textColor = Theme.muted
        hint.lineBreakMode = .byTruncatingTail
        let chevron = NSImageView(image: Theme.symbol("chevron.right", size: 11)!); chevron.contentTintColor = Theme.muted.withAlphaComponent(0.6)
        chevron.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(chevron)
        for view in [title, preview, hint] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: cell.leadingAnchor), stripe.widthAnchor.constraint(equalToConstant: 4), stripe.topAnchor.constraint(equalTo: cell.topAnchor), stripe.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 17), title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 19), title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -32),
            preview.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 9), preview.leadingAnchor.constraint(equalTo: title.leadingAnchor), preview.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -15), hint.leadingAnchor.constraint(equalTo: title.leadingAnchor), hint.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            chevron.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16), chevron.centerYAnchor.constraint(equalTo: title.centerYAnchor)])
        return cell
    }
    func controlTextDidChange(_ notification: Notification) { refresh() }
    @objc func filterChanged() { refresh() }
    func open(_ note: Note) {
        if let existing = editors[note.id] { existing.window.makeKeyAndOrderFront(nil); return }
        let editor = NoteWindow(note: note, store: store)
        editor.showList = { [weak self] in self?.showList() }
        editor.newNote = { [weak self] in self?.newNote() }
        editor.didClose = { [weak self] id in self?.editors.removeValue(forKey: id); self?.saveOpenWindows() }
        editors[note.id] = editor; saveOpenWindows()
    }
    func saveOpenWindows() { if !quitting { UserDefaults.standard.set(Array(editors.keys), forKey: "open-notes") } }
    @objc func newNote() { open(store.create()); NSApp.activate(ignoringOtherApps: true) }
    @objc func showList() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func syncNow() { store.sync(force: true) }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "SongNote", .applicationVersion: "1.1.0", .credits: NSAttributedString(string: "Windows / Mac 私人桌面便签\n自动保存 · 离线编辑 · 双向同步")]) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showList(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil else { return .terminateNow }
        if !store.persist() {
            let alert = NSAlert(); alert.messageText = "本地保存失败"; alert.informativeText = "退出可能丢失尚未保存的内容。"
            alert.addButton(withTitle: "继续使用"); alert.addButton(withTitle: "仍然退出")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
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
        application.setActivationPolicy(.regular); application.run()
        withExtendedLifetime(delegate) {}
    }
}
