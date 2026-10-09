namespace SongNote.Core;

// Status copy shared word-for-word with the Mac (macos/Texts.swift) and docs/UI_GUIDELINES.md.
public static class Texts
{
    public const string Connecting = "正在连接…";
    public const string Syncing = "正在同步…";
    public const string Waiting = "等待同步";
    public const string Offline = "离线 · 内容已保存在本机";
    public const string OfflineWaiting = "离线 · 等待同步";
    public const string BadToken = "同步密钥无效";
    public const string BadResponse = "同步响应无效 · 稍后重试";
    public const string SaveFailed = "本地保存失败，请勿退出";
    public const string SavePaused = "同步已暂停，等待本地保存";
    public const string Draft = "本机草稿 · 关闭空白窗口自动丢弃";
    public const string ConflictCopy = "检测到冲突 · 已保留两份内容";
    public const string DeleteRejected = "删除未执行 · 已保留另一端的新内容";
    public const string AttachmentRetry = "附件传输失败 · 文件已保留待重试";
    public const string NotConfigured = "尚未配置同步 · 内容只保存在本机";
    public static string Failed(int code) => $"同步失败（{code}）· 稍后重试";
    public static string Synced(DateTimeOffset at) => $"已同步 · {at.ToLocalTime():HH:mm}";
}
