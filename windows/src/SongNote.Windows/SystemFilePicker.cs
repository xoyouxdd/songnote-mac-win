using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace SongNote.Windows;

internal sealed class SystemFilePicker(string? initialDirectory) : IDisposable
{
    readonly CancellationTokenSource lifetime = new();
    public Task<string[]?> Select(bool save, string? name) => Execute(save ? "save" : "open", name, lifetime.Token);
    internal Task<string[]?> Check(string action, string directory, CancellationToken cancellation = default) => Execute(action, null, cancellation, directory);
    async Task<string[]?> Execute(string action, string? name, CancellationToken cancellation, string? directoryOverride = null)
    {
        if (cancellation.IsCancellationRequested) return null;
        var executable = Path.Combine(AppContext.BaseDirectory, "SongNote.FilePicker.exe");
        if (!File.Exists(executable)) throw new IOException("缺少系统文件选择器组件，请重新构建或更新程序。");
        var nonce = Guid.NewGuid().ToString("N");
        using var parent = Process.GetCurrentProcess();
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        var directory = directoryOverride ?? initialDirectory ?? Path.Combine(Environment.GetEnvironmentVariable("USERPROFILE") ?? AppContext.BaseDirectory, "Downloads");
        foreach (var value in new[] { action, nonce, directory, name ?? "", parent.Id.ToString(), parent.StartTime.ToUniversalTime().Ticks.ToString() }) start.ArgumentList.Add(value);
        using var child = Process.Start(start) ?? throw new IOException("系统文件选择框未能启动。");
        try
        {
            var output = ReadBounded(child.StandardOutput, cancellation);
            var errors = ReadBounded(child.StandardError, cancellation);
            var exit = child.WaitForExitAsync(cancellation);
            // A malformed/oversized stream must not leave a helper waiting forever.
            var pending = new List<Task> { output, errors, exit };
            while (!exit.IsCompleted)
            {
                var completed = await Task.WhenAny(pending).ConfigureAwait(false); await completed.ConfigureAwait(false);
                if (completed == exit) break;
                pending.Remove(completed);
            }
            await exit.ConfigureAwait(false); await errors.ConfigureAwait(false);
            var json = await output.ConfigureAwait(false);
            if (child.ExitCode != 0) throw new IOException($"系统选择框异常退出（{child.ExitCode:X8}），便签内容已保留，请重试。");
            return Decode(json, action, nonce);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return null; }
        catch (JsonException) { throw new InvalidDataException("系统文件选择框返回无效结果，请重试。"); }
        finally
        {
            if (!child.HasExited)
            {
                child.CloseMainWindow();
                var stopping = child.WaitForExitAsync();
                if (await Task.WhenAny(stopping, Task.Delay(500)).ConfigureAwait(false) != stopping && !child.HasExited) child.Kill(false);
                await stopping.ConfigureAwait(false);
            }
        }
    }
    static async Task<string> ReadBounded(StreamReader reader, CancellationToken cancellation)
    {
        var result = new StringBuilder(); var buffer = new char[4096]; int read;
        while ((read = await reader.ReadAsync(buffer.AsMemory(), cancellation).ConfigureAwait(false)) != 0)
        {
            if (result.Length + read > 1024 * 1024) throw new InvalidDataException("系统文件选择框返回结果过大。");
            result.Append(buffer, 0, read);
        }
        return result.ToString();
    }
    internal static string[]? Decode(string json, string action, string nonce)
    {
        using var document = JsonDocument.Parse(json); var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("schema", out var schema) || schema.ValueKind != JsonValueKind.Number || !schema.TryGetInt32(out var version) || version != 1 ||
            !root.TryGetProperty("action", out var a) || a.ValueKind != JsonValueKind.String || a.GetString() != action ||
            !root.TryGetProperty("nonce", out var n) || n.ValueKind != JsonValueKind.String || n.GetString() != nonce ||
            !root.TryGetProperty("status", out var status) || status.ValueKind != JsonValueKind.String ||
            !root.TryGetProperty("paths", out var paths) || paths.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("系统文件选择框返回结果不匹配。");
        if (status.GetString() == "canceled" && paths.GetArrayLength() == 0) return null;
        var limit = action.EndsWith("save", StringComparison.Ordinal) ? 1 : 20;
        if (status.GetString() != "selected" || paths.GetArrayLength() == 0 || paths.GetArrayLength() > limit)
            throw new InvalidDataException("系统文件选择框返回文件数量无效。");
        var values = paths.EnumerateArray().Select(p => p.ValueKind == JsonValueKind.String ? p.GetString() : null).ToArray();
        if (values.Any(p => string.IsNullOrWhiteSpace(p) || p.Length > 32767 || p.Contains('\0') || !Path.IsPathFullyQualified(p)))
            throw new InvalidDataException("系统文件选择框返回路径无效。");
        return values.Select(p => p!).ToArray();
    }
    public void Dispose() { lifetime.Cancel(); }
}
