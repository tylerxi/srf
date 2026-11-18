# SilentClipboard（静默剪贴板）· 项目说明

> 原生 macOS 静默问答工具。剪贴板里以触发关键字开头的纯文本，经 ⌃C 发送到兼容 Chat Completions 的大模型 API，回答保存在内存里，再由 ⌃V 逐段输出到当前前台应用。全程无窗口、无浮层、无通知、不改写系统剪贴板、不读取选区或屏幕。

当前版本：**0.2.0**（`Info.plist` CFBundleShortVersionString = 0.2.0，build 2）

---

## 1. 项目是做什么的

一套只处理「用户已主动复制到系统剪贴板的纯文本」的本地工具。典型流程：

1. 在原应用用 ⌘C 复制一段以 `!!!` 开头的文字（例如 `!!! 用一句话解释什么是索引`）。
2. 按 **⌃C（Control+C）** 发送。触发关键字会被剥离，剩余文本作为问题发给 API。
3. 回答就绪后，在目标输入位置反复按 **⌃V（Control+V）**，每次输出 2 个 Swift `Character`（中文、组合字符、emoji 不会被 UTF-8 字节切断），用尽后持续输出 `..`。

设计上的硬边界：

- 不读取浏览器、网页、选区、输入框或屏幕内容；不模拟复制；不主动切换焦点或全屏 Space。
- 回答只留在内存，不覆盖系统剪贴板；⌘V 仍是系统正常粘贴。
- 发送、取消、暂停、睡眠、锁屏、退出都会清空答案；剪贴板版本变化使旧答案失效。
- 无标记时不请求 API、不输出旧答案；仅标记或空白也不请求。
- 运行时只检查权限，从不主动弹授权；授权只在用户主动点击设置界面时触发。

### 两个独立 App

| App | Bundle ID | 角色 |
| --- | --- | --- |
| `SilentClipboard.app` | `com.bear.silentclipboard` | 后台工具，`LSUIElement=true`、激活策略 `.prohibited`，无 Dock/菜单栏图标 |
| `SilentClipboard Settings.app` | `com.bear.silentclipboard.settings` | SwiftUI 设置窗口，主动打开才显示，关窗即退出 |

两个 App 由同一个可执行文件按启动参数 / bundle id 分流（`Sources/SilentClipboardApp/Main.swift`）。

---

## 2. 技术栈与开发环境

### 2.1 核心环境（来自本机实测与 `Package.swift`）

| 项 | 版本 / 要求 | 来源 |
| --- | --- | --- |
| 操作系统 | macOS 15.4+（部署下限） | `Package.swift` / `Info.plist` LSMinimumSystemVersion |
| Swift | 6.2（`swift-tools-version: 6.2`） | `Package.swift` |
| Swift 编译器（本机） | Apple Swift 6.2.4 / swift-driver 1.127.15，target `arm64-apple-macosx15.0` | `swift --version` |
| Xcode（本机） | 26.3（17C529） | `xcodebuild -version` |
| 依赖管理 | Swift Package Manager（SwiftPM），**无第三方 Swift 包依赖** | `Package.swift` |
| UI | AppKit + SwiftUI（设置窗口） | `Settings.swift` |
| 网络 | Foundation `URLSession`（ephemeral，无磁盘缓存，禁用重定向） | `DeepSeekClient.swift` |
| 热键 / 输出 | Carbon `RegisterEventHotKey` + CoreGraphics `CGEvent` Unicode 键盘事件 | `HotKey.swift`、`TextOutput.swift` |
| 凭证存储 | macOS Keychain（Security.framework），项名 `SilentClipboard DeepSeek API Key` | `Storage.swift` |
| 登录项 | ServiceManagement `SMAppService` | `Application.swift` |
| IPC | 本地 Unix domain socket（`AF_UNIX`），同用户 UID 校验 | `ControlSocket.swift` |
| 签名 | ad-hoc（`codesign --sign -`），支持用 `SRF_SIGN_IDENTITY` 覆盖 | `scripts/build-app.sh` |
| 架构 | 当前仅 arm64（打包产物 `SilentClipboard-0.2.0-arm64.zip`） | `scripts/package.sh` |

### 2.2 辅助工具（QA / lab，不进入产品二进制）

