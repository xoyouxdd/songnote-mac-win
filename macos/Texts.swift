import Foundation

// Status copy shared word-for-word with Windows (SongNote.Core/Texts.cs) and docs/UI_GUIDELINES.md.
enum Texts {
    static let connecting = "正在连接…"
    static let syncing = "正在同步…"
    static let waiting = "等待同步"
    static let offline = "离线 · 内容已保存在本机"
    static let offlineWaiting = "离线 · 等待同步"
    static let badToken = "同步密钥无效"
    static let badResponse = "同步响应无效 · 稍后重试"
    static let saveFailed = "本地保存失败，请勿退出"
    static let savePaused = "同步已暂停，等待本地保存"
    static let draft = "本机草稿 · 关闭空白窗口自动丢弃"
    static let conflictCopy = "检测到冲突 · 已保留两份内容"
    static let deleteRejected = "删除未执行 · 已保留另一端的新内容"
    static let attachmentRetry = "附件传输失败 · 文件已保留待重试"
    static func failed(_ code: Int) -> String { "同步失败（\(code)）· 稍后重试" }
    static func synced(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        return "已同步 · " + formatter.string(from: date)
    }
}
