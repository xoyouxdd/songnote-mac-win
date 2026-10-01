# SongNote 实际界面检查与修复

> 本文记录的是 `a47345d` 版本的既有 Mac 实机检查。2026-10-01 后续优化已变更标题栏、卡片布局和交互；下列截图及“验证通过”不适用于新版。新版状态和待验收步骤见 [UI 优化续作与验收](UI_OPTIMIZATION_HANDOFF.md)。

日期：2026-10-01。范围：本机真实 Mac 应用的列表、独立便签、搜索和置顶筛选；使用 Computer Use 捕获实际窗口，截图保存在被 Git 忽略的 `private/ui-audit/`。

## 1. 列表：已修复

旧版卡片超过滚动区域可用宽度，右侧圆角和箭头被裁掉；右下角同步图标残留默认的 Button 标题。现采用随可用宽度调整的卡片布局，修正图标按钮标题与位置。新版图标已用于列表标识。

![列表修复前](/Users/a1/Projects/桌面便签/private/ui-audit/01-list-before.png)

![列表修复后](/Users/a1/Projects/桌面便签/private/ui-audit/04-list-after.png)

## 2. 独立便签：已修复

旧版删除图标残留 Button 文字，按钮的图标贴边，底部同步按钮没有靠右。已清空纯图标按钮的默认标题，统一图标与文字布局，并将底部状态固定在左、同步按钮固定在右。顶部返回列表、新建和底部立即同步已实际点击验证。

![编辑窗口修复前](/Users/a1/Projects/桌面便签/private/ui-audit/02-editor-before.png)

![编辑窗口修复后](/Users/a1/Projects/桌面便签/private/ui-audit/03-editor-after.png)

## 3. 搜索与筛选：正常

已实际验证：输入无匹配关键词显示居中的空状态；清除关键词恢复列表；置顶筛选显示对应条目或说明；恢复全部后点击卡片打开原便签窗口。检测未修改便签正文，也没有创建测试垃圾便签。

![搜索无结果](/Users/a1/Projects/桌面便签/private/ui-audit/05-search-empty.png)

![置顶空状态](/Users/a1/Projects/桌面便签/private/ui-audit/06-pinned-empty.png)

## 4. 窗口尺寸和图标：验证通过

通过真实 AppKit 窗口构建代码运行只读布局检查，覆盖列表 400×420、430×660、720×760 和便签 360×280、380×420、640×640 六种内容区域尺寸；验证控件对齐区域不越界、卡片完整、同步按钮靠右、正文区域保有可用高度。检查不展示窗口、不修改便签、不保存窗口位置、不请求服务器。

命令：`build/SongNote.app/Contents/MacOS/SongNote --check-layout`。

新版图标由内置 imagegen 生成，提示方向是立体暖黄便签纸、奶油色卷角、三条深灰笔画、透明背景；完整提示词见 `docs/ICON_DESIGN.md`。Mac ICNS 和 Windows ICO 已导出；ICO 的七种 PNG 尺寸与容器索引检查通过。

## 检查边界

卡片使用可访问按钮角色与打开动作，纯图标按钮有中文标签，保存失败和离线提供文字提示。实际截图与上述几何检查支持本次排版修复；未完成全套 VoiceOver、系统大字体和 Windows 实机 UI 验证，不据此声明完整无障碍合规。截图包含本机便签，只保留在私有本地目录，不上传服务器或提交 GitHub。