| 工具 | 本机版本 | 用途 |
| --- | --- | --- |
| Node.js | v22.22.2 | `lab/event-replay` 事件回放模块的单元测试 |
| Python 3 | 3.13.12 | `scripts/qa-*-fixture-server.py` 本地测试页面服务 |
| bash / zsh | 系统自带 | 构建、安装、打包脚本 |
| `codesign` / `ditto` / `shasum` | Xcode 命令行工具 | 签名、拷贝、校验和 |
| Git | 2.50.1 (Apple Git-155) | 版本管理 |

### 2.3 环境准备

1. 安装 Xcode 26.x（含命令行工具：`xcode-select --install`），确保 `swift --version` 报告 6.2.x。
2. 克隆仓库后无需 `swift package resolve`（无外部依赖）。
3. 运行 `swift test` 验证环境可用。
4. QA 脚本额外需要 Node.js 22+ 与 Python 3。

---

## 3. 目录结构

```
srf/
├── Package.swift                  # SwiftPM 清单：ClipboardCore / SilentClipboardApp / 测试
├── README.md                      # 使用说明（面向用户）
├── PROJECT.md                     # 本文档：项目说明与开发环境
├── DEVELOPMENT-PLAN.md            # 开发记录与后续可选工作
├── TEST-REPORT.md                 # 验收记录（已通过 / 未通过边界）
├── config.example.json            # 非密钥配置示例
├── Sources/
│   ├── ClipboardCore/             # 与界面无关的核心逻辑
│   │   ├── Clipboard.swift        #   剪贴板快照、版本校验、事务
│   │   ├── Configuration.swift    #   配置模型、校验、0.1→0.2 快捷键迁移、错误码
│   │   ├── DeepSeekClient.swift   #   Chat Completions 请求与响应解码
│   │   ├── RequestCoordinator.swift # 请求状态机、取消/超时、答案缓冲与分段输出
│   │   └── SessionGate.swift      #   睡眠/锁屏/会话状态闸门
│   └── SilentClipboardApp/        # 应用壳
│       ├── Main.swift             #   入口分流：后台工具 / 设置 / --ctl 控制命令
│       ├── Application.swift      #   AppDelegate、生命周期、控制命令分发
│       ├── HotKey.swift           #   Carbon 独占热键
│       ├── TextOutput.swift       #   CGEvent Unicode 定向输出
│       ├── Storage.swift          #   配置落盘、Keychain、实例锁
│       ├── ControlSocket.swift    #   Unix socket 客户端/服务端
│       └── Settings.swift         #   SwiftUI 设置窗口
├── Tests/ClipboardCoreTests/      # XCTest：Pipeline / Network / SessionGate
├── bin/srf                        # 命令行入口（转发到安装版 --ctl）
├── scripts/
│   ├── build-app.sh               # swift build + 组装 .app + codesign
│   ├── install.sh                 # 构建、退出旧进程、ditto 安装到 /Applications
│   ├── package.sh                 # 生成 zip + SHA256SUMS
│   ├── qa-*.py / qa-*.swift / qa-*.html  # 外部 QA 工具，不编译进 App
├── packaging/
│   ├── Info.plist                 # 后台工具 Bundle 配置
│   └── Settings-Info.plist        # 设置 App Bundle 配置
├── lab/event-replay/              # 浏览器输入事件回放实验模块（Node.js）
└── build/ release/ .build/        # 构建产物（已加入 .gitignore）
```

---

## 4. 构建、测试与安装

在仓库根目录执行：

```bash
swift test                 # 单元测试（Debug）
./scripts/build-app.sh     # 构建到 build/SilentClipboard.app 与 build/SilentClipboard Settings.app
./scripts/install.sh       # 构建并安装到 /Applications/，启动新版后台工具
./scripts/package.sh       # 生成 release/SilentClipboard-0.2.0-arm64.zip 与 SHA256SUMS
```

辅助验证：

```bash
node --test lab/event-replay/replay.test.mjs   # 事件回放模块测试
```

说明：

- `build-app.sh` 接受一个配置参数（默认 `release`），例如 `./scripts/build-app.sh debug`。
- 签名身份可用环境变量覆盖：`SRF_SIGN_IDENTITY="Developer ID Application: ..."`；默认 `-` 为 ad-hoc。
- 安装脚本会先退出正在运行的旧静默进程，**不自动启用登录项**。
- 卸载：关闭设置窗口，执行 `./bin/srf login-disable`（若曾启用）和 `./bin/srf quit`，删除两个 App；配置目录与钥匙串条目按需手动删除。

