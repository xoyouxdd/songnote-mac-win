import Foundation

// Talks to the sync server: a 3 s poll, a 0.7 s debounce after edits, attachment uploads first,
// then one frozen batch at a time. Local state changes go through Store.
@MainActor final class SyncClient {
    unowned let store: Store
    var status = Texts.connecting
    var syncing = false
    var syncError: String?
    var lastSyncAt: Date?
    var showSyncProgress = false
    var attachmentStatus: String?
    var attachmentSupported = false
    private var timer: Timer?
    private var debounce: Timer?
    private var retryAfter = Date.distantPast
    private var failures = 0
    private var uploadTask: Task<Void, Never>?
    private var uploadedHashes: Set<String> = []
    private var fileRetryAfter = Date.distantPast
    init(store: Store) { self.store = store }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        sync()
    }
    func afterEdit() {
        if store.lastSaved { status = syncError == nil ? Texts.waiting : Texts.offlineWaiting }
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }
    func status(for id: String) -> String {
        guard store.lastSaved else { return Texts.savePaused }
        if store.state.draftIDs?.contains(id) == true { return Texts.draft }
        if syncing && showSyncProgress { return Texts.syncing }
        if let syncError { return syncError == Texts.offline && store.state.pending[id] != nil ? Texts.offlineWaiting : syncError }
        if store.state.pending[id] != nil { return Texts.waiting }
        guard let lastSyncAt else { return Texts.connecting }
        return Texts.synced(lastSyncAt)
    }
    func ready(_ change: Change) -> Bool {
        change.attachments == nil || (attachmentSupported && (change.attachments ?? []).allSatisfy { uploadedHashes.contains($0.sha256) })
    }
    private func beginUploads() {
        guard uploadTask == nil, Date() >= fileRetryAfter else { return }
        let pending = ((store.state.frozen ?? []) + Array(store.state.pending.values)).filter { !ready($0) }
        guard !pending.isEmpty else { return }
        uploadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.attachmentStatus = "正在准备附件…"; self.store.onChange?()
                if !self.attachmentSupported { try await self.store.files.checkSupport(); self.attachmentSupported = true }
                var firstError: String?
                for value in pending.flatMap({ $0.attachments ?? [] }) {
                    if self.uploadedHashes.contains(value.sha256) { continue }
                    self.attachmentStatus = "正在上传 · " + value.name; self.store.onChange?()
                    do { try await self.store.files.upload(value); self.uploadedHashes.insert(value.sha256) }
                    catch { if firstError == nil { firstError = error.localizedDescription } }
                }
                self.attachmentStatus = firstError
                self.fileRetryAfter = firstError == nil ? .distantPast : Date().addingTimeInterval(15)
            } catch {
                self.attachmentStatus = error.localizedDescription
                self.fileRetryAfter = Date().addingTimeInterval(15)
            }
            self.uploadTask = nil; self.store.onChange?(); self.sync()
        }
    }
    func sync(force: Bool = false) {
        if force && !store.lastSaved && !store.persist() { return }
        guard !syncing, store.lastSaved, force || Date() >= retryAfter else { return }
        if force { fileRetryAfter = .distantPast }
        beginUploads()
        if (store.state.frozen ?? []).contains(where: { !ready($0) }) { return }
        guard let changes = store.freeze(ready: ready) else { return }
        syncing = true
        showSyncProgress = force || !changes.isEmpty
        if showSyncProgress { status = Texts.syncing; store.onChange?() }
        Task { @MainActor in await self.send(changes) }
    }
    private func send(_ changes: [Change]) async {
        var request = URLRequest(url: URL(string: store.configuration.base_url + "/v1/sync")!)
        request.httpMethod = "POST"; request.timeoutInterval = 12
        request.setValue("Bearer " + store.configuration.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(SyncRequest(device_id: store.state.device_id, changes: changes, since: store.state.sequence))
        let previous = (status, syncError)
        var outcome = Store.Outcome.failed
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw SyncFailure(message: code == 401 ? Texts.badToken : Texts.failed(code)) }
            guard let result = try? JSONDecoder().decode(SyncResponse.self, from: data), LocalState.validResponse(result, sent: changes) else {
                throw SyncFailure(message: Texts.badResponse)
            }
            outcome = store.apply(result, sent: changes)
            if outcome != .failed {
                failures = 0; retryAfter = .distantPast; syncError = nil; lastSyncAt = Date()
                if result.results.contains(where: { $0.status == "conflict_copy" }) { status = Texts.conflictCopy }
                else if result.results.contains(where: { $0.status == "delete_conflict" }) { status = Texts.deleteRejected }
                else { status = store.state.pending.isEmpty ? Texts.synced(Date()) : Texts.waiting }
            }
        } catch {
            failures += 1
            retryAfter = Date().addingTimeInterval(min(30, pow(2, Double(min(failures, 5)))))
            syncError = (error as? SyncFailure)?.message ?? Texts.offline
            status = syncError!
        }
        syncing = false
        // Idle polls stay silent unless the visible status text changed.
        if outcome == .applied || showSyncProgress || status != previous.0 || syncError != previous.1 { store.onChange?() }
    }
    struct SyncFailure: Error { let message: String }
}
