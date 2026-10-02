using System.Net;
using System.Text;
using System.Globalization;
using SongNote.Core;

static class Tests
{
    static int passed;
    static void Check(bool value, string message = "assertion failed") { if (!value) throw new Exception(message); }
    static void Throws<T>(Action action) where T : Exception { try { action(); } catch (T) { return; } throw new Exception("Expected " + typeof(T).Name); }
    static LocalStore New(out MemoryFile file) { file = new(); return new(file); }
    static void Test(string name, Action test) { test(); passed++; Console.WriteLine("PASS: " + name); }
    static async Task Test(string name, Func<Task> test) { await test(); passed++; Console.WriteLine("PASS: " + name); }
    static SyncResponse Response(Change sent, int revision, string? text = null, string status = "applied", string? target = null)
    {
        string id = target ?? sent.NoteId;
        var note = new Note(id, text ?? sent.Text, sent.Color, sent.Pinned, revision, DateTimeOffset.UtcNow.ToString("O"), sent.Deleted && status != "delete_conflict", status == "conflict_copy" ? sent.NoteId : null, sent.Attachments);
        return new(1, revision, [note], [new(sent.OpId, id, revision, status)]);
    }
    public static async Task<int> Main(string[] args)
    {
        try
        {
            if (!args.Contains("--integration-only"))
            {
            Test("Unicode highlight spans use original-text lengths and preserve search semantics", () =>
            {
                var savedCulture = CultureInfo.CurrentCulture;
                try
                {
                    CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("zh-Hans-HK");
                    Check(SearchMatches.Find("é", "e\u0301").Single() == new TextMatch(0, 1));
                    Check(SearchMatches.Find("e\u0301", "é").Single() == new TextMatch(0, 2));
                    Check(SearchMatches.Find("abc", "abc\u00ad").Single() == new TextMatch(0, 3));
                    Check(SearchMatches.Find("é é", "e\u0301").SequenceEqual(new[] { new TextMatch(0, 1), new TextMatch(2, 1) }));
                    Check(SearchMatches.Find("abc", "\u00ad").Count == 0);
                    Check(SearchMatches.Find("中文 📝", "📝").Single() == new TextMatch(3, 2));
                    Check(SearchMatches.Find("abc", "").Count == 0 && SearchMatches.Find("", "x").Count == 0);
                }
                finally { CultureInfo.CurrentCulture = savedCulture; }
            });
            Test("blank leading lines stay out of the card title", () =>
            {
                var leading = new Note("id", "\r\n周五前交周报", "yellow", false, 0, "t", false);
                Check(leading.Title == "周五前交周报" && leading.DisplayLines.Length == 1);
                var body = new Note("id", "周五前交周报\r\n整理数据", "yellow", false, 0, "t", false);
                Check(body.Title == "周五前交周报" && string.Join(" ", body.DisplayLines.Skip(1)) == "整理数据");
                var spaced = new Note("id", "  \n\n买菜\n鸡蛋", "yellow", false, 0, "t", false);
                Check(spaced.Title == "买菜" && string.Join(" ", spaced.DisplayLines.Skip(1)) == "鸡蛋");
                Check(new Note("id", "", "yellow", false, 0, "t", false).Title == "新便签");
            });
            Test("snake_case contracts and configuration validation", () =>
            {
                var change = Change.From(Note.Blank()); var json = ProtocolJson.Encode(new SyncRequest("test-device", [change]));
                Check(json.Contains("\"base_revision\"") && json.Contains("\"op_id\"") && !json.Contains("frozen_batch"));
                Check(ProtocolJson.Decode<SyncRequest>(json).Changes.Single() == change);
                new Configuration("https://example.invalid/songnote", new string('x', 32)).Validate();
                Throws<InvalidDataException>(() => new Configuration("http://127.0.0.1", new string('x', 32)).Validate());
            });
            Test("draft survives polling/restart, untouched close discards, old empty note survives", () =>
            {
                var store = New(out var file); var draft = store.CreateDraft(); Check(store.Freeze().Changes.Length == 0);
                store.Apply(new(1, 0, [], []), []); Check(store.Snapshot().Notes[draft.Id] == draft);
                var restart = new LocalStore(file); Check(restart.Snapshot().DraftIds.Contains(draft.Id)); Check(restart.DiscardDraft(draft.Id));
                var old = Note.Blank() with { Revision = 2 }; file.Data!.Notes[old.Id] = old;
                var another = new LocalStore(file); another.DiscardDraft(old.Id); Check(another.Snapshot().Notes.ContainsKey(old.Id));
            });
            Test("intentional edit then clear remains queued and is not discarded", () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "写过"); store.SetText(note.Id, "");
                Check(!store.Snapshot().DraftIds.Contains(note.Id)); store.DiscardDraft(note.Id); Check(store.Snapshot().Notes.ContainsKey(note.Id));
            });
            Test("freeze write failure keeps pending and prevents sending", () =>
            {
                var store = New(out var file); var note = store.CreateDraft(); store.SetText(note.Id, "重要内容"); file.Fail = true;
                Throws<IOException>(() => store.Freeze()); Check(store.Snapshot().FrozenBatch.Length == 0 && store.Snapshot().Pending.ContainsKey(note.Id));
            });
            Test("large Unicode batch stays within 2 MiB and preserves remaining operations", () =>
            {
                var store = New(out _);
                for (int i = 0; i < 4; i++) { var note = store.CreateDraft(); store.SetText(note.Id, new string('中', 100000)); }
                var request = store.Freeze(); Check(request.Changes.Length is > 0 and < 4);
                Check(Encoding.UTF8.GetByteCount(ProtocolJson.Encode(request)) <= 2 * 1024 * 1024);
                Check(store.Snapshot().Pending.Count + request.Changes.Length == 4);
            });
            Test("in-flight edits keep frozen payload immutable and follow accepted revision", () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "A"); var frozen = store.Freeze().Changes;
                string encoded = ProtocolJson.Encode(frozen); store.SetText(note.Id, "B"); store.SetText(note.Id, "C");
                Check(ProtocolJson.Encode(store.Snapshot().FrozenBatch) == encoded);
                store.Apply(Response(frozen[0], 6), frozen); var state = store.Snapshot();
                Check(state.Notes[note.Id].Text == "C" && state.Pending[note.Id].BaseRevision == 6 && state.FrozenBatch.Length == 0);
            });
            Test("historical receipt never rebases later edits onto newer remote snapshot", () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "A"); var frozen = store.Freeze().Changes; store.SetText(note.Id, "B");
                var response = Response(frozen[0], 6, "远端版本9"); response = response with { Sequence = 9, Notes = [response.Notes[0] with { Revision = 9 }] };
                store.Apply(response, frozen); Check(store.Snapshot().Pending[note.Id].BaseRevision == 6); Check(store.Snapshot().Notes[note.Id].Text == "B");
            });
            Test("conflict remaps future edits, source, window placement and open IDs", () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "A"); store.SavePlacement(note.Id, new(10, 20, 380, 420, true)); store.SaveOpenNotes([note.Id]);
                var sent = store.Freeze().Changes; store.SetText(note.Id, "继续输入"); string copy = Guid.NewGuid().ToString();
                var response = Response(sent[0], 8, status: "conflict_copy", target: copy);
                response = response with { Notes = [new(note.Id, "远端原件", "yellow", false, 7, note.UpdatedAt, false), response.Notes[0]] };
                store.Apply(response, sent); var state = store.Snapshot();
                Check(state.Notes[note.Id].Text == "远端原件" && state.Notes[copy].Text == "继续输入" && state.Notes[copy].ConflictOf == note.Id);
                Check(state.Pending[copy].BaseRevision == 8 && state.Windows[copy].Topmost && state.OpenNotes.Contains(copy));
            });
            for (int intent = 0; intent < 3; intent++)
            {
                int mode = intent;
                Test("delete rejection with later intent " + mode, () =>
                {
                    var store = New(out var file); var note = store.CreateDraft(); store.SetText(note.Id, "原件"); var first = store.Freeze().Changes; store.Apply(Response(first[0], 5), first);
                    store.Delete(note.Id); var sent = store.Freeze().Changes;
                    if (mode == 1) { store.SetText(note.Id, ""); store.Delete(note.Id); }
                    if (mode == 2) store.SetText(note.Id, "请求期间的正文");
                    store.Apply(Response(sent[0], 9, "另一端的重要新内容", "delete_conflict"), sent);
                    var state = store.Snapshot(); Check(state.DeleteConflictIds.Contains(note.Id));
                    if (mode < 2) Check(!state.Pending.ContainsKey(note.Id) && state.Notes[note.Id].Text == "另一端的重要新内容" && !state.Notes[note.Id].Deleted);
                    else Check(state.Pending[note.Id].BaseRevision == 5 && state.Notes[note.Id].Text == "请求期间的正文");
                    var restart = new LocalStore(file); Check(restart.Snapshot().DeleteConflictIds.Contains(note.Id));
                });
            }
            Test("already-deleted receipt retains late text at stale revision", () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "A"); var initial = store.Freeze().Changes; store.Apply(Response(initial[0], 5), initial);
                store.Delete(note.Id); var sent = store.Freeze().Changes; store.SetText(note.Id, "迟到的文字");
                store.Apply(Response(sent[0], 9, status: "already_deleted"), sent);
                Check(store.Snapshot().Pending[note.Id].BaseRevision == 5 && store.Snapshot().Notes[note.Id].Text == "迟到的文字");
            });
            Test("applied deletion cannot rebase late text onto a tombstone", () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "A"); var initial = store.Freeze().Changes; store.Apply(Response(initial[0], 5), initial);
                store.Delete(note.Id); var sent = store.Freeze().Changes; store.SetText(note.Id, "迟到正文"); store.Apply(Response(sent[0], 6), sent);
                Check(store.Snapshot().Pending[note.Id].BaseRevision == 5 && !store.Snapshot().Notes[note.Id].Deleted);
            });
            Test("multi-draft exit transaction failure preserves all editing targets", () =>
            {
                var store = New(out var file); var first = store.CreateDraft(); var second = store.CreateDraft(); file.Fail = true;
                Check(!store.FinishSession([first.Id, second.Id])); Check(store.Snapshot().Notes.ContainsKey(first.Id) && store.Snapshot().Notes.ContainsKey(second.Id));
                file.Fail = false; store.SetText(first.Id, "取消退出后的输入"); Check(store.FinishSession([first.Id, second.Id]));
                Check(store.Snapshot().Notes.ContainsKey(first.Id) && !store.Snapshot().Notes.ContainsKey(second.Id));
            });
            Test("invalid receipt intent, null elements and missing device identity preserve data", () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "不能丢的文字"); var sent = store.Freeze().Changes;
                Throws<InvalidDataException>(() => store.Apply(Response(sent[0], 1, "远端", "already_deleted"), sent));
                Throws<InvalidDataException>(() => store.Apply(new(1, 1, [null!], []), sent));
                Throws<System.Text.Json.JsonException>(() => ProtocolJson.Decode<LocalState>("{\"notes\":{},\"pending\":{}}"));
                Check(store.Snapshot().FrozenBatch.SequenceEqual(sent) && store.Snapshot().Notes[note.Id].Text == "不能丢的文字");
            });
            Test("merge save failure keeps frozen batch, later typing survives recovery", () =>
            {
                var store = New(out var file); var note = store.CreateDraft(); store.SetText(note.Id, "A"); var sent = store.Freeze().Changes; store.SetText(note.Id, "B"); file.Fail = true;
                Throws<IOException>(() => store.Apply(Response(sent[0], 6), sent)); Check(store.Snapshot().FrozenBatch.SequenceEqual(sent));
                store.SetText(note.Id, "C"); file.Fail = false; Check(store.RetrySave()); Check(store.Freeze().Changes.SequenceEqual(sent));
                store.Apply(Response(sent[0], 6), sent); Check(store.Snapshot().Notes[note.Id].Text == "C");
            });
            Test("draft discard failure keeps a valid editing target", () =>
            {
                var store = New(out var file); var note = store.CreateDraft(); file.Fail = true; Check(!store.DiscardDraft(note.Id));
                Check(store.Snapshot().Notes.ContainsKey(note.Id)); file.Fail = false; store.SetText(note.Id, "取消退出后继续输入"); Check(store.LastSaved);
            });
            Test("malformed and missing receipts never clear frozen data", () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "A"); var sent = store.Freeze().Changes;
                Throws<InvalidDataException>(() => store.Apply(new(1, 1, [], []), sent)); Check(store.Snapshot().FrozenBatch.SequenceEqual(sent));
                var good = Response(sent[0], 1); Throws<InvalidDataException>(() => store.Apply(good with { Results = [good.Results[0], good.Results[0]] }, sent));
                Check(store.Snapshot().Notes[note.Id].Text == "A");
            });
            Test("IME-style stale basis preserves text against remote edits and tombstones", () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "基准"); var sent = store.Freeze().Changes; store.Apply(Response(sent[0], 5), sent); var basis = store.Snapshot().Notes[note.Id];
                store.Apply(new(1, 9, [basis with { Text = "远端新内容", Revision = 9, Deleted = true }], []), []);
                store.SetText(note.Id, "基准正式选字", basis); Check(store.Snapshot().Pending[note.Id].BaseRevision == 5 && !store.Snapshot().Notes[note.Id].Deleted);
            });
            Test("atomic real-file persistence, device ID, backup and corruption preservation", () =>
            {
                string directory = Path.Combine(AppContext.BaseDirectory, "test-data", Guid.NewGuid().ToString("N"));
                try
                {
                    var file = new AtomicStateFile(directory); var store = new LocalStore(file); var note = store.CreateDraft(); store.SetText(note.Id, "真实原子文件 中文 📝");
                    Check(store.LastSaved, store.SaveError ?? "Atomic save failed");
                    var restart = new LocalStore(file); Check(restart.Snapshot().DeviceId == store.Snapshot().DeviceId && restart.Snapshot().Notes[note.Id].Text == "真实原子文件 中文 📝");
                    Check(File.Exists(Path.Combine(directory, "state.previous.json"))); File.WriteAllText(Path.Combine(directory, "state.json"), "{broken");
                    Throws<System.Text.Json.JsonException>(() => new LocalStore(file)); Check(File.ReadAllText(Path.Combine(directory, "state.json")) == "{broken");
                }
                finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
            });
            Test("attachment-only notes persist, frozen metadata and later removal survive conflict remap", () =>
            {
                var store = New(out var file); var note = store.CreateDraft();
                var a = new Attachment(Guid.NewGuid().ToString(), "虚构文件.txt", 0, new string('a', 64));
                Check(!ProtocolJson.Encode(Change.From(note)).Contains("attachments"));
                store.AddAttachment(note.Id, a); store.DiscardDraft(note.Id);
                Check(store.Snapshot().Notes.ContainsKey(note.Id) && !store.Snapshot().DraftIds.Contains(note.Id));
                var sent = store.Freeze().Changes; store.RemoveAttachment(note.Id, a.Id);
                Check(sent[0].Attachments!.Single() == a && store.Snapshot().Pending[note.Id].Attachments!.Length == 0);
                var copy = Guid.NewGuid().ToString(); store.Apply(Response(sent[0], 4, status: "conflict_copy", target: copy), sent);
                Check(store.Snapshot().Pending[copy].Attachments!.Length == 0 && store.Snapshot().Notes[copy].Attachments!.Length == 0);
                var restart = new LocalStore(file); Check(restart.Snapshot().Pending[copy].BaseRevision == 4);
                var basis = restart.Snapshot().Notes[copy]; restart.AddAttachment(copy, a);
                restart.SetText(copy, "正式选字", basis with { Attachments = restart.Snapshot().Notes[copy].Attachments });
                Check(restart.Snapshot().Notes[copy].Attachments!.Single() == a);
                Throws<InvalidDataException>(() => restart.AddAttachment(copy, a with { Name = "../unsafe" }));
            });
            await Test("imported attachment survives source removal; corrupt download never replaces destination", async () =>
            {
                var directory = Path.Combine(AppContext.BaseDirectory, "test-data", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
                try
                {
                    using var client = new HttpClient(new BadFile());
                    var files = new AttachmentFiles(directory, new("https://example.invalid", new string('x', 32)), client);
                    string source = Path.Combine(directory, "fixture.bin"), destination = Path.Combine(directory, "saved.bin");
                    byte[] bytes = [0, 1, 2, 255, 128]; await File.WriteAllBytesAsync(source, bytes);
                    var a = await files.Import(source);
                    using (var inFlight = new FileStream(Path.Combine(directory, "attachments", a.Sha256), FileMode.Open, FileAccess.Read, FileShare.Read))
                    { var repeated = await files.Import(source); Check(repeated.Sha256 == a.Sha256 && repeated.Id != a.Id); }
                    File.Delete(source); await files.Download(a, destination);
                    Check((await File.ReadAllBytesAsync(destination)).SequenceEqual(bytes));
                    var damaged = a with { Sha256 = new string('b', 64) }; bool rejected = false;
                    try { await files.Download(damaged, destination); } catch (IOException) { rejected = true; }
                    Check(rejected && (await File.ReadAllBytesAsync(destination)).SequenceEqual(bytes));
                    Check(!File.Exists(Path.Combine(directory, "attachments", damaged.Sha256)));
                    Check(!Directory.GetFiles(Path.Combine(directory, "attachments"), "*.tmp").Any());
                }
                finally { Directory.Delete(directory, true); }
            });
            await Test("unsupported health bodies and cache permission failures keep attachments pending with an error", async () =>
            {
                foreach (var body in new[] { "[]", "null", "1", "{}", "{\"features\":[1]}" })
                {
                    using var client = new HttpClient(new FixedBody(body));
                    var files = new AttachmentFiles(AppContext.BaseDirectory, new("https://example.invalid", new string('x', 32)), client);
                    bool refused = false; try { await files.CheckSupport(default); } catch (IOException) { refused = true; }
                    Check(refused, "Unsupported health response was accepted");
                }
                var store = New(out _); var note = store.CreateDraft();
                store.AddAttachment(note.Id, new(Guid.NewGuid().ToString(), "fixture.txt", 1, new string('a', 64)));
                using var sync = new SyncService(store, new("https://example.invalid", new string('x', 32)), new HttpClient(new DeniedFile()), attachmentDirectory: AppContext.BaseDirectory);
                await sync.Sync(true);
                for (int i = 0; i < 20 && sync.UploadingAttachments; i++) await Task.Delay(10);
                Check(!sync.UploadingAttachments && sync.AttachmentStatus?.Contains("Injected permission") == true);
                Check(store.Snapshot().Pending.ContainsKey(note.Id) && store.Snapshot().FrozenBatch.Length == 0);
            });
            await Test("accepted response lost, continued editing, restart replays exact op before later edit", async () =>
            {
                var store = New(out var file); var note = store.CreateDraft(); store.SetText(note.Id, "A"); var server = new FakeServer { LoseFirst = true };
                using (var sync = new SyncService(store, new("https://example.invalid", new string('x', 32)), new HttpClient(server))) await sync.Sync(true);
                var original = store.Snapshot().FrozenBatch.Single(); store.SetText(note.Id, "B"); var restart = new LocalStore(file);
                using var second = new SyncService(restart, new("https://example.invalid", new string('x', 32)), new HttpClient(server));
                await second.Sync(true); Check(server.Requests[0] == server.Requests[1]); Check(restart.Snapshot().Pending[note.Id].BaseRevision == 1);
                await second.Sync(true); Check(server.Applied == 2 && server.Notes[note.Id].Text == "B" && restart.Snapshot().FrozenBatch.Length == 0);
            });
            await Test("concurrent manual/periodic/debounce triggers share one HTTP request", async () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "A"); var server = new FakeServer { Delay = 100 };
                using var sync = new SyncService(store, new("https://example.invalid", new string('x', 32)), new HttpClient(server));
                await Task.WhenAll(sync.Sync(true), sync.Sync(true), sync.Sync(true)); Check(server.Requests.Count == 1);
            });
            await Test("invalid 200 response stays inside Sync and keeps the frozen operation", async () =>
            {
                var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "不能丢"); var frozen = store.Freeze().Changes;
                using var sync = new SyncService(store, new("https://example.invalid", new string('x', 32)), new HttpClient(new FixedBody("{\"protocol\":1,\"sequence\":1,\"notes\":[],\"results\":[]}")));
                await sync.Sync(true);
                Check(!sync.Syncing && sync.Status != "正在同步…" && sync.Error != null && sync.Error.Contains("无效"));
                Check(store.Snapshot().FrozenBatch.SequenceEqual(frozen));
                await sync.Sync(true);
                Check(!sync.Syncing && sync.Status != "正在同步…" && sync.Error != null && sync.Error.Contains("无效") && store.Snapshot().FrozenBatch.SequenceEqual(frozen));
            });
            }
            var endpoint = args.SkipWhile(a => a != "--integration").Skip(1).FirstOrDefault();
            if (endpoint != null)
            {
                await Test("real Node protocol integration: C# create/update, remote conflict and stale deletion", async () =>
                {
                    var uri = new Uri(endpoint); Check(uri.IsLoopback && uri.Scheme == "http", "Integration must be loopback HTTP");
                    var store = New(out _); var note = store.CreateDraft(); store.SetText(note.Id, "Windows 初稿 中文 📝");
                    using var sync = new SyncService(store, new(endpoint, new string('t', 64)), allowLoopbackHttp: true); await sync.Sync(true); Check(sync.Error == null);
                    var old = store.Snapshot().Notes[note.Id];
                    using var client = new HttpClient(); client.DefaultRequestHeaders.Authorization = new("Bearer", new string('t', 64));
                    var remote = Change.From(old with { Text = "Mac 模拟新内容" });
                    using var response = await client.PostAsync(endpoint + "/v1/sync", new StringContent(ProtocolJson.Encode(new SyncRequest("remote-test-device", [remote])), Encoding.UTF8, "application/json")); response.EnsureSuccessStatusCode();
                    store.SetText(note.Id, "Windows 离线续写", old); await sync.Sync(true); Check(sync.Error == null && store.Snapshot().Notes.Values.Any(n => n.ConflictOf == note.Id && n.Text == "Windows 离线续写"));
                    store.SetText(note.Id, old.Text, old); store.Delete(note.Id); await sync.Sync(true); Check(store.Snapshot().DeleteConflictIds.Contains(note.Id));
                    Check(store.Snapshot().Notes[note.Id].Text == "Mac 模拟新内容" && !store.Snapshot().Notes[note.Id].Deleted);
                });
                await Test("real Node file integration: upload leaves text syncing and another device downloads", async () =>
                {
                    var directory = Path.Combine(AppContext.BaseDirectory, "test-data", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
                    try
                    {
                        var store = New(out _); using var sync = new SyncService(store, new(endpoint, new string('t', 64)), allowLoopbackHttp: true, attachmentDirectory: directory);
                        var source = Path.Combine(directory, "fixture.bin"); var bytes = Encoding.UTF8.GetBytes("虚构跨端附件\0中文 📝"); await File.WriteAllBytesAsync(source, bytes);
                        var a = await sync.Files!.Import(source); var note = store.CreateDraft(); store.AddAttachment(note.Id, a);
                        var plain = store.CreateDraft(); store.SetText(plain.Id, "附件上传同时同步文字");
                        await sync.Sync(true);
                        Check(!store.Snapshot().Pending.ContainsKey(plain.Id), sync.Error ?? "Plain text was blocked by upload");
                        for (int i = 0; i < 60 && (store.Snapshot().Pending.Count != 0 || store.Snapshot().FrozenBatch.Length != 0); i++)
                        { await Task.Delay(100); await sync.Sync(); }
                        Check(store.Snapshot().Notes[note.Id].Revision > 0 && store.Snapshot().Pending.Count == 0, sync.AttachmentStatus ?? sync.Error ?? "Attachment did not sync");
                        var other = Path.Combine(directory, "other-device"); using var client = new HttpClient();
                        var receiver = new AttachmentFiles(other, new(endpoint, new string('t', 64)), client);
                        var saved = Path.Combine(directory, "received.bin"); await receiver.Download(a, saved); Check((await File.ReadAllBytesAsync(saved)).SequenceEqual(bytes));
                        // The server HEAD makes a repeated upload idempotent without a local source cache.
                        await receiver.Upload(a, default);
                        store.RemoveAttachment(note.Id, a.Id); await sync.Sync(true);
                        Check(store.Snapshot().Notes[note.Id].Attachments!.Length == 0 && store.Snapshot().Pending.Count == 0);
                    }
                    finally { Directory.Delete(directory, true); }
                });
            }
            Console.WriteLine($"CORE_TESTS_OK: {passed} tests"); return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }
}

