# 静默剪贴板开发记录

## 0.3 已实现

- 成功回答按 4 个 Swift Character 分段，依次写入系统文本替换 `ffa`–`ffz`，最多 26 条；中文、emoji 不拆，连续空白折叠为一个空格，标点计入。
- 与 `RequestCoordinator` 的“回答已就绪”回调对接；发布会话带请求代次，旧请求不会覆盖新答案。空答案、请求失败、权限缺失不写入。
- 写入 `~/Library/KeyboardServices/TextReplacements.db`：`BEGIN IMMEDIATE`、`busy_timeout`、同步 `Z_PRIMARYKEY.Z_MAX`，不自动整库备份，不覆盖非本工具拥有的 `ffa`–`ffz`。
- 同时更新全局偏好 `NSUserDictionaryReplacementItems`（`CFPreferences` AnyApplication 域），保留非受管词条；不重启 `keyboardservicesd`，不切换输入法、不弹窗。
- `text-replacements.json` manifest 按 UUID 记录所有权，不保存 phrase；关闭开关或清除命令只删除 manifest 中的条目。
- 默认开启；数据库不可写时只记录状态并停用词条，不影响问答与 ⌃V 输出。设置页显示访问状态、管理的 shortcut、最后更新时间和错误，提供刷新/清除/打开系统设置。
- 新增 `text-replacement-status`、`text-replacement-refresh`、`text-replacement-clear` 控制命令。
- 单元测试覆盖分段、空白、emoji、26 条上限、临时 SQLite 的插入/更新/删除、`Z_MAX`、冲突拒绝、损坏 manifest、软删除忽略和偏好合并。

## 0.3 本机验证结果

- `swift test` 49 个测试函数、7 个 suite 通过；0.3.0 build 3 已安装，后台进程窗口数为 0。
- 真实 canary `ffq → 测试词条` 已写入 DB 与全局偏好；`NSSpellChecker` 立即返回 `replacement=测试词条`，测试文本视图的 `NSTextCheckingController` 可把 `ffq ` 替换为 `测试词条 `，无需重启 `keyboardservicesd`。
- 本机 TCC 日志中该应用只请求 ListenEvent/PostEvent，没有 SystemPolicyAllFiles；DB 可直接读写，未弹授权框。
- canary 已清理，DB 与全局偏好均恢复为原有 10 条。证据在 `build/qa/0.3/`。

## 0.3 待本机验收

- 真实键盘在 ABC/英文模式的 TextEdit/浏览器输入框中敲 `ffa`+空格能否立即展开；本机辅助功能/事件注入未授权，无法自动验证。
- 安装版真实 API → 回答 → 词条全链路；当前 `credentialAvailable=false`，设置页测试连接未执行。
- 中文输入法组合阶段不展开为预期限制；微信输入法等第三方输入法的自定义词库不受本功能影响。
- 安装版关闭开关、清除命令能只删除本工具创建的条目；ad-hoc 重新构建后的权限继承行为需再次确认。

## 0.2 已实现

- 普通复制使用 ⌘C；AI 发送使用 Control+C。只有剪贴板纯文本以可配置触发关键字（默认 `!!!`）开头时请求 API；发送前删除开头关键字。
- 主线程捕获快照，异步网络请求；完整回答到达且剪贴板版本未变化时进入内存缓冲。
- Control+V 通过独占 Carbon 热键捕获，每次发出两个 Swift Character，剩一字则发一字，耗尽发 `..`；失败发出不推进。
- Unicode 键盘事件定向发给前台进程，无菜单粘贴操作，无激活、选区读取、复制模拟或剪贴板写入。
- 配置独立应用，静默应用保持 prohibited 激活策略。设置应用主动显示 SwiftUI 原生表单，API 测试结果内联。
- 完整 HTTPS endpoint、模型、system prompt 保存到 JSON；token 保存到 Keychain，通过同用户 socket 热更新。
- 测试连接使用草稿配置与固定问题，不读剪贴板、不保存草稿、不覆盖答案。
- 0.1 配置迁移、错误分类、取消/超时、休眠锁屏处理继续生效。

## 仍需本机人工设置与验收

当前安装使用 ad-hoc 签名。重新编译导致旧 Keychain ACL 与当前程序身份不匹配，不能无提示读取旧密钥。用户需在设置界面重新输入密钥，并主动授予新增加的文字输出权限。无需向聊天提供 token。

在这一步完成后，应使用安装版做真实 API、重启后密钥读取、设置“测试连接”、Chrome/Safari 全屏端到端验证。自动测试及同源外部输出 harness 已完成的具体范围见 TEST-REPORT.md，不能将其等同于安装版完整验收。

## 后续可选工作

- 稳定 Developer ID 签名和公证，减少升级导致权限/钥匙串身份变化。
- 目标应用兼容性矩阵：更多编辑器、终端、长 Unicode grapheme、带换行输出及输入法正在组合时的输出。
- 如确有硬性长度限制，再增加独立的最大字符数设置；默认提示词只是模型指令。

## 参考

- [Apple CGEvent Unicode 字符设置](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:))：部分应用框架可能忽略事件中的 Unicode 字符，不能承诺所有应用均兼容。
- [Apple CGEvent 定向发出事件](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:))。
