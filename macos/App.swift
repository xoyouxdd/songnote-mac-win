import AppKit
import ServiceManagement

let colorNames = ["yellow": "黄色", "green": "绿色", "blue": "蓝色", "pink": "粉色", "purple": "紫色", "gray": "灰色"]
let colorOrder = ["yellow", "green", "blue", "pink", "purple", "gray"]

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
    let undoButton = NSButton(title: "撤销", target: nil, action: nil)
    let trashButton = ToolButton()
    let recentMenu = NSMenu(title: "最近删除")
    var compareWindows: [String: CompareWindow] = [:]
    var undoExpiry: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        while store == nil {
            do { store = try Store() }
            catch let error as NSError where error.domain == "SongNote" && error.code == Store.missingConfiguration {
                // First launch: choose the private client-config.json once; it is copied with 0600 permissions.
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert(); alert.messageText = "选择同步配置"
                alert.informativeText = "SongNote 需要 client-config.json（服务器地址和私有密钥）。它会保存在本机数据目录，只有当前用户可读，不会打包进应用。"
                alert.addButton(withTitle: "选择文件…"); alert.addButton(withTitle: "退出")
                guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.message = "选择 client-config.json"
                guard panel.runModal() == .OK, let url = panel.url else { continue }
                do { try Store.installConfiguration(from: url) }
                catch { let failed = NSAlert(); failed.messageText = "配置文件无效"; failed.informativeText = error.localizedDescription; failed.runModal() }
            } catch {
                let alert = NSAlert(); alert.messageText = "无法读取便签数据或同步配置"
                alert.informativeText = "原文件已保留，未创建空数据覆盖。\n\(error.localizedDescription)"
                alert.runModal(); NSApp.terminate(nil); return
            }
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
        if !GlobalHotKey.register({ [weak self] in self?.newNote() }) { NSLog("SongNote: ⌥⌘N is used by another app") }
        store.remote.start()
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
        let recent = noteMenu.addItem(withTitle: "最近删除", action: nil, keyEquivalent: ""); recentMenu.delegate = self; recent.submenu = recentMenu
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
        undoButton.target = self; undoButton.action = #selector(undoDelete); Theme.button(undoButton); Theme.padded(undoButton, height: 22); undoButton.isHidden = true
        undoButton.setAccessibilityLabel("撤销删除")
        trashButton.image = Theme.symbol("trash"); trashButton.imagePosition = .imageOnly; trashButton.target = self; trashButton.action = #selector(showRecentlyDeleted)
        trashButton.setAccessibilityLabel("最近删除"); trashButton.toolTip = "最近删除（7 天内可恢复）"; Theme.button(trashButton); trashButton.contentTintColor = Theme.muted
        trashButton.widthAnchor.constraint(equalToConstant: 22).isActive = true; trashButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let footer = NSStackView(views: [connectionDot, status, NSView(), undoButton, trashButton, noticeButton, syncButton]); footer.spacing = 8; footer.alignment = .centerY
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
        for note in nextRows { nextKeys[note.id] = (frozen ? groupKeys[note.id] : nil) ?? (note.pinned ? "已固定" : Theme.dayGroup(note.updated_at)) }
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
        let remote = store.remote
        let undoable = store.lastDeleted.flatMap { Date().timeIntervalSince($0.at) < 8 ? store.state.notes[$0.id] : nil }.flatMap { $0.deleted ? $0 : nil }
        let base = !store.lastSaved ? Texts.saveFailed + "：" + (store.saveError ?? "") : remote.status
        status.stringValue = undoable.map { "已删除「" + String($0.title.prefix(16)) + "」" } ?? (base + (notices > 0 ? " · \(notices) 条冲突提醒" : ""))
        status.toolTip = status.stringValue; undoButton.isHidden = undoable == nil
        if undoable != nil, undoExpiry == nil, let deleted = store.lastDeleted {
            // Hide the undo offer when its 8 seconds run out, wherever the delete came from.
            undoExpiry = Timer.scheduledTimer(withTimeInterval: max(0.1, 8.1 - Date().timeIntervalSince(deleted.at)), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.undoExpiry = nil; self?.refresh() }
            }
        }
        status.textColor = !store.lastSaved ? .systemRed : (remote.syncError == nil ? Theme.muted : .systemOrange)
        noticeButton.isHidden = notices == 0; syncButton.isEnabled = !remote.syncing; trashButton.isHidden = store.recentlyDeleted.isEmpty
        connectionDot.layer?.backgroundColor = (!store.lastSaved ? NSColor.systemRed : (remote.syncError == nil ? Theme.green : NSColor.systemOrange)).cgColor
        Theme.spin(syncButton, active: remote.syncing && remote.showSyncProgress)
        if lastSyncAt != remote.lastSyncAt, store.lastSaved, remote.showSyncProgress { Theme.pulse(connectionDot) }; lastSyncAt = remote.lastSyncAt
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
        let pin = menu.addItem(withTitle: note.pinned ? "取消固定" : "固定在列表顶部", action: #selector(pinFromMenu(_:)), keyEquivalent: "")
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
        let alert = NSAlert(); alert.messageText = "删除“\(String(note.title.prefix(24)))”？"; alert.informativeText = "删除会同步到另一台电脑，7 天内可在「最近删除」中恢复。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.store.delete(id); self.refresh(forceOrder: true)
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
        editor.compare = { [weak self] id in self?.compare(id) }
        editor.didFinishEditing = { [weak self] in self?.refresh(forceOrder: true) }
        editor.didClose = { [weak self] id in
            guard let self else { return }; self.editors.removeValue(forKey: id); self.saveOpenWindows(); self.refresh(forceOrder: true)
        }
        editors[note.id] = editor; saveOpenWindows()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !checkingLayout else { return }; menu.removeAllItems()
        if menu === recentMenu { fillRecentlyDeleted(menu); return }
        menu.addItem(withTitle: "便签列表", action: #selector(showList), keyEquivalent: "").target = self
        let create = menu.addItem(withTitle: "新建便签", action: #selector(newNote), keyEquivalent: "n"); create.target = self
        create.keyEquivalentModifierMask = [.command, .option]; create.toolTip = "全局快捷键 ⌥⌘N，在任何应用中都可新建"
        menu.addItem(withTitle: "立即同步", action: #selector(syncNow), keyEquivalent: "").target = self
        if !store.recentlyDeleted.isEmpty {
            let recent = menu.addItem(withTitle: "最近删除", action: nil, keyEquivalent: ""); let sub = NSMenu(); fillRecentlyDeleted(sub); recent.submenu = sub
        }
        let pinned = store.visible.filter(\.pinned)
        if !pinned.isEmpty {
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "已固定的便签", action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
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
    func fillRecentlyDeleted(_ menu: NSMenu) {
        let notes = store.recentlyDeleted
        if notes.isEmpty { let empty = menu.addItem(withTitle: "没有最近删除的便签", action: nil, keyEquivalent: ""); empty.isEnabled = false; return }
        let heading = menu.addItem(withTitle: "点击恢复（保留 7 天）", action: nil, keyEquivalent: ""); heading.isEnabled = false
        for note in notes.prefix(30) {
            let item = menu.addItem(withTitle: String(note.title.prefix(32)) + "  ·  " + Theme.timestamp(note.updated_at), action: #selector(restoreNote(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = note.id; item.image = Theme.dotImage(note.color)
        }
    }
    @objc func showRecentlyDeleted() {
        let menu = NSMenu(); fillRecentlyDeleted(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: trashButton.bounds.maxY + 4), in: trashButton)
    }
    @objc func restoreNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.restore(id); openID(id)
    }
    @objc func undoDelete() {
        guard let id = store.lastDeleted?.id else { return }
        store.restore(id); refresh(forceOrder: true)
    }
    func compare(_ copyID: String) {
        if let existing = compareWindows[copyID] { existing.window.makeKeyAndOrderFront(nil); return }
        guard let copy = store.state.notes[copyID], let originalID = copy.conflict_of, store.state.notes[originalID]?.deleted == false else { return }
        let view = CompareWindow(store: store, copyID: copyID)
        view.onClose = { [weak self] in self?.compareWindows.removeValue(forKey: copyID) }
        view.onOpenOriginal = { [weak self] in self?.openID(originalID) }
        compareWindows[copyID] = view; view.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
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
    @objc func syncNow() { for editor in Array(editors.values) { editor.saveCommittedText() }; store.remote.sync(force: true) }
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
