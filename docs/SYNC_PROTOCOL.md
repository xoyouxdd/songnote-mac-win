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
| attachments | array, optional | 附件描述；每条最多 20 个，旧数据缺省为空 |

窗口位置、尺寸、打开状态和窗口置顶只存本机；不要跨 Windows/Mac 同步坐标。便签内容、颜色、列表置顶、附件描述和删除状态同步。

## 附件扩展（2026-10-03）

保持 `protocol=1`，通过 `GET /health` 的 `features: ["attachments"]` 协商可选能力，同时返回 `version` 和 `max_file_bytes: 20971520`。旧客户端可继续编辑文字；新客户端必须确认服务器支持附件后才能发送明确带 `attachments` 的操作，避免旧服务器忽略字段造成文件丢失。

每个附件为 `{ "id": "UUID", "name": "文件名", "size": 字节数, "sha256": "小写64位SHA-256" }`。文件名最多 255 个 UTF-16 单元，不能含路径分隔符、控制字符，也不能为 `.` / `..`。单文件最多 20 MiB，每条最多 20 个；空文件可传。附件文件名不参与服务器或本机缓存路径，路径只使用 SHA-256。

- `PUT /v1/files/{sha256}`：二进制文件上传，须携带同一 Bearer 密钥；验证实际长度及 SHA-256，同 hash 重传只保存一份。成功返回 `{ "sha256": "...", "size": 字节数 }`。
- `HEAD /v1/files/{sha256}`：查询是否存在，200 的 Content-Length 为文件长度，404 表示未上传。
- `GET /v1/files/{sha256}`：下载二进制文件，鉴权与文字相同；客户端核对长度和 SHA-256 后原子保存，校验失败不覆盖目标文件。
- 服务端请求接收超时与客户端文件传输超时为 120 秒；上传最多同时 2 个，超过返回 429。文字提交仍受 2 MiB 限制。文件总数据上限 1 GiB，超过返回 507；这是 BLOB 数据量，SQLite/WAL 和备份占用另计。

客户端先将所选文件复制到本机专用缓存，再保存附件描述和待同步操作。附件上传在后台进行，其他便签可继续同步文字；仅附件已上传的操作能进入冻结批次。失败保存原文件与描述，稍后重试；移除附件或继续编辑形成新操作，不修改已冻结载荷。添加附件会把空白草稿转成正式便签，空正文的附件便签不会在关窗时丢弃。下载按需进行，不自动执行附件。

`attachments` 也可以出现在 change 中：**缺省表示保留服务器当前附件，明确 `[]` 表示清空，数组表示完整替换**。旧操作沿用旧回执身份算法，新操作按附件字段值比较，JSON 对象键序不影响幂等。旧客户端的冲突副本继承服务器当前原便签附件；新客户端的冲突副本使用本次完整附件数组。提交前检查全部引用存在且大小一致，任何一项错误都拒绝整个批次。

文件 BLOB 与便签存于同一 SQLite 数据库，现有 `VACUUM INTO` 备份包含文件；本机缓存、待提交附件和生产数据库均不得提交 Git。移除附件或删除便签只改变引用，不自动物理清除服务器文件或本机缓存，以保留其他便签、冲突副本及备份可用性。

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

## 增量同步扩展（2026-10-09）

`/health` 的 `features` 增加 `delta`。客户端在请求中附带 `since`（本机便签对应的上次服务器 `sequence`）时，响应带 `"delta": true`，`notes` 只包含 `revision > since` 的便签，加上本次请求涉及的全部便签（提交的 `note_id` 和回执的 `note_id`，包括冲突时未变化的原便签）。客户端用这些便签逐条覆盖本机记录，其余保持不变；完整快照（无 `delta`）仍整体替换。合并成功落盘后保存新的 `sequence`。

省略 `since`、`since` 不是非负整数，或 `since` 大于服务器当前序号（例如服务器从备份恢复）时，返回完整快照。旧服务器忽略 `since`、不返回 `delta`，客户端照常整体替换，因此新旧版本可以混用。

没有提交任何操作、合并后本机状态也没有变化的空轮询，客户端不写盘、不刷新界面。两端合并规则由共用用例 `tests/fixtures/sync-cases.json` 约束，Swift 模型测试和 C# 核心测试读取同一份用例。

操作回执在服务端持久保存；同一设备重试相同 `op_id` 与载荷只应用一次。不同载荷或不同设备复用 `op_id` 返回 409。一个批次验证失败时不写入任何操作。

## 错误与边界

- 400：字段错误或 JSON 无效；提示错误，不丢弃本地内容。
- 401：私有密钥错误；停止把它当普通离线问题，提示同步配置无效。
- 409：操作 ID 被错误复用；保留待同步内容，修复客户端的队列逻辑。
- 413：请求过大；拆小批次或缩短单条内容。
- 5xx / 超时：保存本地内容，重试原操作。
- 并发合并是“整条便签保留冲突副本”，不是逐字协同编辑。
- 服务端 SQLite 使用 WAL 和 FULL 同步；每小时备份一份，保留最近 48 份。这是同机备份，不替代异地备份。
- 正文采用纯文本；附件作为独立文件传输，不插入正文，不支持富文本或内嵌预览。

## 运行与验证

服务端要求 Node.js 24.15 或以上，使用内置 [node:sqlite](https://nodejs.org/download/release/latest-v24.x/docs/api/sqlite.html)，无需 npm 依赖。

本地运行核心测试：`node --test tests/server.test.mjs`。

服务器启动任务：`SongNoteServer`；备份任务：`SongNoteBackup`。安装脚本为 `server/install.ps1`，须管理员运行。真实 `server/config.json` 必须私下配置，不放进仓库。

维护连接使用 `scripts/remote.py`，在仓库 `build/deploy-tools` 安装 paramiko；支持本机私钥或不落盘的密码提示，始终核对 `~/.ssh/known_hosts`，不使用固定 Unix 控制套接字。交付时将 `VERSION`、`server/server.mjs`、`server/deploy.ps1` 和包含源码提交/文件 SHA-256 的 `manifest.json` 放入服务器 `C:\便签\releases\<版本-提交-时间>`，调用 `deploy.ps1 -CandidateRoot <目录> -ExpectedCommit <40位提交>`。Windows PowerShell 5.1 应先用 UTF-8 读取脚本再创建 ScriptBlock 执行，或使用 PowerShell 7，避免中文目录被默认 ANSI 解码。

部署脚本先核对候选文件及版本、生成兼容新表结构的旧代码回滚文件；停止服务器和暂停备份任务后生成一致数据库快照，再安装和启动新服务。成功必须回读安装文件哈希及 health 的版本、附件能力和上限，并额外从本机通过公网 HTTPS 验证文件传输。部署失败保留当前数据库数据，恢复兼容代码，不用旧数据库覆盖升级后的写入。部署目录的 `before/` 和 `receipt.json` 仅留私有服务器；数据库、凭据及本机应用配置不上传 GitHub。
