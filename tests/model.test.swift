import Foundation
@main struct ModelTest {
    static func main() {
        var original = Note.blank(); original.text = "原始"; original.revision = 5
        let submitted = Change(original)
        var state = LocalState(); state.notes[original.id] = original; state.pending[original.id] = submitted
        var edited = original; edited.text = "请求期间继续输入"
        state.notes[original.id] = edited; state.pending[original.id] = Change(edited)
        var serverNote = original; serverNote.revision = 6
        let response = SyncResponse(protocol: 1, sequence: 6, notes: [serverNote], results: [Receipt(op_id: submitted.op_id, note_id: original.id, revision: 6, status: "applied")])
        _ = state.merge(response, sent: [submitted])
        assert(state.notes[original.id]?.text == "请求期间继续输入")
        assert(state.pending[original.id]?.base_revision == 6)
        let retry = state.pending[original.id]!
        serverNote.text = edited.text; serverNote.revision = 7
        _ = state.merge(SyncResponse(protocol: 1, sequence: 7, notes: [serverNote], results: [Receipt(op_id: retry.op_id, note_id: original.id, revision: 7, status: "applied")]), sent: [retry])
        assert(state.pending.isEmpty); assert(state.notes[original.id]?.text == edited.text)

        state.notes[original.id] = edited; state.pending[original.id] = Change(edited)
        let conflicted = state.pending[original.id]!
        edited.text = "冲突请求期间继续输入"; state.notes[original.id] = edited; state.pending[original.id] = Change(edited)
        var copy = edited; copy.id = UUID().uuidString; copy.revision = 8; copy.conflict_of = original.id
        let mapping = state.merge(SyncResponse(protocol: 1, sequence: 8, notes: [serverNote, copy], results: [Receipt(op_id: conflicted.op_id, note_id: copy.id, revision: 8, status: "conflict_copy")]), sent: [conflicted])
        assert(mapping[original.id] == copy.id)
        assert(state.pending[original.id] == nil)
        assert(state.pending[copy.id]?.base_revision == 8)
        assert(state.notes[copy.id]?.text == "冲突请求期间继续输入")
        assert(state.notes[copy.id]?.conflict_of == original.id)
        assert(state.notes[original.id]?.text == serverNote.text)
        var remote = serverNote; remote.text = "另一端已更新"; remote.revision = 9
        _ = state.merge(SyncResponse(protocol: 1, sequence: 9, notes: [remote, copy], results: []), sent: [])
        assert(state.notes[copy.id]?.text == "冲突请求期间继续输入")
        assert(state.pending[copy.id]?.base_revision == 8)
        assert(state.notes[copy.id]?.conflict_of == original.id)

        // Existing installations have no draft or notice metadata.
        struct LegacyState: Codable {
            var device_id: String; var notes: [String: Note]; var pending: [String: Change]
        }
        let legacy = LegacyState(device_id: "legacy-device", notes: [original.id: original], pending: [:])
        var upgraded = try! JSONDecoder().decode(LocalState.self, from: JSONEncoder().encode(legacy))
        assert(upgraded.device_id == legacy.device_id && upgraded.notes[original.id] == original)
        assert(upgraded.draftIDs == nil && upgraded.deleteConflictIDs == nil)

        // An untouched empty draft is persisted locally, never submitted or lost
        // when an empty server snapshot arrives. Existing empty notes survive.
        let draft = upgraded.createDraft()
        assert(upgraded.pending[draft.id] == nil)
        _ = upgraded.merge(SyncResponse(protocol: 1, sequence: 0, notes: [], results: []), sent: [])
        assert(upgraded.notes[draft.id] == draft)
        upgraded = try! JSONDecoder().decode(LocalState.self, from: JSONEncoder().encode(upgraded))
        assert(upgraded.draftIDs?.contains(draft.id) == true)
        assert(upgraded.discardDraft(draft.id))
        assert(upgraded.notes[draft.id] == nil && upgraded.pending[draft.id] == nil)
        var empty = Note.blank(); empty.revision = 10; upgraded.notes[empty.id] = empty
        assert(!upgraded.discardDraft(empty.id) && upgraded.notes[empty.id] != nil)

        // A stale deletion is rejected even if another deletion was queued while
        // the request ran. A newer text edit keeps its original base revision.
        var current = original; current.revision = 10; current.text = "另一端重要的新内容"
        var deletion = original; deletion.deleted = true
        let staleDelete = Change(deletion)
        let rejection = SyncResponse(protocol: 1, sequence: 10, notes: [current], results: [Receipt(op_id: staleDelete.op_id, note_id: original.id, revision: 10, status: "delete_conflict")])
        for newerIntent in 0..<3 {
            var candidate = LocalState(); candidate.notes[original.id] = deletion
            if newerIntent == 0 { candidate.pending[original.id] = staleDelete }
            else if newerIntent == 1 { candidate.pending[original.id] = Change(deletion) }
            else {
                var edit = original; edit.text = "本机请求期间继续编辑"; candidate.notes[original.id] = edit
                candidate.pending[original.id] = Change(edit)
            }
            _ = candidate.merge(rejection, sent: [staleDelete])
            assert(candidate.deleteConflictIDs?.contains(original.id) == true)
            if newerIntent < 2 {
                assert(candidate.pending[original.id] == nil)
                assert(candidate.notes[original.id] == current)
            } else {
                assert(candidate.pending[original.id]?.base_revision == original.revision)
                assert(candidate.notes[original.id]?.text == "本机请求期间继续编辑")
            }
            let restarted = try! JSONDecoder().decode(LocalState.self, from: JSONEncoder().encode(candidate))
            assert(restarted.deleteConflictIDs?.contains(original.id) == true)
            var polled = restarted
            _ = polled.merge(SyncResponse(protocol: 1, sequence: 10, notes: [current], results: []), sent: [])
            assert(polled.deleteConflictIDs?.contains(original.id) == true)
        }
        print("MODEL_TESTS_OK: in-flight edits, conflict metadata, legacy decoding, local drafts, stale delete rejection and persistent notices")
    }
}
