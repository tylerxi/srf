# 静默剪贴板 · SilentClipboard 0.3

原生 macOS 静默工具。只处理你已经复制到系统剪贴板的纯文本，不读取浏览器、页面、选区、输入框或屏幕。回答默认写入 macOS 系统文本替换（`ffa`、`ffb`…），可在 ABC/英文输入模式下快速展开。

项目结构、开发环境与构建说明见 [PROJECT.md](PROJECT.md)；验收记录见 [TEST-REPORT.md](TEST-REPORT.md)。

## 使用

1. 在原应用用 **⌘C** 复制包含 **`!!!`** 的文字，例如：`!!! 用一句话解释什么是索引`。
2. 按原来的 **⌃C**（Control + C）发送。
3. 等待回答后，在目标输入位置按 **Control+V**，每次输出两个字符。
4. 需要系统词条时，在输入框用 **ABC/英文输入模式** 输入 `ffa` 再按空格，展开本轮答案第 1 段；`ffb` 是第 2 段，依次到 `ffz`。中文输入法拼音组合阶段不会触发系统替换。

`!!!` 区分大小写，所有标记在发送前移除。没有标记时不请求 API，也不输出旧答案。仅有标记或空白也不会请求。

例如答案 `春夏秋冬天地人`，连续按键依次输出 `春夏`、`秋冬`、`天地`、`人`、`..`，此后每次仍输出 `..`。按 Swift Character 分段，中文、组合字符和 emoji 不按 UTF-8 字节切开。空格、标点、换行也计入字符。

系统词条每段固定 4 个 Swift Character，中文、组合字符、emoji 不拆；标点计入，连续空白折叠成一个空格。答案总长不足 4 个字符时只有 `ffa`，不足 8 个字符时只有 `ffa`、`ffb`；最多 26 条。每次成功回答会重写本工具管理的 `ffa`–`ffz`，答案变短时多余的旧词条被删除；空答案或请求失败保留上一轮。该功能默认开启，与 Control+V 逐段输出相互独立。

回答正文只保存在应用内存中，**不再把整段答案覆盖到系统剪贴板**。开启系统词条后，分段文本会另写入 macOS 文本替换存储，见下文。Control+V 使用 Unicode 键盘事件输出到当前前台应用；⌘V 仍是系统正常粘贴。长按只触发一次，下一次要松开再按。

发送新请求、取消、暂停、睡眠、锁屏、退出会清空内存中的答案。系统词条不受这一清空影响，直到下一次成功回答或关闭功能。请求过程中再次复制会丢弃旧回答；回答就绪后再次复制，也会在下次输出时使旧答案失效。等待回答、失败、权限缺失、未准备好时，Control+V 均无动作。耗尽后的 `..` 仅适用于已经成功收到的答案。

日常运行没有窗口、浮层、通知、声音、菜单栏图标或 Dock 图标。不会主动切换焦点或全屏 Space。不会模拟复制、读取选区、扩展剪贴板中的 URL/文件内容。

## 独立设置应用

打开 `/Applications/SilentClipboard Settings.app`（静默剪贴板设置）：

- **API 地址**：完整 HTTPS Chat Completions 地址，默认 `https://api.deepseek.com/chat/completions`。
- **模型**：默认 `deepseek-flash`，其他服务需填写其有效模型名。
- **API 密钥**：掩码输入，保存到 macOS 钥匙串；留空保留现有密钥。
- **默认提示词**：每次作为 system 消息发送，可填写角色、常用资料和字数要求。
- **测试连接**：使用当前表单中的地址、模型和密钥发一个固定测试问题，结果在窗口内显示；不读取或修改剪贴板、不保存草稿、不使用默认提示词干扰测试。
- **保存并生效**：保存配置并立即应用；不需要每次启动都配置。

例如提示词：`你是我的技术问答助手。用中文直接回答，不加开场白。每次答案不超过 30 个字符。`

提示词中的字数是给模型的要求，不是程序强制截断。API 兼容 Chat Completions 的基本文本协议；不代表所有供应商私有参数均兼容。只对 DeepSeek 官方域名发送关闭 thinking 的扩展参数，不跟随 HTTP 重定向。

设置程序只在主动打开时显示，关闭窗口会退出设置程序，后台工具继续运行。双击 `/Applications/SilentClipboard.app` 只启动静默工具，不显示设置。

## 系统文本替换

0.3 默认把每个成功回答切成 4 个字符一段，依次写入系统文本替换的 `ffa`、`ffb`…`ffz`，最多 26 条。设置应用中的“系统词条”区域显示开关、权限状态、当前管理的词条和刷新/清除按钮。

