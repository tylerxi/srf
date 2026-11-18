# 验收记录 · 0.2.0

日期：2026-11-17。环境：macOS 15.7.9 / Apple Silicon / Swift 6.2.4。

## 已通过

- Debug 与 Release：34 个测试函数、4 个 suite 全部通过（参数化场景额外展开）。报告：`build/qa/v2-tests-release.log`。
- `$c` 大小写门控；没有标记不读取凭证、不调用网络、不输出。标记移除、仅标记拒绝。
- 回答只保存在内存；旧响应取消、乱序、超时、HTTP/网络错误；等待期间不输出；新复制使旧回答失效。
- 2 个 Swift Character 分段、中文、组合字符、家庭 emoji、奇数尾字、反复 `..`；发出失败不移动游标。
- 旧配置默认字段迁移、自定义 endpoint / model / system message、非 HTTPS 和带凭证地址拒绝、DeepSeek 扩展只发往官方域名。
- 安装版配置保存、内存即时更新、磁盘持久化，并恢复原配置：`build/qa/v2-installed-config.json`。
- 安装版两个全局热键均注册成功；实际无标记发送进入 ignored，未触发 API。最终状态：`build/qa/v2-final-status.json`。
- 独立设置窗口截图人工检查：表单、密码遮罩字段、提示词、测试/保存按钮、内联状态均可见。截图：`build/qa/settings-v2.png`。
- Chrome 原生全屏，使用与产品相同 RequestCoordinator / HotKeyService / TextOutput 源码的外部测试 harness + 固定回答：Control+V 五次得到 `春夏`、`秋冬`、`天地`、`人`、`..`。ABC 与微信输入法已启用且未处于组合输入时均通过。
- 微信输入法 + Chrome 全屏输出期间 312 次窗口采样：无新增/移除窗口，无前台进程变化，Space 变化 0。记录：`build/qa/v2-chrome-wetype-output-monitor.json`；测试页面输出与输入事件：`build/qa/v2-chrome-wetype-output.json`。
- 测试前的系统剪贴板、输入法均已恢复，测试专用 Chrome 窗口和 Ego TaskSpace 已关闭。

## 尚未完成，不能视为已验收

安装版新增的文字输出权限尚未授权；ad-hoc 重编译后旧钥匙串条目不可无提示读取，安装版 credentialAvailable=false。未自动绕过或触发授权。已请用户在设置应用中重新保存密钥、主动授权。

因此 **本次 0.2 安装版真实 API → 内存回答 → Control+V 的完整链路、GUI 测试连接成功、重启后读取新保存密钥** 尚待完成。外部 harness 具有测试进程的既有权限，只用于验证算法/输出机制，不能替代安装版权限验收。

本次未验证 Safari 的新逐字输出、输入法正在组词时的逐字输出、所有第三方编辑器。CGEvent Unicode 的接收由目标应用决定，发出事件没有插入确认；不读取目标内容，因此不能证明每个目标都接受。

## 0.1 历史验收记录（不代表 0.2 当前链路）

# SilentClipboard 0.1.0 测试记录

日期：2026-11-17。环境：Apple Silicon、macOS 15.7.9、Swift 6.2.4。

交付状态：实现和下列自动/本机集成测试已通过。此前待确认的中文输入法兼容性，已补做本机当前微信输入法的真实组合输入与候选窗口测试并通过。用户额外试用反馈尚未收到，不计作人工反馈，也不再作为本机交付的阻塞项。

本机已安装到 `/Applications/SilentClipboard.app`，配置 DeepSeek Key 到钥匙串，并保持后台运行。默认处理键为 ⌃⌥⌘J；登录启动默认关闭。测试前的剪贴板已通过仅在内存中的备份恢复；测试用浏览器窗口和本地服务已关闭。

## 用户强制需求与证据