---

## 5. 配置

### 5.1 非密钥配置

路径：`~/Library/Application Support/SilentClipboard/config.json`（目录 0700，文件 0600）。密钥**不在此文件**，只在 Keychain。旧版 0.1 配置自动兼容。

可用 `./bin/srf configure /绝对路径/config.json` 从文件加载并校验。字段示例见 `config.example.json`：

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `apiEndpoint` | `https://api.deepseek.com/chat/completions` | 完整 HTTPS Chat Completions 地址；禁止带 userinfo/query/fragment |
| `model` | `deepseek-flash` | 模型名 |
| `triggerPrefix` | `!!!` | 区分大小写，必须位于剪贴板文本开头，发送前移除 |
| `systemPrompt` | 见示例 | 每次作为 system 消息发送；只是模型指令，不强制截断 |
| `timeoutSeconds` | `60` | 请求超时（1–300） |
| `maxInputBytes` | `32768` | 输入上限 |
| `maxOutputTokens` | `4096` | 输出 token 上限 |
| `hotKeyCode` | `8`（⌃C 的虚拟键码） | 旧版 ⌃⌥⌘J 会自动迁移 |
| `hotKeyModifiers` | `4096`（Control） | 修饰位 |
| `localClipboardOnly` | `true` | 剪贴板写入限定本机 |

### 5.2 命令行（`./bin/srf`）

```
status | process | pause | resume | cancel | quit
set-key             # 终端安全输入密钥，不进命令行参数
authorize           # 主动剪贴板授权
authorize-output    # 主动文字输出授权
settings            # 打开独立设置应用
configure FILE      # 加载非密钥配置
verify | verify-status  # 固定 API 连通性测试，不读写剪贴板
login-enable | login-disable
```

控制 socket 目录 0700、socket 0600、仅同用户 UID 可访问；状态只返回计数和错误分类，不返回问答正文或密钥。

### 5.3 设置应用

打开 `/Applications/SilentClipboard Settings.app` 可配置 API 地址、模型、触发关键字、掩码密钥（存 Keychain）、默认提示词，并执行「测试连接」「保存并生效」「刷新并重启」以及主动授权。

密钥只发给所配置的远端 API；仅对 DeepSeek 官方域名附加关闭 thinking 的扩展参数；不跟随 HTTP 重定向，避免 Authorization 头外泄。

---

## 6. 隐私与安全设计

- 网络：ephemeral `URLSession`，无缓存、无 Cookie、无凭证存储；响应上限 1 MiB；拒绝重定向与 3xx。
- 权限：剪贴板读取只在 `accessBehavior == .alwaysAllow` 时进行；文字输出需辅助功能授权；安全键盘输入启用时不发事件。
- 存储：不保存问答历史、不记录正文日志；配置目录 0700、配置/socket/lock 文件 0600。
- 输出：CGEvent 定向发给前台进程，不激活目标、不读目标内容；只能确认事件发出，不能确认目标实际插入成功。
- 会话：睡眠、屏幕睡眠、会话失活、锁屏、关机均触发暂停并清空答案。

---

## 7. 已知限制

- 当前为 **ad-hoc 签名**：重新构建可能使旧 Keychain 访问或辅助功能授权失效，需在设置应用重新保存密钥并主动更新权限。正式分发应使用稳定 Developer ID 签名并公证。
- 仅 arm64；macOS 15.4 是部署下限，其他系统版本未实机测试。
- CGEvent Unicode 的接收由目标应用决定；自定义编辑器、终端、某些输入法组合状态可能不接受，程序无法确认插入成功。
- NSPasteboard 无跨进程原子比较写入，版本校验与提交之间存在极小竞争窗口。
- 安装版真实 API → 内存回答 → ⌃V 的完整链路、GUI 测试连接、重启后读取密钥等仍需本机人工验收，详见 `TEST-REPORT.md`。外部 QA harness 只验证算法与输出机制，不能替代安装版权限验收。

---

## 8. 参考

- [Apple CGEvent keyboardSetUnicodeString](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:))
- [Apple CGEvent postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:))
- 验收记录：`TEST-REPORT.md`；开发记录：`DEVELOPMENT-PLAN.md`