写入 `~/Library/KeyboardServices/TextReplacements.db` 和全局偏好 `NSUserDictionaryReplacementItems`。本机 0.3.0 安装版在 LaunchServices 启动后可直接读写，未要求完全磁盘访问；若其他系统版本或安全策略拒绝，设置页会显示“需要完全磁盘访问”，可点击按钮打开系统设置手动添加，再点“刷新状态”。macOS 不允许应用自行静默取得该权限，本程序也从不弹系统授权框：未授权时问答和 Control+V 输出仍正常，只是词条不更新。

写入会同时更新数据库和全局偏好 `NSUserDictionaryReplacementItems`，但不重启 `keyboardservicesd`，也不切换输入法，因此不会打断当前输入。多数应用切到 ABC/英文即可立即使用；若输入框仍未展开，切换一次输入法或重新聚焦输入框。

系统文本替换只在 **ABC/英文输入模式** 下可靠触发，中文拼音的候选组合阶段不会替换。网页输入框一般可用；地址栏、安全输入框、部分终端和 Electron 应用不保证。

关闭开关或点击“清除系统词条”，会按本工具记录的所有权删除自己创建的 `ffa`–`ffz`，保留其他应用或系统自建的词条。退出应用不会自动删除；若在启用状态直接卸载，已写入的词条会留在系统中，需要先关闭功能或手动删除。系统文本替换是否经 iCloud 同步由 macOS 和 Apple ID 设置决定，本程序不主动触发同步。

## 首次权限

在设置应用中主动点击“允许剪贴板访问”和“允许文字输出”。macOS 可能显示系统授权界面；在系统隐私/辅助功能设置中允许 **静默剪贴板** 后，点击“刷新状态”。运行时只检查权限，从不自行请求授权。

系统文本替换通常无需额外授权；若系统策略拒绝写入，才需要在系统设置中手动添加“完全磁盘访问”。本程序不会为此弹授权框，未授权时仅停用词条写入。

本版本新增文字输出权限。当前本机采用 ad-hoc 签名，重新构建可能使旧钥匙串访问或权限失效；此时需在设置应用中重新保存密钥、主动更新权限。正式分发应使用稳定的 Developer ID 签名并公证。

Unicode 键盘事件由目标应用解释，某些自定义编辑器、终端或输入法组合状态可能不接受。程序不读取目标内容，因此只能确认事件已发出，不能确认目标实际插入成功；光标按发出成功推进。安全键盘输入启用时不发出事件，也不推进。当前全屏验证范围与限制见 [TEST-REPORT.md](TEST-REPORT.md)。

## 命令行

```bash
./bin/srf status
./bin/srf settings
./bin/srf pause
./bin/srf resume
./bin/srf cancel
./bin/srf quit
open -gj /Applications/SilentClipboard.app
./bin/srf set-key             # 终端安全输入，不把密钥放入命令参数
./bin/srf authorize           # 主动剪贴板授权
./bin/srf authorize-output    # 主动文字输出授权
./bin/srf verify
./bin/srf verify-status
./bin/srf configure /绝对路径/config.json
./bin/srf text-replacement-status
./bin/srf text-replacement-refresh
./bin/srf text-replacement-clear
./bin/srf login-enable        # 可选，本机默认不启用
./bin/srf login-disable
```

发送快捷键固定为 Control+C（虚拟键码 8、修饰位 4096）；Control+V 固定用于逐段输出。触发关键字可在设置中修改，默认 `!!!`，必须位于剪贴板文本开头。旧版 J 快捷键配置会自动迁移。快捷键冲突会记录状态，运行时不弹窗。请避免与其他应用同时占用 Control+C 或 Control+V。

非密钥配置在 `~/Library/Application Support/SilentClipboard/config.json`，旧版文件自动兼容；密钥只在钥匙串，条目名 `SilentClipboard DeepSeek API Key`。不保存聊天历史，不记录正文日志；但开启系统词条时，答案的 `ffa`–`ffz` 分段会写入 macOS 文本替换数据库和全局偏好，属于系统持久化数据，关闭功能会删除本工具创建的词条。网络使用无磁盘缓存的临时会话。请求发送到所配置的远端 API，服务方处理不在本机内存中进行。

控制 socket 仅同一用户可访问，目录 0700、socket 0600；状态返回计数和错误分类，不返回问答正文或密钥。配置内的默认提示词本身按非密钥配置保存。

## 构建与安装

要求 macOS 15.4+、Swift 6.2，无第三方 Swift 包依赖。

```bash
swift test
./scripts/build-app.sh
./scripts/install.sh
./scripts/package.sh
```

构建生成两个应用，安装到 `/Applications/`。安装脚本退出旧静默进程后启动新版，不自动启用登录项。源码内的 `scripts/qa-*` 仅是外部 QA 工具，不编译进应用。

卸载时先关闭设置窗口，运行 `./bin/srf login-disable`（若曾启用）和 `./bin/srf quit`，然后删除两个应用。配置目录和钥匙串条目可按需手动删除。
