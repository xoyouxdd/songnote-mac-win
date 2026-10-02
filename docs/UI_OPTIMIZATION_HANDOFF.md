# 当前续作与验收

更新：2026-10-03，版本 1.2.0。版本由根目录 `VERSION` 统一提供给 Windows 程序、Mac Info.plist/About 和服务端 health。

## 当前实现与验证

- Windows/Mac 便签支持附件：更多菜单添加，正文下方默认折叠，展开后下载或移除；20 MiB/文件、20 个/便签。
- 文件先复制至本机缓存，后台上传并按 hash 去重；已上传操作才进入冻结批次，其他便签文字仍可同步；下载校验大小与 SHA-256 后原子保存。
- 两端将附件加入整条便签冲突处理及输入法菜单覆盖状态。空正文的附件便签属于正式便签，关闭不丢弃。
- Windows 持久保存 FrozenBatch；Mac 已新增可兼容旧状态的 LocalState.frozen，失败重试原载荷、合并保存失败保留旧状态。Mac 原生异常路径尚未执行，不能将源码实现等同于运行验收。
- 服务端保持 protocol=1，通过 health 的 attachments 能力协商扩展；旧客户端省略字段时保留服务器附件。文件与便签同 SQLite，原有 VACUUM INTO 备份包含文件。
- Windows Release 0 警告/错误、28 核心、44 WPF、2 Node 回环集成、8 服务端测试通过；Swift 语法解析通过。部署与本机原入口更新状态见 [Windows 验证记录](../windows/VALIDATION.md)。

## 文件入口

`macos/App.swift`：窗口、折叠附件及交互；`Theme.swift`：卡片/样式/动效；`Models.swift`：附件、冻结载荷、合并和输入法基准；`Store.swift`：原子保存、后台上传和同步；`AttachmentFiles.swift`：私有文件缓存与传输；`LayoutChecks.swift`：虚构内容原生几何检查。构建脚本已包含新增文件和 CryptoKit，最低 macOS 13。

## Mac 待验收

当前 Windows 主机没有 swiftc/macOS SDK。下列模型用例、21 个 AppKit 布局/状态检查、真实输入法、签名和运行均未在 Mac 执行；实际 Windows/Mac 双端互传也未验收。

```sh
mkdir -p build
swiftc -swift-version 5 macos/Models.swift tests/model.test.swift -o build/songnote-model-tests
build/songnote-model-tests
scripts/build-mac.sh
build/SongNote.app/Contents/MacOS/SongNote --check-layout
```

模型检查包含旧 JSON、草稿、冻结后的附件变更、冲突副本、旧删除、输入法属性覆盖；原生布局检查包含长文本卡片、单/双列、冲突和保存失败，以及 280×240/380×420 附件折叠/展开。模型测试不使用 `-O`，保留断言。

完成编译后使用虚构文件与本机测试服务，逐项验证：

1. 旧安装数据可读取；附件空正文关闭/重启仍保留；未编辑空草稿关闭后丢弃。
2. 上传中续写、移除或再添加附件；断网、响应丢失且服务已接受、退出重启后，原冻结操作先重试，后续操作与正确版本继续提交。
3. 中文候选期间添加/移除附件、接收远端编辑/删除，选字后正文与附件均保留；Esc、关窗、取消退出不保存拼音候选。成功回执可推进编辑基准，拒绝删除/墓碑不能推进。
4. 双端并发编辑保留原件与副本及其附件；副本 ID 迁移后窗口设置保留；删除拒绝的提示持久保留，不自动按新版本重试删除。
5. 窄窗和长文件名、8 个以上附件滚动、展开高度、下载/移除按钮与键盘可用；输入区仍可编辑；实际系统标题栏、多屏和 DPI 下不越界。
6. 下载错误/大小或 hash 不匹配不覆盖目标文件；本机缓存或状态保存失败显示可重试错误并保留文件；旧服务端不支持附件时保留待传队列。
7. 减少动态、菜单栏置顶入口、开机启动默认关闭及真实系统注册状态；无变化轮询不闪烁，正常文字编辑不产生不必要冲突。

真实双端互通需在两台设备上验证。语法解析不代替编译、运行或真实输入法；本机回环不代替生产互通。私有配置、真实便签、文件缓存和验收截图不提交 Git。

## 历史边界

2026-10-01 的 UI、输入法、滚动条与首次 Windows 验证保留于 [Windows 历史验证记录](../windows/VALIDATION.md)。[UI_AUDIT.md](UI_AUDIT.md) 是旧 Mac UI 验收材料，不作为 1.2.0 的原生证据。此前 Mac 单 pending 的冻结重试缺口已在本轮源码处理，仍需要上述异常场景的 Mac 实测。
