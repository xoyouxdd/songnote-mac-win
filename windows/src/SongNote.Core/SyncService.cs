using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace SongNote.Core;

public sealed class SyncService : IDisposable
{
    readonly LocalStore store;
    readonly Configuration? configuration;
    readonly HttpClient client;
    readonly SemaphoreSlim single = new(1, 1);
    readonly CancellationTokenSource lifetime = new();
    CancellationTokenSource? debounce;
    DateTimeOffset retryAfter;
    int failures;
    Task? uploadTask;
    DateTimeOffset fileRetryAfter;
    volatile bool attachmentSupported;
    readonly System.Collections.Concurrent.ConcurrentDictionary<string, byte> uploaded = new();
    public AttachmentFiles? Files { get; }
    public string? AttachmentStatus { get; private set; }
    public bool UploadingAttachments { get; private set; }
    public bool Syncing { get; private set; }
    public bool ShowProgress { get; private set; }
    public string Status { get; private set; } = "已保存到本机 · 尚未配置同步";
    public string? Error { get; private set; }
    public DateTimeOffset? LastSyncAt { get; private set; }
    public event Action? Changed;
    public SyncService(LocalStore store, Configuration? configuration, HttpClient? client = null, bool allowLoopbackHttp = false, string? attachmentDirectory = null)
    {
        this.store = store; this.configuration = configuration; configuration?.Validate(allowLoopbackHttp);
        this.client = client ?? new HttpClient(); this.client.Timeout = TimeSpan.FromSeconds(120);
        var directory = attachmentDirectory ?? store.DirectoryPath;
        if (directory != null) Files = new(directory, configuration, this.client);
    }
    public void Start() { _ = Poll(); }
    async Task Poll()
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(3));
            await Sync(); while (await timer.WaitForNextTickAsync(lifetime.Token)) await Sync();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }
    public void AfterEdit()
    {
        debounce?.Cancel(); debounce?.Dispose(); debounce = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        _ = Delayed(debounce.Token);
    }
    async Task Delayed(CancellationToken cancellation)
    {
        try { await Task.Delay(700, cancellation); await Sync(); }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
    }
    public async Task Sync(bool force = false)
    {
        if (force && !store.LastSaved && !store.RetrySave()) { Changed?.Invoke(); return; }
        if (configuration == null) { Status = "已保存到本机 · 尚未配置同步"; Changed?.Invoke(); return; }
        if (!store.LastSaved || (!force && DateTimeOffset.UtcNow < retryAfter) || !await single.WaitAsync(0)) return;
        try
        {
            if (force) fileRetryAfter = default;
            BeginUploads();
            var snapshot = store.Snapshot();
            if (snapshot.FrozenBatch.Any(c => !Ready(c))) return;
            var payload = store.Freeze(Ready); Syncing = true; ShowProgress = force || payload.Changes.Length != 0;
            if (ShowProgress) { Status = "正在同步…"; Changed?.Invoke(); }
            using var request = new HttpRequestMessage(HttpMethod.Post, configuration.BaseUrl.TrimEnd('/') + "/v1/sync");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", configuration.Token);
            request.Content = new StringContent(ProtocolJson.Encode(payload), Encoding.UTF8, "application/json");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); timeout.CancelAfter(TimeSpan.FromSeconds(12));
            using var response = await client.SendAsync(request, timeout.Token);
            if (response.StatusCode != HttpStatusCode.OK)
            {
                var error = response.StatusCode == HttpStatusCode.Unauthorized ? "同步密钥无效" : $"同步失败（{(int)response.StatusCode}）";
                throw new SyncFailure(error);
            }
            var data = await response.Content.ReadAsStringAsync(lifetime.Token);
            var result = ProtocolJson.Decode<SyncResponse>(data);
            store.Apply(result, payload.Changes);
            failures = 0; retryAfter = default; Error = null; LastSyncAt = DateTimeOffset.Now;
            var current = store.Snapshot();
            Status = current.Pending.Count > 0 ? "已保存到本机 · 等待同步" : $"已同步 · {LastSyncAt:HH:mm}";
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException or System.Text.Json.JsonException or SyncFailure or InvalidDataException)
        {
            failures++; retryAfter = DateTimeOffset.UtcNow.AddSeconds(Math.Min(30, Math.Pow(2, Math.Min(failures, 5))));
            Error = e is InvalidDataException ? "同步响应无效 · 稍后重试" : e is HttpRequestException or TaskCanceledException ? "离线 · 内容已保存在本机" : e is SyncFailure ? e.Message : "同步响应或本地保存失败 · 保留队列待重试";
            Status = Error;
        }
        finally { Syncing = false; single.Release(); Changed?.Invoke(); }
    }
    bool Ready(Change c) => c.Attachments == null || (Files == null && c.Attachments.Length == 0) || (attachmentSupported && c.Attachments.All(a => uploaded.ContainsKey(a.Sha256)));
    void BeginUploads()
    {
        if (Files == null || (uploadTask != null && !uploadTask.IsCompleted) || DateTimeOffset.UtcNow < fileRetryAfter) return;
        var state = store.Snapshot();
        var pending = state.FrozenBatch.Concat(state.Pending.Values).Where(c => !Ready(c)).ToArray();
        if (pending.Length != 0) uploadTask = UploadPending(pending);
    }
    async Task UploadPending(Change[] pending)
    {
        UploadingAttachments = true; AttachmentStatus = "正在准备附件…"; Changed?.Invoke();
        try
        {
            if (!attachmentSupported) { await Files!.CheckSupport(lifetime.Token); attachmentSupported = true; }
            string? firstError = null;
            foreach (var value in pending.SelectMany(c => c.Attachments ?? []).DistinctBy(a => a.Sha256))
            {
                if (uploaded.ContainsKey(value.Sha256)) continue;
                AttachmentStatus = "正在上传 · " + value.Name; Changed?.Invoke();
                try { await Files!.Upload(value, lifetime.Token); uploaded[value.Sha256] = 0; }
                catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { throw; }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or HttpRequestException or TaskCanceledException)
                { firstError ??= e is IOException or UnauthorizedAccessException ? e.Message : "附件传输失败 · 文件已保留待重试"; }
            }
            AttachmentStatus = firstError; fileRetryAfter = firstError == null ? default : DateTimeOffset.UtcNow.AddSeconds(15);
            AfterEdit();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        { AttachmentStatus = e is IOException or UnauthorizedAccessException ? e.Message : "附件传输失败 · 文件已保留待重试"; fileRetryAfter = DateTimeOffset.UtcNow.AddSeconds(15); }
        finally { UploadingAttachments = false; Changed?.Invoke(); }
    }
    sealed class SyncFailure(string message) : Exception(message);
    public void Dispose() { lifetime.Cancel(); debounce?.Cancel(); debounce?.Dispose(); client.Dispose(); }
}
