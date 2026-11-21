# AGENTS.md

这个仓库接入了 [ios-ci-workflows](https://github.com/wenjinliuu/ios-ci-workflows)（v1.1.0）。
改代码、写测试、读报告、发版之前先读技能：`/var/minis/skills/ios-ci-workflows/SKILL.md`，
以及 `setup.md` / `daily.md` / `release.md`。

## 必须遵守

- **CI 是唯一测试入口**：改完 push，读 Build & Test 的报告再修；不要在本地另起一套跑测试“证明”通过。
- **新功能必须带测试**：逻辑放 `Tests/`，用 XCTest；UI 测试不写（本 App 没有 UI 测试）。
- **删测试 / 改断言要写理由**：只能因为功能删除、完全重复、或被更便宜的测试覆盖。
- **不要写明文密钥**：API Key 只在 App 的 Keychain / 仓库 Secrets 里。
- **不要引用中央仓库 `@main`**：工作流统一 `@df71d6096d6d39ea799179cb2635703548b07ae0 # v1.1.0`。

## 工程约定

- 工程文件由 XcodeGen 生成（`project.yml`），`.xcodeproj` 不进仓库。
- 生成后必须跑 `python3 Scripts/sync-test-plans.py` 回填测试计划里的 target ID。
- 最低 iOS 16.0，Swift 5.9，零第三方依赖；新代码尽量保持 `SWIFT_STRICT_CONCURRENCY: minimal` 能过。
- 文件系统操作一律走 `VirtualFS`，不要直接 `FileManager` 拼绝对路径（沙盒边界靠它）。
- 工具参数解析失败要返回 `ToolResult.fail`，不要把异常抛给模型循环。
- 工具要区分只读/写入：`ToolCatalog.risk(of:)` 与 `ToolCatalog.readOnlyNames` 是审批和 plan mode 的唯一依据。

## 常用命令

```bash
xcodegen generate && python3 Scripts/sync-test-plans.py   # 生成工程
xcodebuild test -project Dsh.xcodeproj -scheme Dsh -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

CI 失败时用 `gh run view` / GitHub API 读 `Build & Test` 的日志和 xcresult 摘要。