| 要求 | 验证与结果 |
| --- | --- |
| 只读取已复制内容 | 唯一生产输入为 `SystemClipboard.readPlainText()` 的 `NSPasteboard.general` `.string`；源码无 AX 内容读取、浏览器自动化、截图、文件展开或合成输入调用 |
| 不读取当前页面选区 | 在剪贴板为测试问题 A、页面选中不同文本 B 时，返回 A 指定的答案；B 的内容和选区没有变化 |
| 不依赖源页面 | 复制测试问题后将源页导航到空白页，再触发快捷键，仍成功取得指定答案 |
| 原生后台运行 | 已安装进程报告 activationPolicy 为 prohibited，NSApp.windows 数量为 0；无 SwiftUI/窗口/浮层/通知/声音创建代码 |
| Safari 全屏静默 | 真实 Safari 的测试窗口 AXFullScreen 为 true；请求期间 314 次窗口/前台采样，没有新增窗口、焦点变化、Space 变化；页面选区 5–22、滚动位置、输入内容、copy/paste/input/focus 等计数保持一致 |
| Chrome 全屏静默 | 真实 Chrome 的具名测试窗口 AXFullScreen 为 true；请求期间 328 次采样，没有新增窗口、焦点变化、Space 变化；页面状态完全一致 |
| 中文输入法候选状态不受影响 | 本机当前微信输入法 `com.tencent.inputmethod.wetype.pinyin`，Chrome 原生全屏中真实键盘事件输入 nihao，页面处于 composing=true、未上屏内容为 `ni'hao`。处理前后 composition/input/keydown 等计数、光标和焦点完全相同；308 次采样未发现新增窗口。另一次按住热键期间及返回后共 306 次采样，原来的 Chrome 和微信输入法窗口没有新增或消失，答案已提交 |
| 正常粘贴返回答案 | Safari、Chrome 和 ego lite 的测试页均通过实际 ⌘V 粘贴出 `CLIPBOARD_TEST_OK`；源输入框没有被程序改写 |
| 无完成/失败提示 | 成功和剪贴板冲突路径均没有窗口；权限拒绝等错误仅改变内存状态，单元测试验证不读取或写入。没有系统通知或声音 API |
| API token 可用 | 从钥匙串读取后向官方 DeepSeek endpoint 发出固定问题，返回 `SILENT_CLIPBOARD_OK`；真实剪贴板问题多次成功，短回答实测约 0.5–1.3 秒，仅为本次样本 |
| 中间内容在内存处理 | URLSession ephemeral、无 URLCache/Cookie/credential store；无历史存储或正文日志；应用数据目录只出现空锁文件及控制 socket |
| 原文及密钥不进入交付包 | 扫描 Sources、Tests、scripts 和 packaging，没有真实 `sk-` 密钥字面量；Keychain 读写经 IPC，命令行参数不含密钥，安装包不含凭据 |

浏览器页面的监测、复制/粘贴输入和全屏控制由独立外部 QA 工具执行，仅作用于新建的测试窗口。它们不在产品可执行文件中。生产程序未获得或使用页面读取能力。

Chrome 的第一次验证脚本错误地检查了未命名工具栏窗口，其 AXFullScreen 为 false；随后按 `SilentClipboard Native QA - Google Chrome` 精确定位测试窗口，确认实际内容窗口为全屏。该脚本误判没有当作成功结果。

## 自动与集成测试

`swift test` 及 `swift test -c release`：**28 个测试函数、4 个测试套件通过**；其中参数化测试覆盖多组错误和输入。包括：

- 权限拒绝不读取；提交前权限撤销不写入。
- 读取期间版本变化、无纯文本、空白、UTF-8 大小限制。
- 真实临时 NSPasteboard 的中文和换行读写；图片/文件引用不展开。
- 问答期间不改写剪贴板；完整成功后只写一次。
- 再次复制、相同文本重新复制、乱序响应、客户端忽略取消的迟到响应。
- 暂停、取消、总超时和缺失密钥；错误保持当前内容。
- URLProtocol 模拟实际 URLSession 请求，覆盖 401、402、429、500、断网、无效 JSON。
- 空答案、被截断答案、过滤/中断/工具调用结果被拒绝；不输出 reasoning_content。
- 网络配置不使用持久缓存；请求仅包含系统提示词和剪贴板快照。
- 无效快捷键和配置被拒绝。
- 显示器唤醒不清除锁屏状态；休眠、切换会话等重叠状态只有全部解除才恢复。

