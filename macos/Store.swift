import AppKit

// Local notes: the state file, edits and the merge of server responses.
// Network sync and attachment uploads live in SyncClient.
@MainActor final class Store {
    static let missingConfiguration = 2
    let directory: URL
    let file: URL
    let configuration: Configuration
    var state: LocalState
    var onChange: (() -> Void)?
    var onRemap: (([String: String]) -> Void)?
    var onAccepted: (([Receipt], [Change]) -> Void)?
    var lastSaved = true
    var saveError: String?
    // The most recent deletion made on this Mac, offered for undo for a few seconds.
    var lastDeleted: (id: String, at: Date)?
    lazy var files = AttachmentFiles(directory: directory, configuration: configuration)
    lazy var remote = SyncClient(store: self)
    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SongNote")
    }
    static var configurationFile: URL { dataDirectory.appendingPathComponent("client-config.json") }
    init() throws {
        directory = Store.dataDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent("state.json")
        // The private sync key is never bundled into the app; it is chosen once and kept here (0600).
        guard FileManager.default.fileExists(atPath: Store.configurationFile.path) else {
            throw NSError(domain: "SongNote", code: Store.missingConfiguration, userInfo: [NSLocalizedDescriptionKey: "还没有同步配置"])
        }
        configuration = try Store.readConfiguration(Store.configurationFile)
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: file))
        } else { state = LocalState() }
        guard state.notes.values.allSatisfy({ Attachment.validList($0.attachments) }),
              state.pending.values.allSatisfy({ Attachment.validList($0.attachments) }),
              (state.frozen ?? []).count <= 4, (state.frozen ?? []).allSatisfy({ Attachment.validList($0.attachments) }) else {
            throw AttachmentFiles.failure("本机附件信息无效，原数据已保留。")
        }
    }
    static func readConfiguration(_ url: URL) throws -> Configuration {
        let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        guard let parsed = URL(string: value.base_url), parsed.scheme == "https", value.token.count >= 32 else {
            throw NSError(domain: "SongNote", code: 1, userInfo: [NSLocalizedDescriptionKey: "同步配置无效：需要 HTTPS 地址和至少 32 位的私有密钥"])
        }
        return value
    }
    // Validate a chosen file, then copy it into the private data directory.
    static func installConfiguration(from source: URL) throws {
        _ = try readConfiguration(source)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(contentsOf: source).write(to: configurationFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationFile.path)
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
    // Deleted notes keep their text on the server, so the last 7 days can be restored.
    var recentlyDeleted: [Note] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return state.notes.values.filter { $0.deleted && (Theme.date($0.updated_at) ?? .distantPast) >= cutoff && !$0.text.isEmpty }
            .sorted { $0.updated_at > $1.updated_at }
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
            onChange?(); return false
        }
    }
    func create() -> Note {
        let note = state.createDraft()
        persist(); onChange?(); return note
    }
    func discardDraft(_ id: String) {
        if state.discardDraft(id) { _ = persist(); onChange?() }
    }
    func acknowledgeDeleteConflict(_ id: String) {
        state.deleteConflictIDs?.remove(id); _ = persist(); onChange?()
    }
    var saveStatus: String { lastSaved ? "已保存到本机" : Texts.saveFailed }
    func update(_ note: Note) {
        var updated = note
        state.draftIDs?.remove(note.id)
        updated.updated_at = ISO8601DateFormatter().string(from: Date())
        state.notes[note.id] = updated
        state.pending[note.id] = Change(updated)
        persist(); onChange?()
        remote.afterEdit()
    }
    func delete(_ id: String) {
        guard var note = state.notes[id], !note.deleted else { return }
        note.deleted = true; lastDeleted = (id, Date()); update(note)
    }
    // Undo or restore from 最近删除: an ordinary edit on the tombstone's revision.
    func restore(_ id: String) {
        guard var note = state.notes[id], note.deleted else { return }
        note.deleted = false; if lastDeleted?.id == id { lastDeleted = nil }
        update(note)
    }
    // Keep the original note's place and id: copy the conflict copy's content into it, then delete the copy.
    func keepConflictCopy(_ copyID: String) {
        guard let copy = state.notes[copyID], let originalID = copy.conflict_of, var original = state.notes[originalID], !original.deleted else { return }
        original.text = copy.text; original.attachments = copy.attachments; update(original)
        var removed = copy; removed.deleted = true; update(removed)
    }
    func keepOriginal(_ copyID: String) {
        guard var copy = state.notes[copyID], copy.conflict_of != nil, !copy.deleted else { return }
        copy.deleted = true; update(copy)
    }
    // Freeze up to four ready changes (2 MiB request limit); the exact payload survives restarts.
    func freeze(ready: (Change) -> Bool) -> [Change]? {
        if (state.frozen ?? []).isEmpty {
            var batch: [Change] = []
            for change in state.pending.values.filter(ready).sorted(by: { $0.note_id < $1.note_id }).prefix(4) {
                guard let data = try? JSONEncoder().encode(SyncRequest(device_id: state.device_id, changes: batch + [change])), data.count <= 2 * 1024 * 1024 else { break }
                batch.append(change)
            }
            if !batch.isEmpty { state.frozen = batch; guard persist() else { return nil } }
        }
        return state.frozen ?? []
    }
    enum Outcome { case unchanged, applied, failed }
    // Merge a validated response. An idle poll that changes nothing writes nothing and refreshes nothing.
    func apply(_ result: SyncResponse, sent: [Change]) -> Outcome {
        let original = state
        var candidate = original
        let remapped = candidate.merge(result, sent: sent)
        candidate.frozen = []
        var before = original; before.frozen = []
        if sent.isEmpty && candidate == before { return .unchanged }
        state = candidate
        guard persist() else { state = original; return .failed }
        onAccepted?(result.results, sent); onRemap?(remapped)
        return .applied
    }
}
