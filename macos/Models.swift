import Foundation

struct Attachment: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var size: Int
    var sha256: String
    static let maxBytes = 20 * 1024 * 1024
    var valid: Bool {
        id.range(of: "^[a-zA-Z0-9_-]{8,80}\\z", options: .regularExpression) != nil &&
        !name.isEmpty && name.utf16.count <= 255 && name != "." && name != ".." &&
        name.range(of: "[\\\\/\\x00-\\x1f\\x7f]", options: .regularExpression) == nil &&
        size >= 0 && size <= Self.maxBytes && sha256.utf16.count == 64 && sha256.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil
    }
    static func validList(_ values: [Attachment]?) -> Bool {
        let list = values ?? []
        return list.count <= 20 && Set(list.map { $0.id }).count == list.count && list.allSatisfy { $0.valid }
    }
}

struct Note: Codable, Equatable {
    var id: String
    var text: String
    var color: String
    var pinned: Bool
    var revision: Int
    var updated_at: String
    var deleted: Bool
    var conflict_of: String?
    var attachments: [Attachment]?
    // Display-only parsing: support CRLF, LF, CR and Unicode line separators
    // without normalizing or rewriting the saved/synchronized note text.
    private var displayLines: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    var title: String { displayLines.first ?? "新便签" }
    var preview: String { displayLines.dropFirst().joined(separator: " ") }
    static func blank() -> Note {
        Note(id: UUID().uuidString, text: "", color: "yellow", pinned: false, revision: 0,
             updated_at: ISO8601DateFormatter().string(from: Date()), deleted: false)
    }
}
struct Change: Codable, Equatable {
    var op_id: String
    var note_id: String
    var base_revision: Int
    var text: String
    var color: String
    var pinned: Bool
    var deleted: Bool
    var attachments: [Attachment]?
    init(_ note: Note) {
        op_id = UUID().uuidString; note_id = note.id; base_revision = note.revision
        text = note.text; color = note.color; pinned = note.pinned; deleted = note.deleted
        attachments = note.attachments
    }
}
struct Receipt: Codable {
    var op_id: String; var note_id: String; var revision: Int; var status: String
}
struct SyncRequest: Codable { var device_id: String; var changes: [Change] }
struct SyncResponse: Codable { var `protocol`: Int; var sequence: Int; var notes: [Note]; var results: [Receipt] }
// Transient editor state, never persisted or sent as a protocol field.
// Menu overrides are separate from the revision anchor of the local edit chain.
struct NoteComposition {
    private(set) var base: Note
    private var colorOverride: String?
    private var pinOverride: Bool?
    private var attachmentOverride: [Attachment]?
    init(_ note: Note) { base = note }
    var note: Note {
        var result = base
        if let colorOverride { result.color = colorOverride }
        if let pinOverride { result.pinned = pinOverride }
        if let attachmentOverride { result.attachments = attachmentOverride }
        return result
    }
    mutating func update(pinned: Bool? = nil, color: String? = nil, attachments: [Attachment]? = nil) {
        if let pinned { pinOverride = pinned }
        if let color { colorOverride = color }
        if let attachments { attachmentOverride = attachments }
    }
    mutating func accept(_ receipts: [Receipt], sent: [Change]) {
        for receipt in receipts where receipt.status == "applied" && receipt.note_id == base.id {
            guard let submitted = sent.first(where: { $0.op_id == receipt.op_id }),
                  submitted.note_id == base.id, !submitted.deleted,
                  submitted.base_revision == base.revision else { continue }
            base.revision = receipt.revision
        }
    }
    mutating func remap(to id: String, revision: Int?, conflictOf: String?) {
        base.id = id
        if let revision { base.revision = revision }
        base.conflict_of = conflictOf ?? base.conflict_of
    }
}
struct Configuration: Codable { var base_url: String; var token: String }
struct LocalState: Codable {
    var device_id = UUID().uuidString
    var notes: [String: Note] = [:]
    var pending: [String: Change] = [:]
    // Persist the exact payload across upload failures, timeouts and restarts.
    var frozen: [Change]?
    // Optional for backwards-compatible decoding of existing state.json files.
    // Untouched empty notes stay local until their first intentional edit.
    var draftIDs: Set<String>?
    var deleteConflictIDs: Set<String>?
    mutating func createDraft() -> Note {
        let note = Note.blank()
        notes[note.id] = note
        draftIDs = (draftIDs ?? []).union([note.id])
        return note
    }
    @discardableResult mutating func discardDraft(_ id: String) -> Bool {
        guard draftIDs?.contains(id) == true, let note = notes[id], note.text.isEmpty, (note.attachments ?? []).isEmpty else { return false }
        notes.removeValue(forKey: id); pending.removeValue(forKey: id)
        draftIDs?.remove(id)
        return true
    }
    // Apply receipts before overlaying unsent edits. An edit made during an HTTP request
    // follows the accepted revision (and a conflict copy's new UUID), never disappears.
    static func validResponse(_ response: SyncResponse, sent: [Change]) -> Bool {
        guard response.protocol == 1, response.sequence >= 0,
              Set(response.notes.map { $0.id }).count == response.notes.count,
              Set(response.results.map { $0.op_id }).count == sent.count, response.results.count == sent.count,
              response.notes.allSatisfy({ !$0.id.isEmpty && $0.text.utf16.count <= 100000 && $0.revision >= 0 && $0.revision <= response.sequence && Attachment.validList($0.attachments) }) else { return false }
        for op in sent {
            guard let receipt = response.results.first(where: { $0.op_id == op.op_id }),
                  let note = response.notes.first(where: { $0.id == receipt.note_id }),
                  receipt.revision >= 0, receipt.revision <= note.revision,
                  ["applied", "conflict_copy", "delete_conflict", "already_deleted"].contains(receipt.status),
                  receipt.status == "conflict_copy" || receipt.note_id == op.note_id else { return false }
            if receipt.status == "conflict_copy" && (op.deleted || receipt.note_id == op.note_id || note.conflict_of != op.note_id) { return false }
            if ["delete_conflict", "already_deleted"].contains(receipt.status) && !op.deleted { return false }
        }
        return true
    }
    mutating func merge(_ response: SyncResponse, sent: [Change]) -> [String: String] {
        var remapped: [String: String] = [:]
        for receipt in response.results {
            guard let submitted = sent.first(where: { $0.op_id == receipt.op_id }),
                  var queued = pending[submitted.note_id] else { continue }
            if receipt.status == "delete_conflict" {
                deleteConflictIDs = (deleteConflictIDs ?? []).union([receipt.note_id])
                // A rejected stale deletion never authorizes deleting the latest
                // remote content automatically. A newer text edit keeps its base
                // revision, so the next submission preserves a conflict copy.
                if queued.op_id == submitted.op_id || queued.deleted {
                    pending.removeValue(forKey: submitted.note_id)
                }
                continue
            }
            if queued.op_id == submitted.op_id {
                pending.removeValue(forKey: submitted.note_id)
            } else {
                queued.base_revision = receipt.revision
                queued.note_id = receipt.note_id
                pending.removeValue(forKey: submitted.note_id)
                pending[receipt.note_id] = queued
                if var local = notes.removeValue(forKey: submitted.note_id) {
                    local.id = receipt.note_id; local.revision = receipt.revision
                    if receipt.status == "conflict_copy" { local.conflict_of = submitted.note_id }
                    notes[receipt.note_id] = local
                }
            }
            if receipt.note_id != submitted.note_id { remapped[submitted.note_id] = receipt.note_id }
        }
        let oldNotes = notes
        notes = Dictionary(uniqueKeysWithValues: response.notes.map { ($0.id, $0) })
        for (id, queued) in pending {
            if var local = oldNotes[id] {
                local.revision = queued.base_revision
                local.conflict_of = notes[id]?.conflict_of ?? local.conflict_of
                notes[id] = local
            }
        }
        for id in draftIDs ?? [] {
            if notes[id] == nil, let draft = oldNotes[id] { notes[id] = draft }
        }
        return remapped
    }
}
