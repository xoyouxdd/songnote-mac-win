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
        assert(state.notes[original.id]?.text == serverNote.text)
        var remote = serverNote; remote.text = "另一端已更新"; remote.revision = 9
        _ = state.merge(SyncResponse(protocol: 1, sequence: 9, notes: [remote, copy], results: []), sent: [])
        assert(state.notes[copy.id]?.text == "冲突请求期间继续输入")
        assert(state.pending[copy.id]?.base_revision == 8)
        print("MODEL_TESTS_OK: in-flight edits, conflict remap, retry receipts, unsent offline overlay")
    }
}
