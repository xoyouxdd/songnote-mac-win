namespace SongNote.Core;

public interface IStateFile
{
    LocalState? Read();
    void Write(LocalState state);
}
public sealed class AtomicStateFile(string directory) : IStateFile
{
    public string DirectoryPath { get; } = Path.GetFullPath(directory);
    public LocalState? Read()
    {
        var path = Path.Combine(DirectoryPath, "state.json");
        return File.Exists(path) ? ProtocolJson.Decode<LocalState>(File.ReadAllText(path)) : null;
    }
    public void Write(LocalState state)
    {
        Directory.CreateDirectory(DirectoryPath);
        var path = Path.Combine(DirectoryPath, "state.json");
        var temp = Path.Combine(DirectoryPath, "state." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                var bytes = System.Text.Encoding.UTF8.GetBytes(ProtocolJson.Encode(state));
                stream.Write(bytes); stream.Flush(flushToDisk: true);
            }
            if (File.Exists(path)) File.Replace(temp, path, Path.Combine(DirectoryPath, "state.previous.json"));
            else File.Move(temp, path);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
public sealed class LocalStore
{
    readonly object gate = new();
    readonly IStateFile file;
    LocalState state;
    public bool LastSaved { get; private set; } = true;
    public string? SaveError { get; private set; }
    public event Action? Changed;
    public event Action<Dictionary<string, string>, Receipt[], Change[]>? Accepted;
    public LocalStore(IStateFile file)
    {
        this.file = file; var initial = file.Read(); state = initial ?? new LocalState();
        ValidateLocal(state); // Corrupt files are never silently replaced.
        if (initial == null) file.Write(state);
    }
    static void ValidateLocal(LocalState state)
    {
        if (state.Schema != 1 || string.IsNullOrWhiteSpace(state.DeviceId) || state.Notes == null || state.Pending == null ||
            state.FrozenBatch == null || state.DraftIds == null || state.DeleteConflictIds == null || state.Windows == null || state.OpenNotes == null ||
            state.FrozenBatch.Length > 4 || state.FrozenBatch.Any(c => c == null || !state.Notes.ContainsKey(c.NoteId)) ||
            state.FrozenBatch.Select(c => c.OpId).Distinct().Count() != state.FrozenBatch.Length ||
            state.Pending.Any(p => p.Value == null || p.Key != p.Value.NoteId || !state.Notes.ContainsKey(p.Key)) ||
            state.Notes.Any(p => p.Value == null || p.Key != p.Value.Id || p.Value.Text == null || p.Value.Text.Length > 100000))
            throw new InvalidDataException("本机便签文件无效，原文件已保留。");
    }
    public LocalState Snapshot() { lock (gate) return state.Copy(); }
    bool Save(LocalState value)
    {
        try { file.Write(value); LastSaved = true; SaveError = null; return true; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Text.Json.JsonException)
        { LastSaved = false; SaveError = e.Message; return false; }
    }
    void Edit(Action<LocalState> change)
    {
        lock (gate) { change(state); Save(state); }
        Changed?.Invoke();
    }
    public bool RetrySave()
    {
        bool result; lock (gate) result = Save(state);
        Changed?.Invoke(); return result;
    }
    public Note CreateDraft()
    {
        var note = Note.Blank(); Edit(s => { s.Notes[note.Id] = note; s.DraftIds.Add(note.Id); }); return note;
    }
    public bool DiscardDraft(string id)
    {
        bool result = true;
        lock (gate)
        {
            if (state.DraftIds.Contains(id) && state.Notes.TryGetValue(id, out var note) && note.Text.Length == 0)
            {
                var candidate = state.Copy(); candidate.Notes.Remove(id); candidate.DraftIds.Remove(id); candidate.OpenNotes.Remove(id);
                result = Save(candidate); if (result) state = candidate;
            }
        }
        Changed?.Invoke(); return result;
    }
    public bool FinishSession(IEnumerable<string> openIds)
    {
        bool result;
        lock (gate)
        {
            var candidate = state.Copy(); var open = openIds.ToArray();
            foreach (var id in open)
                if (candidate.DraftIds.Contains(id) && candidate.Notes.TryGetValue(id, out var note) && note.Text.Length == 0)
                { candidate.Notes.Remove(id); candidate.DraftIds.Remove(id); }
            candidate.OpenNotes = new(open.Where(candidate.Notes.ContainsKey));
            result = Save(candidate); if (result) state = candidate;
        }
        Changed?.Invoke(); return result;
    }
    public void SetText(string id, string text, Note? basis = null)
    {
        if (text.Length > 100000) throw new ArgumentException("便签最多 100000 个 UTF-16 单元。");
        Edit(s =>
        {
            if (!s.Notes.TryGetValue(id, out var current)) return;
            var note = (basis ?? current) with { Id = id, Text = text, Deleted = false, UpdatedAt = DateTimeOffset.UtcNow.ToString("O") };
            Queue(s, note);
        });
    }
    public void SetColor(string id, string color) => Edit(s =>
    {
        if (!new[] { "yellow", "green", "blue", "pink", "purple", "gray" }.Contains(color)) throw new ArgumentException("颜色无效。");
        if (s.Notes.TryGetValue(id, out var note) && !note.Deleted && note.Color != color) Queue(s, note with { Color = color });
    });
    public void TogglePin(string id) => Edit(s => { if (s.Notes.TryGetValue(id, out var note) && !note.Deleted) Queue(s, note with { Pinned = !note.Pinned }); });
    public void Delete(string id) => Edit(s => { if (s.Notes.TryGetValue(id, out var note) && !note.Deleted) Queue(s, note with { Deleted = true }); });
    static void Queue(LocalState s, Note note)
    {
        note = note with { UpdatedAt = DateTimeOffset.UtcNow.ToString("O") };
        s.DraftIds.Remove(note.Id); s.Notes[note.Id] = note; s.Pending[note.Id] = Change.From(note);
    }
    public void Acknowledge(string id) => Edit(s => s.DeleteConflictIds.Remove(id));
    public void SavePlacement(string id, Placement placement) => Edit(s => s.Windows[id] = placement);
    public void SaveOpenNotes(IEnumerable<string> ids) => Edit(s => s.OpenNotes = new(ids));
    public void MarkTrayHint() => Edit(s => s.TrayHintShown = true);
    public SyncRequest Freeze()
    {
        SyncRequest request;
        lock (gate)
        {
            if (!LastSaved) throw new IOException("本机保存失败，同步已暂停。");
            if (state.FrozenBatch.Length == 0 && state.Pending.Count > 0)
            {
                var candidate = state.Copy(); var batch = new List<Change>();
                foreach (var op in state.Pending.Values.OrderBy(c => c.NoteId).Take(4))
                {
                    var proposal = batch.Append(op).ToArray();
                    if (System.Text.Encoding.UTF8.GetByteCount(ProtocolJson.Encode(new SyncRequest(state.DeviceId, proposal))) > 2 * 1024 * 1024) break;
                    batch.Add(op);
                }
                if (batch.Count == 0) throw new InvalidDataException("单条操作超过请求大小限制，内容已保留。");
                candidate.FrozenBatch = batch.ToArray();
                foreach (var op in candidate.FrozenBatch) candidate.Pending.Remove(op.NoteId);
                if (!Save(candidate)) throw new IOException(SaveError);
                state = candidate;
            }
            request = new(state.DeviceId, [.. state.FrozenBatch]);
        }
        Changed?.Invoke(); return request;
    }
    public void Apply(SyncResponse response, Change[] sent)
    {
        MergeResult merged;
        lock (gate)
        {
            if (!state.FrozenBatch.SequenceEqual(sent)) throw new InvalidDataException("冻结请求与回执不匹配。");
            merged = StateMerge.Apply(state, response, sent);
            if (!Save(merged.State)) throw new IOException(SaveError);
            state = merged.State;
        }
        Accepted?.Invoke(merged.Remapped, response.Results, sent); Changed?.Invoke();
    }
}
