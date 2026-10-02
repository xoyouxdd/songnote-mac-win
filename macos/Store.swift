import AppKit

@MainActor final class Store {
    let directory: URL
    let file: URL
    let configuration: Configuration
    var state: LocalState
    var onChange: (() -> Void)?
    var onRemap: (([String: String]) -> Void)?
    var onAccepted: (([Receipt], [Change]) -> Void)?
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
    lazy var files = AttachmentFiles(directory: directory, configuration: configuration)
    var uploadTask: Task<Void, Never>?
    var uploadedHashes: Set<String> = []
    var attachmentSupported = false
    var attachmentStatus: String?
    var fileRetryAfter = Date.distantPast
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
        guard state.notes.values.allSatisfy({ Attachment.validList($0.attachments) }),
              state.pending.values.allSatisfy({ Attachment.validList($0.attachments) }),
              (state.frozen ?? []).count <= 4, (state.frozen ?? []).allSatisfy({ Attachment.validList($0.attachments) }) else {
            throw AttachmentFiles.failure("本机附件信息无效，原数据已保留。")
        }
    }
    // Layout checks use deterministic fixtures without reading private notes,
    // creating files, or connecting to the production service.
    init(previewState: LocalState) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SongNote-layout-preview")
        file = directory.appendingPathComponent("state.json")
        configuration = Configuration(base_url: "https://example.invalid", token: String(repeating: "x", count: 32))
        state = previewState
    }
    var visible: [Note] {
        state.notes.values.filter { !$0.deleted }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.updated_at != $1.updated_at { return $0.updated_at > $1.updated_at }
            return $0.id < $1.id
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
    func create() -> Note {
        let note = state.createDraft()
        if persist() { status = "空白草稿已保存到本机" }
        onChange?(); return note
    }
    func discardDraft(_ id: String) {
        if state.discardDraft(id) { _ = persist(); onChange?() }
    }
    func acknowledgeDeleteConflict(_ id: String) {
        state.deleteConflictIDs?.remove(id); _ = persist(); onChange?()
    }
    var saveStatus: String { lastSaved ? "已保存到本机" : "本地保存失败，请勿退出" }
    func syncStatus(for id: String) -> String {
        guard lastSaved else { return "同步已暂停，等待本地保存" }
        if state.draftIDs?.contains(id) == true { return "本机草稿 · 关闭空白窗口自动丢弃" }
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
        state.draftIDs?.remove(note.id)
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
    func ready(_ change: Change) -> Bool {
        change.attachments == nil || (attachmentSupported && (change.attachments ?? []).allSatisfy { uploadedHashes.contains($0.sha256) })
    }
    func beginUploads() {
        guard uploadTask == nil, Date() >= fileRetryAfter else { return }
        let pending = ((state.frozen ?? []) + Array(state.pending.values)).filter { !ready($0) }
        guard !pending.isEmpty else { return }
        uploadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.attachmentStatus = "正在准备附件…"; self.onChange?()
                if !self.attachmentSupported { try await self.files.checkSupport(); self.attachmentSupported = true }
                var firstError: String?
                for value in pending.flatMap({ $0.attachments ?? [] }) {
                    if self.uploadedHashes.contains(value.sha256) { continue }
                    self.attachmentStatus = "正在上传 · " + value.name; self.onChange?()
                    do { try await self.files.upload(value); self.uploadedHashes.insert(value.sha256) }
                    catch { if firstError == nil { firstError = error.localizedDescription } }
                }
                self.attachmentStatus = firstError
                self.fileRetryAfter = firstError == nil ? .distantPast : Date().addingTimeInterval(15)
            } catch {
                self.attachmentStatus = error.localizedDescription
                self.fileRetryAfter = Date().addingTimeInterval(15)
            }
            self.uploadTask = nil; self.onChange?(); self.sync()
        }
    }
    func sync(force: Bool = false) {
        if force && !lastSaved && !persist() { return }
        guard !syncing, lastSaved, force || Date() >= retryAfter else { return }
        if force { fileRetryAfter = .distantPast }
        beginUploads()
        if (state.frozen ?? []).contains(where: { !ready($0) }) { return }
        if (state.frozen ?? []).isEmpty {
            var batch: [Change] = []
            for change in state.pending.values.filter({ ready($0) }).sorted(by: { $0.note_id < $1.note_id }).prefix(4) {
                guard let data = try? JSONEncoder().encode(SyncRequest(device_id: state.device_id, changes: batch + [change])), data.count <= 2 * 1024 * 1024 else { break }
                batch.append(change)
            }
            if !batch.isEmpty { state.frozen = batch; guard persist() else { return } }
        }
        let changes = state.frozen ?? []
        syncing = true
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
                      let result = try? JSONDecoder().decode(SyncResponse.self, from: data), LocalState.validResponse(result, sent: changes) else {
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
                let original = self.state
                var candidate = original
                let remapped = candidate.merge(result, sent: changes)
                candidate.frozen = []
                self.state = candidate
                let hasCopy = result.results.contains { $0.status == "conflict_copy" }
                let hasDeleteConflict = result.results.contains { $0.status == "delete_conflict" }
                if self.persist() {
                    self.failures = 0; self.retryAfter = .distantPast
                    self.syncError = nil; self.lastSyncAt = Date()
                    if hasCopy { self.status = "检测到冲突 · 已保留两份内容" }
                    else if hasDeleteConflict { self.status = "删除未执行 · 已保留另一端的新内容" }
                    else { self.status = self.state.pending.isEmpty ? "已同步 · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))" : "本机有新修改 · 等待同步" }
                    self.onAccepted?(result.results, changes); self.onRemap?(remapped)
                } else { self.state = original }
                self.onChange?()
            }
        }.resume()
    }
}
