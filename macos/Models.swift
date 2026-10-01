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
    var title: String { text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "新便签" }
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
    // Apply receipts before overlaying unsent edits. An edit made during an HTTP request
    // follows the accepted revision (and a conflict copy's new UUID), never disappears.
    mutating func merge(_ response: SyncResponse, sent: [Change]) -> [String: String] {
        var remapped: [String: String] = [:]
        for receipt in response.results {
            guard let submitted = sent.first(where: { $0.op_id == receipt.op_id }),
                  var queued = pending[submitted.note_id] else { continue }
            if queued.op_id == submitted.op_id {
                pending.removeValue(forKey: submitted.note_id)
            } else {
                queued.base_revision = receipt.revision
                queued.note_id = receipt.note_id
                pending.removeValue(forKey: submitted.note_id)
                pending[receipt.note_id] = queued
                if var local = notes.removeValue(forKey: submitted.note_id) {
                    local.id = receipt.note_id; local.revision = receipt.revision
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
                notes[id] = local
            }
        }
        return remapped
    }
}
