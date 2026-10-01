import Foundation

struct Note: Codable, Equatable {
    var id: String
    var text: String
    var color: String
    var pinned: Bool
    var revision: Int
    var updated_at: String
    var deleted: Bool
    var conflict_of: String?
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
    init(_ note: Note) {
        op_id = UUID().uuidString; note_id = note.id; base_revision = note.revision
        text = note.text; color = note.color; pinned = note.pinned; deleted = note.deleted
    }
}
struct Receipt: Codable {
    var op_id: String; var note_id: String; var revision: Int; var status: String
}
struct SyncRequest: Codable { var device_id: String; var changes: [Change] }
struct SyncResponse: Codable { var `protocol`: Int; var sequence: Int; var notes: [Note]; var results: [Receipt] }
struct Configuration: Codable { var base_url: String; var token: String }
struct LocalState: Codable {
    var device_id = UUID().uuidString
    var notes: [String: Note] = [:]
    var pending: [String: Change] = [:]
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
        guard draftIDs?.contains(id) == true, let note = notes[id], note.text.isEmpty else { return false }
        notes.removeValue(forKey: id); pending.removeValue(forKey: id)
        draftIDs?.remove(id)
        return true
    }
    // Apply receipts before overlaying unsent edits. An edit made during an HTTP request
    // follows the accepted revision (and a conflict copy's new UUID), never disappears.
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
