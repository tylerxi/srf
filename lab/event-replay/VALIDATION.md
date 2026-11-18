# 验证记录

2026-11-17，本机 Node.js 22.21.0 与 Ego Lite 浏览器。

## 自动检查

运行 `node --test lab/event-replay/replay.test.mjs`：3 项测试通过。

- 非法事件类型、超长数据、过量事件、无效延迟在发送前拒绝。
- 无效目标拒绝，不访问其他 DOM 元素。
- 模块可在无浏览器全局对象的环境导入，不自动执行。

## 浏览器实际 DOM 验证

通过 localhost 临时 HTTP 服务导入模块，创建临时 textarea 调用回放；未创建防御网页，未连接第三方网站。

| 操作 | 观察结果 |
|---|---|
| `fixtures.keyboard` | 最终值 `ab`；两个完整 down / beforeinput / input / up 序列 |
| `fixtures.composition` | start / update / end 均收到，输入值依次 `n`、`ni`、`你`，没有累计成 `nni你` |
| `fixtures.multiCharacter` | 一个 down/up 对，input 数据 `中文`，最终值 `中文` |
| beforeinput 调用 preventDefault | 最终值为空，input 事件数为 0 |
| AbortController 中止 | outcome 为 aborted |
| 所有观察到的事件 | isTrusted=false |

这仅验证合成样本模块的 DOM 行为。尚未收到用户现有测试网页，未验证该页的检测规则。没有修改原生输入后端、伪造可信事件、模拟真人随机节奏或篡改检测数据。
