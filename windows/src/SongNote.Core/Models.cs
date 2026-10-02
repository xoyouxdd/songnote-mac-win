using System.Text.Json;
using System.Text.Json.Serialization;

namespace SongNote.Core;

public sealed record Note(string Id, string Text, string Color, bool Pinned, int Revision,
    string UpdatedAt, bool Deleted, string? ConflictOf = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] Attachment[]? Attachments = null)
{
    [JsonIgnore] public string[] DisplayLines => Text.Split(['\r', '\n', '\u2028', '\u2029'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
    [JsonIgnore] public string Title => DisplayLines.FirstOrDefault() ?? "新便签";
    public static Note Blank() => new(Guid.NewGuid().ToString(), "", "yellow", false, 0, DateTimeOffset.UtcNow.ToString("O"), false);
}
public sealed record Change(string OpId, string NoteId, int BaseRevision, string Text, string Color, bool Pinned, bool Deleted,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] Attachment[]? Attachments = null)
{
    public static Change From(Note note) => new(Guid.NewGuid().ToString(), note.Id, note.Revision, note.Text, note.Color, note.Pinned, note.Deleted, note.Attachments == null ? null : [.. note.Attachments]);
}
public sealed record Attachment(string Id, string Name, long Size, string Sha256)
{
    public const long MaxBytes = 20 * 1024 * 1024;
    public void Validate()
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(Id ?? "", "^[a-zA-Z0-9_-]{8,80}\\z") ||
            string.IsNullOrEmpty(Name) || Name.Length > 255 || Name is "." or ".." || Name.Any(c => c is '/' or '\\' || c < 32 || c == 127) ||
            Size < 0 || Size > MaxBytes || !System.Text.RegularExpressions.Regex.IsMatch(Sha256 ?? "", "^[a-f0-9]{64}\\z"))
            throw new InvalidDataException("附件信息无效。");
    }
    public static void ValidateList(Attachment[]? values)
    {
        if (values == null) return;
        if (values.Length > 20 || values.Any(a => a == null) || values.Select(a => a.Id).Distinct().Count() != values.Length)
            throw new InvalidDataException("每条便签最多 20 个附件，附件 ID 不得重复。");
        foreach (var a in values) a.Validate();
    }
}
public sealed record Receipt(string OpId, string NoteId, int Revision, string Status);
public sealed record SyncRequest(string DeviceId, Change[] Changes);
public sealed record SyncResponse(int Protocol, int Sequence, Note[] Notes, Receipt[] Results);
public sealed record Configuration(string BaseUrl, string Token)
{
    public void Validate(bool allowLoopbackHttp = false)
    {
        if (!Uri.TryCreate(BaseUrl, UriKind.Absolute, out var url) ||
            (url.Scheme != "https" && !(allowLoopbackHttp && url.Scheme == "http" && url.IsLoopback)) ||
            !string.IsNullOrEmpty(url.UserInfo) || !string.IsNullOrEmpty(url.Query) || !string.IsNullOrEmpty(url.Fragment) ||
            string.IsNullOrWhiteSpace(Token) || Token.Length < 32 || Token.Any(char.IsWhiteSpace))
            throw new InvalidDataException("同步配置无效：需要 HTTPS 地址和有效私有密钥。");
    }
}
public sealed record Placement(double Left, double Top, double Width, double Height, bool Topmost = false);
public sealed class LocalState
{
    public int Schema { get; set; } = 1;
    [JsonRequired] public string DeviceId { get; set; } = Guid.NewGuid().ToString();
    [JsonRequired] public Dictionary<string, Note> Notes { get; set; } = [];
    [JsonRequired] public Dictionary<string, Change> Pending { get; set; } = [];
    public Change[] FrozenBatch { get; set; } = [];
    public HashSet<string> DraftIds { get; set; } = [];
    public HashSet<string> DeleteConflictIds { get; set; } = [];
    public Dictionary<string, Placement> Windows { get; set; } = [];
    public HashSet<string> OpenNotes { get; set; } = [];
    public bool TrayHintShown { get; set; }
    public LocalState Copy() => new()
    {
        Schema = Schema, DeviceId = DeviceId, Notes = new(Notes), Pending = new(Pending), FrozenBatch = [.. FrozenBatch],
        DraftIds = new(DraftIds), DeleteConflictIds = new(DeleteConflictIds), Windows = new(Windows),
        OpenNotes = new(OpenNotes), TrayHintShown = TrayHintShown
    };
    public Note[] Visible() => Notes.Values.Where(n => !n.Deleted).OrderByDescending(n => n.Pinned)
        .ThenByDescending(n => n.UpdatedAt, StringComparer.Ordinal).ThenBy(n => n.Id, StringComparer.Ordinal).ToArray();
}
public static class ProtocolJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = false
    };
    public static string Encode<T>(T value) => JsonSerializer.Serialize(value, Options);
    public static T Decode<T>(string value) => JsonSerializer.Deserialize<T>(value, Options) ?? throw new InvalidDataException("数据为空。");
}
