import AppKit

@MainActor final class Store {
    let directory: URL
    let file: URL
    let configuration: Configuration
    var state: LocalState
    var onChange: (() -> Void)?
    var onRemap: (([String: String]) -> Void)?
    var status = "正在连接…"
    var syncing = false
    var timer: Timer?
    var debounce: Timer?
    var retryAfter = Date.distantPast
    var failures = 0
    var lastSaved = true
    var saveError: String?
    var syncError: String?
    var lastSyncAt: Date?
    var showSyncProgress = false
    init() throws {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SongNote")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent("state.json")
        let configFile = directory.appendingPathComponent("client-config.json")
        if !FileManager.default.fileExists(atPath: configFile.path), let resource = Bundle.main.url(forResource: "client-config", withExtension: "json") {
            try FileManager.default.copyItem(at: resource, to: configFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        }
        configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configFile))
        guard let url = URL(string: configuration.base_url), url.scheme == "https", configuration.token.count >= 32 else {
            throw NSError(domain: "SongNote", code: 1, userInfo: [NSLocalizedDescriptionKey: "同步配置无效"])
        }
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: file))
        } else { state = LocalState() }
    }
    var visible: [Note] {
        state.notes.values.filter { !$0.deleted }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updated_at > $1.updated_at
        }
    }
    @discardableResult func persist() -> Bool {
        do {
            let data = try JSONEncoder().encode(state)
            // A previous readable snapshot is available if the latest local file is damaged.
            if FileManager.default.fileExists(atPath: file.path) {
                let backup = directory.appendingPathComponent("state.previous.json")
                try Data(contentsOf: file).write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            lastSaved = true; saveError = nil; return true
        } catch {
            lastSaved = false; saveError = error.localizedDescription
            status = "本地保存失败，请勿退出：\(error.localizedDescription)"
            onChange?(); return false
        }
    }
    func create() -> Note { let note = Note.blank(); update(note); return note }
    var saveStatus: String { lastSaved ? "已保存到本机" : "本地保存失败，请勿退出" }
    func syncStatus(for id: String) -> String {
        guard lastSaved else { return "同步已暂停，等待本地保存" }
        if syncing && showSyncProgress { return "正在同步…" }
        if let syncError {
            if syncError == "离线" { return state.pending[id] == nil ? "离线 · 等待连接" : "离线 · 待同步" }
            return syncError
        }
        if state.pending[id] != nil { return "等待同步" }
        guard let lastSyncAt else { return "正在连接…" }
        let time = DateFormatter.localizedString(from: lastSyncAt, dateStyle: .none, timeStyle: .short)
        return "已同步 · \(time)"
    }
    func update(_ note: Note) {
        var updated = note
        updated.updated_at = ISO8601DateFormatter().string(from: Date())
        state.notes[note.id] = updated
        state.pending[note.id] = Change(updated)
        if persist() { status = syncError == "离线" ? "已保存到本机 · 离线待同步" : "已保存到本机 · 等待同步" }
        onChange?()
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        sync()
    }
    func sync(force: Bool = false) {
        if force && !lastSaved && !persist() { return }
        guard !syncing, lastSaved, force || Date() >= retryAfter else { return }
        syncing = true
        let sent = Array(state.pending.values).sorted { $0.note_id < $1.note_id }.prefix(4)
        let changes = Array(sent)
        showSyncProgress = force || !changes.isEmpty
        if showSyncProgress { status = "正在同步…"; onChange?() }
        var request = URLRequest(url: URL(string: configuration.base_url + "/v1/sync")!)
        request.httpMethod = "POST"; request.timeoutInterval = 12
        request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(SyncRequest(device_id: state.device_id, changes: changes))
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.syncing = false
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data,
                      let result = try? JSONDecoder().decode(SyncResponse.self, from: data), result.protocol == 1 else {
                    self.failures += 1
                    self.retryAfter = Date().addingTimeInterval(min(30, pow(2, Double(min(self.failures, 5)))))
                    let code = (response as? HTTPURLResponse)?.statusCode
                    if code == 401 { self.syncError = "同步密钥无效" }
                    else if let code { self.syncError = "同步失败（\(code)）· 稍后重试" }
                    else if error == nil { self.syncError = "同步响应无效 · 稍后重试" }
                    else { self.syncError = "离线" }
                    self.status = "\(self.syncError!) · 内容已保存在本机"
                    self.onChange?(); return
                }
                self.failures = 0; self.retryAfter = .distantPast
                self.syncError = nil; self.lastSyncAt = Date()
                let remapped = self.state.merge(result, sent: changes)
                let hasCopy = result.results.contains { $0.status == "conflict_copy" }
                let hasDeleteConflict = result.results.contains { $0.status == "delete_conflict" }
                if self.persist() {
                    if hasCopy { self.status = "检测到冲突 · 已保留两份内容" }
                    else if hasDeleteConflict { self.status = "删除未执行 · 已保留另一端的新内容" }
                    else { self.status = self.state.pending.isEmpty ? "已同步 · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))" : "本机有新修改 · 等待同步" }
                }
                self.onRemap?(remapped); self.onChange?()
            }
        }.resume()
    }
}
