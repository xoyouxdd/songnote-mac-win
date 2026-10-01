# SongNote 同步协议 v1

Mac 和 Windows 使用同一协议。单人使用，无账号和登录页面；两端安装时预置同一份私有密钥。所有公网请求使用标准 HTTPS 证书校验，不关闭证书验证。

## 地址与配置

- 生产地址：`https://124.220.229.9/songnote`
- 健康检查：`GET /health`，不含任何便签数据。
- 数据请求：`Authorization: Bearer <token>`。
- 配置包含 `base_url` 和 `token`；真实配置在服务器 `C:\便签\private\client-config.json`，通过管理员 SSH/SFTP 私下获取，不能提交 GitHub。
- 客户端配置模板：[client-config.example.json](../windows/client-config.example.json)。服务和数据位于 `C:\便签`；内部端口为 `127.0.0.1:18084`。

## 数据结构

便签字段如下：

| 字段 | 类型 | 规则 |
| --- | --- | --- |
| id | string | 客户端生成 UUID，首次提交之前即可离线使用 |
| text | string | 纯文本，最多 100000 个 UTF-16 单元；第一行作为列表标题 |
| color | string | yellow / green / blue / pink / purple / gray |
| pinned | boolean | 列表置顶，同步到两端 |
| revision | integer | 服务器全局递增版本，不使用设备时间判断新旧 |
| updated_at | string | 服务器 UTC ISO 8601 时间 |
| deleted | boolean | 删除墓碑，必须保存，不能自行清理 |
| conflict_of | string or null | 冲突副本对应的原始便签 ID |

窗口位置、尺寸、打开状态和窗口置顶只存本机；不要跨 Windows/Mac 同步坐标。便签内容、颜色、列表置顶和删除状态同步。

## 读取

`GET /v1/snapshot` 返回 `{ "protocol": 1, "sequence": 版本号, "notes": [...] }`。

`notes` 包含所有便签和删除墓碑。只展示 `deleted=false` 的条目。

## 双向同步

`POST /v1/sync`，JSON 格式：

```json
{
  "device_id": "每个安装实例固定的UUID",
  "changes": [{
    "op_id": "本次操作唯一UUID",
    "note_id": "便签UUID",
    "base_revision": 0,
    "text": "便签正文",
    "color": "yellow",
    "pinned": false,
    "deleted": false
  }]
}
```

响应包含 `protocol`、`sequence`、`notes` 完整快照和 `results` 操作回执：

```json
{
  "op_id": "操作UUID",
  "note_id": "最终便签UUID",
  "revision": 42,
  "status": "applied"
}
```

`status` 可为：

- `applied`：正常写入。
- `conflict_copy`：版本冲突，服务器保留原内容，将本次编辑保存成新 UUID 的副本；副本 `conflict_of` 指向原便签。客户端应把正在编辑的窗口关联到回执返回的新 UUID。
- `delete_conflict`：删除基于旧版本，服务器保留另一端的新内容。取消本地删除队列，并重新展示该便签，提示用户。
- `already_deleted`：已经删除，视为成功，不产生新的版本。

新便签使用 `base_revision=0`；已有便签使用本地最近确认的服务器版本。删除也要提交完整字段，只将 `deleted` 设为 true。

## 客户端必须遵守的处理顺序

1. 每次编辑先原子保存本地便签和待同步队列，再触发网络请求；断网/退出不能丢失队列。
2. 同一便签未发送的编辑可合并；请求发出后冻结其 `op_id` 与载荷，网络失败重试必须发送完全相同的操作。
3. 用户在请求过程中继续输入，保留为新的待提交操作，不能用响应快照覆盖。收到旧操作回执后，将新操作的 `base_revision` 改为回执版本；如果返回冲突副本，同时迁移 ID 和编辑窗口。
4. 根据回执只清除对应已确认操作；以服务器完整快照为基础，再叠加未确认的本地编辑。尚未提交的离线编辑不得因为读取了新快照就自动改基准版本，否则会静默覆盖另一端编辑。
5. 响应合并结果和队列必须一起原子落盘，再更新界面。未成功落盘时停止后续提交并提示用户。
6. 每 3 秒同步一次；编辑后约 700ms 合并提交；退避重试 2～30 秒。退出不等待网络，本机队列在下次启动继续同步。
7. 每批建议最多 4 条，HTTP 请求不超过 2 MiB。服务端接受最多 100 条，但仍受请求大小限制。

操作回执在服务端持久保存；同一设备重试相同 `op_id` 与载荷只应用一次。不同载荷或不同设备复用 `op_id` 返回 409。一个批次验证失败时不写入任何操作。

## 错误与边界

- 400：字段错误或 JSON 无效；提示错误，不丢弃本地内容。
- 401：私有密钥错误；停止把它当普通离线问题，提示同步配置无效。
- 409：操作 ID 被错误复用；保留待同步内容，修复客户端的队列逻辑。
- 413：请求过大；拆小批次或缩短单条内容。
- 5xx / 超时：保存本地内容，重试原操作。
- 并发合并是“整条便签保留冲突副本”，不是逐字协同编辑。
- 服务端 SQLite 使用 WAL 和 FULL 同步；每小时备份一份，保留最近 48 份。这是同机备份，不替代异地备份。
- 本版本采用纯文本；暂不含图片、附件和富文本。

## 运行与验证

服务端要求 Node.js 24.15 或以上，使用内置 [node:sqlite](https://nodejs.org/download/release/latest-v24.x/docs/api/sqlite.html)，无需 npm 依赖。

本地运行核心测试：`node --test tests/server.test.mjs`。

服务器启动任务：`SongNoteServer`；备份任务：`SongNoteBackup`。安装脚本为 `server/install.ps1`，须管理员运行。真实 `server/config.json` 必须私下配置，不放进仓库。
