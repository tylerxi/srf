# 输入事件回放模块

供自有测试网页检测事件处理逻辑。没有附带防御网页、浏览器扩展或常驻服务；不修改现有 macOS 工具和安装包。

## 接入现有网页

把 `replay.mjs` 放入你的开发项目，通过模块导入。在网页上准备一个专用于测试的 textarea 或文本 input，调用：

```js
import { fixtures, replay, downloadReport } from './replay.mjs';

const target = document.querySelector('#test-input');
// 由测试按钮主动调用，不要指向用户实际答题或提交表单的输入框。
const report = await replay(target, fixtures.composition);
console.table(report.events);
downloadReport(report);
```

如果只是临时加载，可在此目录运行 `python3 -m http.server 8766 --bind 127.0.0.1`；在同源本地开发页面中导入 `/replay.mjs`。不要为加载模块关闭浏览器安全检查。

## 三个测试样本

| 样本 | 输入结果 | 检查目标 |
|---|---|---|
| `fixtures.keyboard` | `ab` | down/up 配对、固定间隔与按住时长、普通文本插入 |
| `fixtures.composition` | `你` | start/update/end 状态、组合文本逐次替换而不重复追加 |
| `fixtures.multiCharacter` | `中文` | 单次键盘事件对应多字、无组合输入的中文等异常规则 |

样本可通过 JSON 形式显式指定 `steps`。`delayMs` 是相对上一条事件的固定等待时间；使用固定时间便于复现测试，不随机生成所谓“真人特征”。实际计时受浏览器调度影响，报告保存实际发出时间。样本最多 2000 条事件，每条延迟不超过 5 秒。

```js
const controller = new AbortController();
const pending = replay(target, fixtures.keyboard, { signal: controller.signal });
controller.abort();
const report = await pending; // outcome: "aborted"
```

## 必须区分的测试边界

- 这里的 KeyboardEvent、InputEvent、CompositionEvent 均为 JS 合成事件，`isTrusted === false`。不能把报告用作原生输入法、操作系统输入或人工打字的证据。
- `dispatchEvent` 不会自动触发浏览器默认输入，因此模块显式修改测试输入框，在可取消的 beforeinput 与 input 之间插入文本。检测器可能识别这条路径，这是正常结果。
- composition 样本是一个声明好的测试序列，不代表所有浏览器和输入法的实际顺序。测试真正的中文输入法，需要人在目标系统上实际输入并采样。
- 尊重 keydown 和 beforeinput 的 preventDefault；不会移除监听器、改写上报、绕过输入限制或设置 `isTrusted`。
- 额外发出 `input-lab:replay` 自定义事件，包含 `source: synthetic-fixture` 和开始/结束标记，便于区分实验样本。
- 不访问剪贴板、API Token、其他控件或远程网页；无网络请求。测试报告含样本字符，请仅使用测试文本。

现有原生工具仍通过 `Sources/SilentClipboardApp/TextOutput.swift` 发出 CGEvent；这个模块不让其伪装成原生输入法，也不需要重建应用、重新授权或保存密钥。

## 验证

```bash
node --test lab/event-replay/replay.test.mjs
```

浏览器实测记录见 `VALIDATION.md`。