已安装进程集成验证：

- Carbon 独占热键已注册；外部程序不能占用相同组合。
- 修改为已占用热键时拒绝配置并恢复原组合。
- 长按 J 发送 1 次按下、7 次重复和 1 次释放，只有一次新的有效请求，页面没有额外 keydown/input 事件。
- `pause` 后主动 process 不发起请求；`resume` 恢复；无效配置、无效 IPC 消息不会使服务退出。
- 请求期间再次复制 `NEW_COPY_MUST_SURVIVE`，真实响应被标记 `clipboard_changed` 且新内容保持不变。
- 应用退出重启后，钥匙串可读、热键可用、窗口数为 0；重复启动会退出第二实例。
- ad-hoc 更新曾导致旧钥匙串 ACL 拒绝新代码。已修复主动 `set-key`：重建本应用自己的条目并立即读回验证；日常失败保持静默。最终构建已重新配置并验证，后续重新构建仍可能需要主动 set-key。
- 应用数据目录 0700；socket 0600；控制服务校验同一用户 UID。
- 空闲样本 CPU 0.0%、RSS 约 24 MB；没有持续剪贴板正文轮询。
- Info.plist 校验、shell 语法、codesign 校验和 ZIP 完整性检查通过；安装二进制与构建产物一致。

原始结果保存在本机 `build/qa/`，包含 `safari-fullscreen.json`、`chrome-fullscreen.json`、`browser-fullscreen.json`、`control-integration.json`、`clipboard-conflict.json`、`release-tests.log` 和 `installed-status.json`。这些文件仅包含测试文本或状态，不含真实密钥和用户剪贴板正文。

追加输入法证据：`wetype-fullscreen.json`、`wetype-before.json`、`wetype-monitor.json`、`wetype-window-persistence.json`。测试使用独立 Chrome 窗口，真实切换至微信输入法中文模式后发送按键；不是通过 JavaScript 人造 composition 事件。测试结束已恢复进入测试前的输入来源、原模式和剪贴板，关闭测试窗口与本地服务。此次仅增强外部 QA 脚本，没有修改已验证的产品二进制。

最终交付审计 `build/qa/delivery-audit.json` 确认安装程序与 ZIP 内程序逐字节一致、运行时窗口数 0、密钥可读、热键可用、未暂停，且不存在 `~/Library/Caches/com.bear.silentclipboard` 持久缓存目录。二进制 SHA-256 为 `072ea11cb3e85d5f05943883b9ffe8c331d03791a14bb05a8ab4ce9afa9a1098`。

## 验证范围与限制

本次证明的是这台 macOS 15.7.9 上的剪贴板问答、Safari/Chrome 原生全屏、应用重启与上述异常处理。不把单机测试推广为所有系统版本、所有第三方插件或所有输入法均已验收。

- 没有重启用户电脑、锁定其真实钥匙串或切断整机网络；休眠/锁屏重叠和网络失败由可控测试验证。没有实际注销/重新登录或物理双屏回归。
- 微信输入法的未上屏拼音和候选窗口已实测；其他输入法没有逐一覆盖。程序不注入输入，但其他输入法与第三方热键工具仍可能存在冲突。
- 没有撤销用户的真实系统授权来诱发系统提示；生产路径仅在剪贴板明确 alwaysAllow 时读取，其他状态直接返回。
- NSPasteboard 无跨进程原子比较写入接口；版本核对与提交间仍存在极小竞争窗口。系统延迟数据交付、跨设备剪贴板或第三方剪贴板工具的行为不能作绝对保证。
- macOS 15.4 是 API 部署下限，其他系统版本未实机测试；当前包仅 arm64、本机 ad-hoc 签名，未公证。
- 可选登录项入口已实现，但本次未启用或注销登录验证，交付时保持关闭。

这些限制不改变运行策略：任何不能确认权限或数据有效性的情况停止处理，不增加页面读取或模拟复制的备用路径。
