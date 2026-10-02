namespace SongNote.Core;

public sealed record MergeResult(LocalState State, Dictionary<string, string> Remapped);
public static class StateMerge
{
    public static MergeResult Apply(LocalState source, SyncResponse response, Change[] sent)
    {
        Validate(response, sent);
        var next = source.Copy();
        var local = new Dictionary<string, Note>(source.Notes);
        var remapped = new Dictionary<string, string>();
        foreach (var submitted in sent)
        {
            var receipt = response.Results.Single(r => r.OpId == submitted.OpId);
            next.Pending.TryGetValue(submitted.NoteId, out var queued);
            if (receipt.Status == "delete_conflict")
            {
                next.DeleteConflictIds.Add(receipt.NoteId);
                if (queued?.Deleted == true) next.Pending.Remove(submitted.NoteId);
                // A newer text edit retains its stale base and becomes a copy.
                continue;
            }
            if (queued != null)
            {
                next.Pending.Remove(submitted.NoteId);
                var revision = submitted.Deleted && !queued.Deleted ? queued.BaseRevision : receipt.Revision;
                next.Pending[receipt.NoteId] = queued with { NoteId = receipt.NoteId, BaseRevision = revision };
                if (local.Remove(submitted.NoteId, out var edited))
                    local[receipt.NoteId] = edited with { Id = receipt.NoteId, Revision = revision,
                        ConflictOf = receipt.Status == "conflict_copy" ? submitted.NoteId : edited.ConflictOf };
            }
            if (receipt.NoteId != submitted.NoteId)
            {
                remapped[submitted.NoteId] = receipt.NoteId;
                if (next.Windows.Remove(submitted.NoteId, out var placement)) next.Windows[receipt.NoteId] = placement;
                if (next.OpenNotes.Remove(submitted.NoteId)) next.OpenNotes.Add(receipt.NoteId);
                if (next.DeleteConflictIds.Remove(submitted.NoteId)) next.DeleteConflictIds.Add(receipt.NoteId);
            }
        }
        next.Notes = response.Notes.ToDictionary(n => n.Id);
        foreach (var (id, queued) in next.Pending)
        {
            if (!local.TryGetValue(id, out var edited)) throw new InvalidDataException("待提交操作缺少本机正文。");
            next.Notes.TryGetValue(id, out var server);
            next.Notes[id] = edited with { Revision = queued.BaseRevision, ConflictOf = server?.ConflictOf ?? edited.ConflictOf };
        }
        foreach (var id in next.DraftIds)
            if (!next.Notes.ContainsKey(id) && local.TryGetValue(id, out var draft)) next.Notes[id] = draft;
        next.FrozenBatch = [];
        return new(next, remapped);
    }
    public static void Validate(SyncResponse response, Change[] sent)
    {
        if (response.Protocol != 1 || response.Notes == null || response.Results == null || response.Sequence < 0 ||
            response.Notes.Any(n => n == null) || response.Results.Any(r => r == null) ||
            response.Notes.Select(n => n.Id).Distinct().Count() != response.Notes.Length ||
            response.Results.Length != sent.Length || response.Results.Select(r => r.OpId).Distinct().Count() != sent.Length)
            throw new InvalidDataException("同步响应不完整或协议版本无效。");
        foreach (var note in response.Notes)
        {
            Attachment.ValidateList(note.Attachments);
            if (string.IsNullOrEmpty(note.Id) || note.Text == null || note.Text.Length > 100000 || note.Revision < 0 || note.Revision > response.Sequence ||
                !new[] { "yellow", "green", "blue", "pink", "purple", "gray" }.Contains(note.Color))
                throw new InvalidDataException("服务器便签字段无效。");
        }
        foreach (var op in sent)
        {
            var receipt = response.Results.SingleOrDefault(r => r.OpId == op.OpId);
            if (receipt == null || receipt.Revision < 0 ||
                !new[] { "applied", "conflict_copy", "delete_conflict", "already_deleted" }.Contains(receipt.Status) ||
                (receipt.Status != "conflict_copy" && receipt.NoteId != op.NoteId) ||
                (receipt.Status is "delete_conflict" or "already_deleted" && !op.Deleted) ||
                (receipt.Status == "conflict_copy" && op.Deleted) ||
                !response.Notes.Any(n => n.Id == receipt.NoteId))
                throw new InvalidDataException("同步回执无效，保留冻结操作等待重试。");
            if (receipt.Revision > response.Notes.Single(n => n.Id == receipt.NoteId).Revision)
                throw new InvalidDataException("同步回执版本超过快照版本。");
            if (receipt.Status == "conflict_copy" && (receipt.NoteId == op.NoteId ||
                response.Notes.Single(n => n.Id == receipt.NoteId).ConflictOf != op.NoteId))
                throw new InvalidDataException("冲突副本来源无效。");
        }
    }
}
