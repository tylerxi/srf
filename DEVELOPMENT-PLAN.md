# 静默剪贴板开发记录

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
