# Windows 首版验证记录

日期：2026-10-01。范围：Windows 客户端源码、Release 构建、本机持久化与协议合并、原生 WPF 布局和本机回环服务。没有连接生产地址、读取真实便签、注册开机启动或提交/推送代码。

## 当前结果

- `.NET SDK 10.0.401` 放在仓库 `build/dotnet`，SDK ZIP 根据微软官方发布元数据做 SHA512 比对通过；未安装到全局 SDK 目录。运行时仍使用系统已有的 .NET 10。
- `SongNote.Windows` / `SongNote.Core` Release 构建通过，0 警告、0 错误。
- 22 项核心测试通过：本机草稿、旧空便签、请求冻结、100000 字中文分批不超 2 MiB、请求期间续写、历史回执、冲突 ID/窗口设置迁移、三种删除拒绝、墓碑后迟到正文、批量退出失败、畸形响应、缺失设备 ID、合并落盘失败、原子文件/备份、损坏文件保留、响应丢失后续写重启、并发同步门。
- 1 项本机 Node 实际协议测试通过：C# 客户端新建/编辑，第二设备模拟更新，冲突副本和过期删除拒绝。服务仅监听 `127.0.0.1` 随机端口，使用内存 SQLite 与虚构密钥，退出后自动停止。
- 15 项原生 WPF 检查通过：图标资源，七张样例的单/双列与奇数末行，280/380/640 宽便签，280×240 冲突提示，透明且不激活的真实窗口收到远端墓碑后的关闭路径、即时选中边框、越屏坐标恢复、动画替换/停止、删除保存失败时窗口保留/提示/重试恢复。截图已查看，不把 HTML 模型当作 WPF 截图。

截图输出在仓库忽略目录 `build/windows-ui-check`：`list-460.png`、`list-720.png`、`note-380.png`、`note-conflict-min.png` 等，只含虚构内容。

## 可重复执行

在 `windows/` 运行：

```powershell
.\build.ps1 -Test -CheckUi -Integration
```

SDK 缺失时先从 `windows/` 执行 `python bootstrap-sdk.py`（Python 3.11+），再构建。Node 24.15+ 用于回环协议测试；客户端运行无需 Node。测试工具、SDK、NuGet 缓存与截图都在项目内。

受限执行环境可能拒绝 `File.Replace` 或原生子进程；本次真实文件和 GUI 检查在获自动批准的宿主执行环境运行通过，没有通过更换非原子写法绕过验证。

## 运行与数据位置

客户端入口为 `src/SongNote.Windows/bin/Release/net10.0-windows/SongNote.exe`。运行需要 .NET 10 Desktop Runtime，保留同目录 DLL、runtimeconfig 和其它构建输出。直接运行后以本机离线模式使用；缺少配置不会连接任何服务。

正式本机数据为 `%LOCALAPPDATA%\SongNote/state.json`，上一个可读版本为 `state.previous.json`；内容、Pending、FrozenBatch、草稿、提醒、打开 ID 与窗口设置一并原子保存。窗口坐标采用 Windows 原生物理像素，再结合目标显示器 DPI 恢复；仅存 Windows 本机，不同步到 Mac。

测试体验可运行 `SongNote.exe --offline-demo`，数据位于可执行文件目录的 `demo-data`，与正式数据和单实例锁分开，不连接生产服务。没有默认开启开机启动；托盘菜单提供注册/取消注册操作，界面明确注明系统仍可能禁用已注册项。

真实同步配置由用户放入 `windows/client-config.json` 后构建，或放入 `%LOCALAPPDATA%\SongNote/client-config.json`。必须使用真实 HTTPS 配置，不能安装模板里的占位密钥；正常启动若已存在有效配置会开始自动同步。不要把真实配置或密钥提交仓库。

## 尚未验收

真实微软拼音的连续选字、Esc、候选中关窗、取消退出及远端变化尚未人工实测；已实现候选抑制、组合基准、完成后延迟读取和会话代次保护，模型用例不替代输入法实测。

当前显示器上越屏恢复已验证；真实多显示器、不同 DPI 的拖动/最大化/拔屏、辅助功能与高对比体验、托盘开机注册、同账号跨登录会话单实例仍需人工验收。客户端使用 WindowChrome 提供窗口行为，三个系统操作按钮是自绘控件调用 SystemCommands，不能称为原生系统按钮。

本轮没有进行实际 Mac/Windows 两台客户端或生产服务器联调。Mac 源码仍保持上一轮状态，编译和真机验收见 `docs/UI_OPTIMIZATION_HANDOFF.md`。本机回环测试不等于双端生产互通验收，也未形成正式发布包。
