using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;

namespace SongNote.Core;

// Only SHA-256 values become cache paths; user filenames are display metadata.
public sealed class AttachmentFiles(string directory, Configuration? configuration, HttpClient client)
{
    readonly string root = Path.Combine(Path.GetFullPath(directory), "attachments");
    public async Task<Attachment> Import(string source, CancellationToken cancellation = default)
    {
        var info = new FileInfo(source);
        if (!info.Exists || info.Length > Attachment.MaxBytes) throw new IOException("单个附件不能超过 20 MiB。");
        Directory.CreateDirectory(root);
        var temp = Path.Combine(root, Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
            await using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
                await CopyBounded(input, output, cancellation);
            var size = new FileInfo(temp).Length;
            var hash = await Hash(temp, cancellation);
            var value = new Attachment(Guid.NewGuid().ToString(), info.Name, size, hash); value.Validate();
            var cached = Path.Combine(root, hash);
            // Do not replace a valid blob that a concurrent upload is reading.
            if (!File.Exists(cached) || new FileInfo(cached).Length != size || await Hash(cached, cancellation) != hash)
                File.Move(temp, cached, true);
            return value;
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    HttpRequestMessage Request(HttpMethod method, string endpoint)
    {
        if (configuration == null) throw new IOException("尚未配置同步，附件已保存在本机。");
        var request = new HttpRequestMessage(method, configuration.BaseUrl.TrimEnd('/') + endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", configuration.Token);
        return request;
    }
    public async Task CheckSupport(CancellationToken cancellation)
    {
        using var request = Request(HttpMethod.Get, "/health");
        using var response = await client.SendAsync(request, cancellation);
        if (response.StatusCode != HttpStatusCode.OK) throw new IOException($"附件连接失败（{(int)response.StatusCode}）");
        using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellation));
        if (body.RootElement.ValueKind != JsonValueKind.Object || !body.RootElement.TryGetProperty("features", out var features) || features.ValueKind != JsonValueKind.Array ||
            !features.EnumerateArray().Any(f => f.ValueKind == JsonValueKind.String && f.GetString() == "attachments"))
            throw new IOException("服务器尚未支持附件，文件保留在本机待传。");
    }
    public async Task Upload(Attachment value, CancellationToken cancellation)
    {
        value.Validate();
        using (var head = Request(HttpMethod.Head, "/v1/files/" + value.Sha256))
        using (var response = await client.SendAsync(head, cancellation))
        {
            if (response.StatusCode == HttpStatusCode.OK && response.Content.Headers.ContentLength == value.Size) return;
            if (response.StatusCode != HttpStatusCode.NotFound) throw new IOException($"附件查询失败（{(int)response.StatusCode}）");
        }
        var path = Path.Combine(root, value.Sha256);
        if (!File.Exists(path) || new FileInfo(path).Length != value.Size || await Hash(path, cancellation) != value.Sha256)
            throw new IOException("本机附件缺失或损坏，保留便签等待重试。");
        using var request = Request(HttpMethod.Put, "/v1/files/" + value.Sha256);
        request.Content = new StreamContent(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true));
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        using var result = await client.SendAsync(request, cancellation);
        if (result.StatusCode != HttpStatusCode.OK) throw new IOException($"附件上传失败（{(int)result.StatusCode}）· 文件已保留");
    }
    public async Task Download(Attachment value, string destination, CancellationToken cancellation = default)
    {
        value.Validate(); Directory.CreateDirectory(root);
        var cached = Path.Combine(root, value.Sha256);
        if (!File.Exists(cached) || new FileInfo(cached).Length != value.Size || await Hash(cached, cancellation) != value.Sha256)
        {
            var temp = Path.Combine(root, Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using var request = Request(HttpMethod.Get, "/v1/files/" + value.Sha256);
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
                if (response.StatusCode != HttpStatusCode.OK) throw new IOException($"附件下载失败（{(int)response.StatusCode}）");
                if (response.Content.Headers.ContentLength != value.Size) throw new IOException("附件大小不匹配。");
                await using (var stream = await response.Content.ReadAsStreamAsync(cancellation))
                await using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
                    await CopyBounded(stream, output, cancellation);
                if (new FileInfo(temp).Length != value.Size || await Hash(temp, cancellation) != value.Sha256)
                    throw new IOException("附件完整性校验失败，请重试。");
                File.Move(temp, cached, true);
            }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        var target = Path.GetFullPath(destination);
        var staging = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.Copy(cached, staging); File.Move(staging, target, true); }
        finally { if (File.Exists(staging)) File.Delete(staging); }
    }
    static async Task<string> Hash(string path, CancellationToken cancellation)
    {
        await using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, cancellation));
    }
    static async Task CopyBounded(Stream input, Stream output, CancellationToken cancellation)
    {
        var buffer = new byte[65536]; long total = 0; int read;
        while ((read = await input.ReadAsync(buffer, cancellation)) > 0)
        {
            total += read;
            if (total > Attachment.MaxBytes) throw new IOException("单个附件不能超过 20 MiB。");
            await output.WriteAsync(buffer.AsMemory(0, read), cancellation);
        }
        await output.FlushAsync(cancellation);
    }
}
