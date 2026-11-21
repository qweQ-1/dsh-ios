# dsh for iOS

**DeepSeek Harness 的原生 iOS 版**：把 dsh 的「流式对话 + 工具循环 + 沙盒工作区」搬到手机上，
SwiftUI 写的，不依赖 iSH，也不是把 Node 塞进 App。

> dsh = `@deepseek-ai/dsh`（DeepSeek Harness），DeepSeek 官方的命令行智能体。
> 这个仓库是它的 iOS 原生实现：模型仍然是 DeepSeek API，工具换成了 iOS 沙盒里的等价物。

```
┌──────────────┐   SSE    ┌──────────────────┐  tool_calls  ┌─────────────────────┐
│  SwiftUI UI  │ ◀──────▶ │  DeepSeekClient  │ ◀──────────▶ │  AgentEngine 循环    │
└──────────────┘          └──────────────────┘              └─────────┬───────────┘
                                                                       │
                                              ┌────────────────────────┴──────────────┐
                                              │ read/write/edit/list · run_shell ·    │
                                              │ web_fetch · todo · 审批 · plan mode   │
                                              └────────────────────────┬──────────────┘
                                                                       │
                                                            Application Support/DshRoot
```

## 功能

- **流式对话**：DeepSeek `chat/completions` SSE，支持 `deepseek-chat` / `deepseek-reasoner`，
  reasoning 单独折叠展示，token 用量实时显示。
- **工具循环**：模型返回 tool_calls → App 执行 → 结果回灌 → 继续，直到给出最终回答（可设步数上限）。
- **内置沙盒 shell**（`run_shell`）：`ls cd cat echo grep find tree wc head tail mkdir rm mv cp
  sort uniq curl …`，支持 `|` `>` `>>` `2>` `&&` `||` `$VAR` `*` 通配符。
- **文件工具**：`read_file`（带行号）、`write_file`、`edit_file`（精确替换 + 唯一性检查）、`list_dir`。
- **网页抓取**：`web_fetch`，HTML 转文本，截断到 8k 字符。
- **待办**：`todo_write`，在对话里渲染清单。
- **审批**：写文件 / 改文件 / 跑命令默认弹卡片确认；读操作自动放行。
- **Plan mode**：只暴露只读工具，先出方案再动手。
- **会话**：本地 JSON 持久化，自动起标题，可切换 / 删除 / 新建。
- **人设**：dsh / 工程师 / 极简 / 讲解，外加一段自定义附加指令。
- **工作区浏览器**：直接看沙盒里的文件，点开预览。
- **Keychain**：API Key 只存在本机钥匙串，不进会话文件、不进日志。

## 安装（unsigned IPA）

CI 的 **Unsigned IPA** 工作流会产出 `Dsh-unsigned.ipa`：

1. 打开 Actions → 最近一次 `Unsigned IPA` → Artifacts → 下载 `dsh-unsigned-ipa`。
2. 用 **AltStore / Sideloadly / 轻松签** 等自签工具装入 iPhone（免费 Apple ID 即可，7 天有效期）。
3. 第一次启动去 **设置** 填 DeepSeek API Key（[获取地址](https://platform.deepseek.com/api_keys)）。

> 没有签名的 IPA 不能直接双击安装，必须有自签工具或开发者证书。

## 使用

1. 设置里填 `sk-…`，点「测试连接」，应返回 `deepseek-chat`、`deepseek-reasoner`。
2. 回主界面直接说任务，例如：
   - 「看看工作区里有什么」
   - 「写一个 backup.sh，把 ~/notes 打包成 tar.gz」
   - 「读一下 ~/README.md，翻译成英文再写回去」
3. dsh 要写文件 / 跑命令时会弹审批卡片；允许后它继续。
4. 想让它只出方案：点右上角盾牌进入 **PLAN**，或者设置里打开「新会话默认计划模式」。
5. 所有文件都在 App 沙盒的 `Application Support/DshRoot`，等价于 dsh 的 `/`；`~` 是 `/home/dsh`。

## 工具一览

| 工具 | 作用 | 计划模式 | 需要审批 |
| --- | --- | --- | --- |
| `read_file` | 读文件，带行号，可 offset/limit | ✅ | 否 |
| `list_dir` | 树状列目录 | ✅ | 否 |
| `web_fetch` | 抓 http/https 页面 | ✅ | 否 |
| `todo_write` | 维护待办 | ✅ | 否 |
| `write_file` | 新建/覆盖文件 | ❌ | 是 |
| `edit_file` | 精确替换文本 | ❌ | 是 |
| `run_shell` | 沙盒 shell 命令 | ❌ | 是 |

## 目录

```
Sources/
  App/            入口
  Models/         ChatMessage / Session / Settings / Keychain
  Harness/        DeepSeekClient（SSE）、AgentEngine、Tools、SessionStore
  Core/           VirtualFS、Tokenizer、Parser、Expander、Shell、ANSI
  Commands/       shell 内置命令（run_shell 用）
  UI/             ChatScreen、Markdown、Settings、Sessions、Workspace
Tests/            纯逻辑测试（分词/语法/命令/工具/SSE/Agent/会话/Markdown）
.github/workflows build-test.yml + unsigned-ipa.yml（走 ios-ci-workflows v1.1.0）
```

## 构建

CI 是唯一入口（配置见 `.ios-ci.yml`）：

- **Build & Test**：每次 push 编译 + 跑单元测试，报告在 run 的 summary 里。
- **Unsigned IPA**：手动触发或 main 分支改动后自动打不签名 IPA。

本地需要 Mac + XcodeGen：

```bash
xcodegen generate && python3 Scripts/sync-test-plans.py
open Dsh.xcodeproj
```

最低 iOS 16.0，零第三方依赖（没有 SPM / CocoaPods）。

## 限制（诚实版）

- iOS 不允许执行任意二进制，所以 shell 是**用 Swift 重写的一套常用命令**，没有 `python`、`git`、`node`、`ffmpeg`。
- 没有 SSH / 公网访问他人机器；`curl` 只做 GET/HEAD，不跟随重定向开关（默认跟随）。
- 沙盒工作区随 App 卸载删除；不做 iCloud 同步。
- 工具调用串行执行，没有并行子代理。

## License

MIT
