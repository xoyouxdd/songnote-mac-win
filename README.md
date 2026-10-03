# SongNote

自己使用的 Windows / Mac 桌面便签。Mac 是 Swift / AppKit 原生应用；便签列表可搜索，每条便签可以打开独立窗口，支持纯文本、6 种颜色、列表置顶、窗口置顶和离线保存。

服务器使用 Node.js 内置 SQLite，通过 HTTPS 同步，无账号或登录页；客户端安装时预置私有同步密钥。版本冲突保留副本。

- `macos/`：Mac 原生源码。
- `windows/`：Windows WPF 客户端、存储/同步核心、配置模板、构建脚本与验证记录。
- `server/`：服务端、Windows 服务器开机启动与备份脚本。
- `docs/SYNC_PROTOCOL.md`：两端共同遵守的协议。
- `tests/`：服务端及 Mac 同步合并测试。
- `assets/`：图标母图、预览和 Mac ICNS；Windows ICO 位于 `windows/assets/`。
- `private/`、`build/`：私有配置和本机产物，已忽略，不提交仓库。

仓库：<https://github.com/xoyouxdd/songnote-mac-win>。

Mac 编译：`scripts/build-mac.sh`。需要 macOS Command Line Tools；输出为本机架构程序（arm64 或 x86_64），最低 macOS 13，未经 Apple Developer 公证，供本机私人使用。应用包为 `build/SongNote.app`。要配置此安装，先把实际 `client-config.json` 放到 `private/`，再编译。

Mac 数据目录：`~/Library/Application Support/SongNote`。每次正式输入写入本机，服务每 3 秒同步；中文候选文字暂不保存。未编辑空草稿只留本机，关窗丢弃。标题栏提供新建、列表、列表置顶、更多；更多包含六色选择、总在最前和删除。底部一行状态及立即同步，冲突和拒绝删除在正文上方持续提示。⌘F 搜索，列表支持键盘和右键操作；宽窗口自动双列。关闭窗口后仍在菜单栏运行，菜单可直接打开置顶便签或切换开机启动；Command-Q 退出。

当前版本由根目录 `VERSION` 统一定义为 1.2.2。Windows 构建和本机验证通过，见 [Windows 验证记录](windows/VALIDATION.md)；Mac 源码和构建脚本已同步，原生编译、布局与实机体验待验证，见 [续作与验收](docs/UI_OPTIMIZATION_HANDOFF.md)。

验证：

```sh
node --test tests/server.test.mjs
mkdir -p build
swiftc -swift-version 5 macos/Models.swift tests/model.test.swift -o build/songnote-model-tests
build/songnote-model-tests
scripts/build-mac.sh
build/SongNote.app/Contents/MacOS/SongNote --check-layout
```

真实服务器凭据与同步密钥不进入代码仓库。实际 Mac/Windows 双端互通仍待实机联调，本机回环测试不视为生产验收。

1.2.0（2026-10-03）实现两端便签附件：在更多菜单选择「添加附件…」，正文下方默认折叠显示数量，展开后下载或移除；每文件最多 20 MiB，每便签最多 20 个。文件先保存本机，后台上传成功后同步描述，下载校验长度和 SHA-256。服务端文件同库保存，已纳入原有数据库备份，详见[附件协议](docs/SYNC_PROTOCOL.md)。

1.2.0 基线 Release 构建 0 警告/错误、28 项核心测试、44 项 WPF 检查、2 项 Node 回环集成及 8 项服务端测试通过；Swift 语法检查通过。Mac 新增原生模型/布局测试尚未在 macOS 编译执行，真实 Windows/Mac 双端互传仍待验证；公网 20 MiB 传输已验证，不据此声明慢网络下的 120 秒边界已测。1.2.0 服务端已部署，公网 HTTPS 20 MiB 上传/下载、401 鉴权和 413 超限拒绝通过；原生选择器真实测试发现崩溃后已修复为 1.2.1；实际入口和常规入口均已更新并核验哈希、配置保留及 7 条原便签同步。本机测试程序位于 `build/attachments-windows/SongNote.exe`。

1.2.1 修复 Windows 添加/另存附件的原生选择器崩溃：改用应用内文件列表，后台读取文件夹，支持多选和粘贴完整路径，Ctrl+O 添加；不调用系统文件对话框、缩略图或 Shell 命名空间。49 项 WPF 检查及虚构中文文件的实际选择、取消重开、另存与哈希比对通过。修复提交 `f1b213e` 已推送 main，1.2.1 服务端版本、能力与安装文件哈希已从 SSH 和公网 HTTPS 独立核验；本机运行 1.2.1。部署备份及回执仅保留私有目录，详情见 [Windows 验证记录](windows/VALIDATION.md)。

1.2.2 恢复 Windows 系统现代文件选择框，使用同目录的 `SongNote.FilePicker.exe` 独立运行，主便签仍使用 .NET 10；选文件组件使用 Windows 自带 .NET Framework，不读取真实便签或同步配置，不修改系统安全设置。系统选择、取消、另存、中文路径及异常进程回收通过 57 项原生检查；发布输出包含该组件。Windows 本机更新状态见验证记录；服务端仍运行协议兼容的 1.2.1，本轮不重复部署未变更的服务逻辑。
