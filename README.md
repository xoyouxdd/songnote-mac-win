# SongNote

自己使用的 Windows / Mac 桌面便签。Mac 是 Swift / AppKit 原生应用；便签列表可搜索，每条便签可以打开独立窗口，支持纯文本、6 种颜色、列表置顶、窗口置顶和离线保存。

服务器使用 Node.js 内置 SQLite，通过 HTTPS 同步，无账号或登录页；客户端安装时预置私有同步密钥。版本冲突保留副本。

- `macos/`：Mac 原生源码。
- `windows/`：Windows 源码预留目录、配置模板与实现交接要求。
- `server/`：服务端、Windows 服务器开机启动与备份脚本。
- `docs/SYNC_PROTOCOL.md`：两端共同遵守的协议。
- `tests/`：服务端及 Mac 同步合并测试。
- `assets/`：图标母图、预览和 Mac ICNS；Windows ICO 位于 `windows/assets/`。
- `private/`、`build/`：私有配置和本机产物，已忽略，不提交仓库。

仓库：<https://github.com/xoyouxdd/songnote-mac-win>。

Mac 编译：`scripts/build-mac.sh`。需要 macOS Command Line Tools；当前输出为本机 arm64 程序，未经 Apple Developer 公证，供本机私人使用。应用包为 `build/SongNote.app`。要配置此安装，先把实际 `client-config.json` 放到 `private/`，再编译。

Mac 数据目录：`~/Library/Application Support/SongNote`。内容每次编辑写入本机，服务每 3 秒同步。每张便签顶部可返回列表或新建便签；底部显示本地保存和服务器同步状态，可点击「立即同步」。关闭窗口后应用仍在菜单栏运行；菜单栏或 Dock 可重新打开列表；Command-Q 退出。需要开机启动可在 macOS“系统设置 → 通用 → 登录项”中加入应用。

验证：

```sh
node --test tests/server.test.mjs
swiftc -swift-version 5 macos/Models.swift tests/model.test.swift -o /tmp/songnote-model-tests
/tmp/songnote-model-tests
scripts/build-mac.sh
build/SongNote.app/Contents/MacOS/SongNote --check-layout
```

真实服务器凭据与同步密钥不进入代码仓库。Windows 端尚待实现和实机联调。