sealed class MemoryFile : IStateFile
{
    public LocalState? Data;
    public bool Fail;
    public LocalState? Read() => Data?.Copy();
    public void Write(LocalState state) { if (Fail) throw new IOException("Injected disk failure"); Data = state.Copy(); }
}
sealed class FixedBody : HttpMessageHandler
{
    readonly string body;
    public FixedBody(string body) => this.body = body;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) =>
        Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
}
sealed class BadFile : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) =>
        Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new byte[5]) });
}
sealed class DeniedFile : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
    {
        if (request.RequestUri!.AbsolutePath == "/health")
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"features\":[\"attachments\"]}") });
        if (request.Method == HttpMethod.Head) throw new UnauthorizedAccessException("Injected permission failure");
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(ProtocolJson.Encode(new SyncResponse(1, 0, [], []))) });
    }
}
sealed class FakeServer : HttpMessageHandler
{
    public bool LoseFirst;
    public int Delay, Applied;
    public List<string> Requests { get; } = [];
    public Dictionary<string, Note> Notes { get; } = [];
    readonly Dictionary<string, (Change Payload, Receipt Result)> operations = [];
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
    {
        string text = await request.Content!.ReadAsStringAsync(cancellation); Requests.Add(text);
        if (Delay > 0) await Task.Delay(Delay, cancellation);
        var input = ProtocolJson.Decode<SyncRequest>(text); var results = new List<Receipt>();
        foreach (var op in input.Changes)
        {
            if (operations.TryGetValue(op.OpId, out var old)) { if (old.Payload != op) return new(HttpStatusCode.Conflict); results.Add(old.Result); continue; }
            Applied++; var note = new Note(op.NoteId, op.Text, op.Color, op.Pinned, Applied, DateTimeOffset.UtcNow.ToString("O"), op.Deleted);
            Notes[note.Id] = note; var receipt = new Receipt(op.OpId, op.NoteId, Applied, "applied"); operations[op.OpId] = (op, receipt); results.Add(receipt);
        }
        if (LoseFirst) { LoseFirst = false; throw new HttpRequestException("Injected lost response after server commit"); }
        return new(HttpStatusCode.OK) { Content = new StringContent(ProtocolJson.Encode(new SyncResponse(1, Applied, Notes.Values.ToArray(), results.ToArray())), Encoding.UTF8, "application/json") };
    }
}
