import Foundation

struct ToolDefinition {
    let name: String
    let description: String
    let parameters: [String: Any]

    var jsonObject: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters
            ]
        ]
    }
}

enum ToolRisk: Equatable {
    case readOnly
    case mutating
}

enum ToolCatalog {
    static let readOnlyNames: Set<String> = ["read_file", "list_dir", "web_fetch", "todo_write"]

    static func risk(of name: String) -> ToolRisk {
        readOnlyNames.contains(name) ? .readOnly : .mutating
    }

    static func definitions(planMode: Bool) -> [ToolDefinition] {
        let all = [
            readFile, writeFile, editFile, listDir, runShell, webFetch, todoWrite
        ]
        if planMode {
            return all.filter { readOnlyNames.contains($0.name) }
        }
        return all
    }

    static let readFile = ToolDefinition(
        name: "read_file",
        description: "读取沙盒里的一个文本文件，返回带行号的内容。编辑前先读它。",
        parameters: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "文件路径；相对路径从当前工作目录算，也可以用 /home/dsh/… 或 ~/…"
                ],
                "offset": [
                    "type": "integer",
                    "description": "从第几行开始（1 起），默认 1"
                ],
                "limit": [
                    "type": "integer",
                    "description": "最多读多少行，默认 400，最大 800"
                ]
            ],
            "required": ["path"]
        ]
    )

    static let writeFile = ToolDefinition(
        name: "write_file",
        description: "创建或覆盖一个文件（父目录不存在会自动创建）。整个文件内容都要传进来。",
        parameters: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "文件路径"],
                "content": ["type": "string", "description": "完整文件内容"]
            ],
            "required": ["path", "content"]
        ]
    )

    static let editFile = ToolDefinition(
        name: "edit_file",
        description: "精确替换文件里的一段文本。old_string 必须与文件内容完全一致（含缩进），默认要求只出现一次。",
        parameters: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "文件路径"],
                "old_string": ["type": "string", "description": "要被替换的原文"],
                "new_string": ["type": "string", "description": "替换成的新文本，可为空"],
                "replace_all": ["type": "boolean", "description": "替换所有出现的地方，默认 false"]
            ],
            "required": ["path", "old_string", "new_string"]
        ]
    )

    static let listDir = ToolDefinition(
        name: "list_dir",
        description: "列出一个目录（默认当前目录）的树状结构，含文件大小。",
        parameters: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "目录路径，默认 ."],
                "depth": ["type": "integer", "description": "递归深度，默认 2，最大 4"]
            ],
            "required": []
        ]
    )

    static let runShell = ToolDefinition(
        name: "run_shell",
        description: """
        在手机的沙盒 shell 里执行一条命令（支持管道、重定向、&&/||、变量、通配符）。
        内置命令：ls cat grep find tree wc head tail mkdir rm mv cp sort uniq curl 等，
        不是完整的 Linux，没有 python/git/node。会返回输出和退出码。
        """,
        parameters: [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "要执行的命令，例如 ls -la && cat README.md"]
            ],
            "required": ["command"]
        ]
    )

    static let webFetch = ToolDefinition(
        name: "web_fetch",
        description: "抓取一个 http/https 页面或接口，返回去掉标签后的文本（截断到约 8000 字符）。",
        parameters: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "完整 URL"]
            ],
            "required": ["url"]
        ]
    )

    static let todoWrite = ToolDefinition(
        name: "todo_write",
        description: "维护本次任务的待办列表。传完整列表（不是增量），状态用 pending / in_progress / completed。",
        parameters: [
            "type": "object",
            "properties": [
                "todos": [
                    "type": "array",
                    "description": "待办列表",
                    "items": [
                        "type": "object",
                        "properties": [
                            "content": ["type": "string", "description": "任务描述"],
                            "status": ["type": "string", "description": "pending / in_progress / completed"]
                        ],
                        "required": ["content", "status"]
                    ]
                ]
            ],
            "required": ["todos"]
        ]
    )
}

// MARK: - 执行器

final class SandboxToolExecutor {
    let fs: VirtualFS
    let shell: Shell
    var planMode = false

    init(fs: VirtualFS, shell: Shell) {
        self.fs = fs
        self.shell = shell
    }

    func execute(_ call: ToolCall) async -> ToolResult {
        guard let args = SandboxToolExecutor.parseArguments(call.arguments) else {
            return .fail("参数不是合法 JSON：\(call.arguments.prefix(300))")
        }
        switch call.name {
        case "read_file":
            return readFile(args)
        case "write_file":
            return writeFile(args)
        case "edit_file":
            return editFile(args)
        case "list_dir":
            return listDir(args)
        case "run_shell":
            return await runShell(args)
        case "web_fetch":
            return await webFetch(args)
        case "todo_write":
            return todoWrite(args)
        default:
            return .fail("未知工具：\(call.name)")
        }
    }

    // MARK: 参数

    static func parseArguments(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func string(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }

    private func int(_ args: [String: Any], _ key: String, default fallback: Int) -> Int {
        (args[key] as? NSNumber)?.intValue ?? fallback
    }

    private func bool(_ args: [String: Any], _ key: String) -> Bool {
        (args[key] as? NSNumber)?.boolValue ?? (args[key] as? Bool) ?? false
    }

    private func resolve(_ path: String) -> String {
        fs.resolve(path, cwd: shell.cwd)
    }

    // MARK: 文件

    private func readFile(_ args: [String: Any]) -> ToolResult {
        guard let raw = string(args, "path") else { return .fail("缺少 path") }
        let path = resolve(raw)
        do {
            let text = try fs.read(path)
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            if lines.isEmpty { return .ok("(空文件) \(path)") }
            let offset = max(1, int(args, "offset", default: 1))
            let limit = min(800, max(1, int(args, "limit", default: 400)))
            let start = min(offset - 1, lines.count)
            let end = min(lines.count, start + limit)
            guard start < end else { return .ok("(没有更多内容，共 \(lines.count) 行)") }
            var out = ""
            for index in start..<end {
                out += String(format: "%5d\t", index + 1) + lines[index] + "\n"
            }
            if end < lines.count {
                out += "…（共 \(lines.count) 行，已显示 \(start + 1)–\(end)）\n"
            }
            return .ok(out)
        } catch let error as ShellError {
            return .fail(error.message)
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func writeFile(_ args: [String: Any]) -> ToolResult {
        guard let raw = string(args, "path") else { return .fail("缺少 path") }
        guard let content = string(args, "content") else { return .fail("缺少 content") }
        let path = resolve(raw)
        do {
            let parent = fs.parent(of: path)
            if !fs.isDirectory(parent) {
                try fs.mkdir(parent, parents: true)
            }
            try fs.write(content, to: path, append: false)
            let lines = content.components(separatedBy: "\n").count
            return .ok("已写入 \(path)（\(content.utf8.count) 字节，\(lines) 行）")
        } catch let error as ShellError {
            return .fail(error.message)
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func editFile(_ args: [String: Any]) -> ToolResult {
        guard let raw = string(args, "path") else { return .fail("缺少 path") }
        guard let oldString = string(args, "old_string") else { return .fail("缺少 old_string") }
        guard let newString = string(args, "new_string") else { return .fail("缺少 new_string") }
        guard !oldString.isEmpty else { return .fail("old_string 不能为空") }
        let path = resolve(raw)
        do {
            let text = try fs.read(path)
            let occurrences = text.components(separatedBy: oldString).count - 1
            if occurrences == 0 {
                return .fail("在 \(path) 里找不到 old_string。先 read_file 看看当前内容（注意缩进和换行）。")
            }
            let replaceAll = bool(args, "replace_all")
            if occurrences > 1 && !replaceAll {
                return .fail("old_string 在文件里出现 \(occurrences) 次。提供更长的上下文，或把 replace_all 设为 true。")
            }
            let updated: String
            if replaceAll {
                updated = text.replacingOccurrences(of: oldString, with: newString)
            } else if let range = text.range(of: oldString) {
                updated = text.replacingCharacters(in: range, with: newString)
            } else {
                return .fail("替换失败")
            }
            try fs.write(updated, to: path, append: false)
            return .ok("已编辑 \(path)：替换 \(replaceAll ? occurrences : 1) 处")
        } catch let error as ShellError {
            return .fail(error.message)
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func listDir(_ args: [String: Any]) -> ToolResult {
        let raw = string(args, "path") ?? "."
        let root = resolve(raw)
        guard fs.isDirectory(root) else { return .fail("不是目录：\(root)") }
        let depth = min(4, max(1, int(args, "depth", default: 2)))
        var out = "\(fs.relative(root, from: shell.cwd))/\n"
        var dirs = 0
        var files = 0
        walk(root, prefix: "", depth: 1, maxDepth: depth, out: &out, dirs: &dirs, files: &files)
        out += "\n\(dirs) 个目录, \(files) 个文件"
        return .ok(out)
    }

    private func walk(_ path: String,
                      prefix: String,
                      depth: Int,
                      maxDepth: Int,
                      out: inout String,
                      dirs: inout Int,
                      files: inout Int) {
        guard depth <= maxDepth else { return }
        let names = (try? fs.contents(path)) ?? []
        let visible = names.filter { !$0.hasPrefix(".") }
        for (index, name) in visible.enumerated() {
            let isLast = index == visible.count - 1
            let itemPath = fs.join(path, name)
            let info = fs.info(itemPath)
            let isDir = info?.isDirectory ?? false
            let connector = isLast ? "└── " : "├── "
            let size = isDir ? "" : "  (\(Fmt.humanSize(info?.size ?? 0)))"
            out += prefix + connector + name + (isDir ? "/" : "") + size + "\n"
            if isDir {
                dirs += 1
                let nextPrefix = prefix + (isLast ? "    " : "│   ")
                walk(itemPath, prefix: nextPrefix, depth: depth + 1, maxDepth: maxDepth, out: &out, dirs: &dirs, files: &files)
            } else {
                files += 1
            }
        }
    }

    // MARK: Shell

    private func runShell(_ args: [String: Any]) async -> ToolResult {
        guard let command = string(args, "command"), !command.isEmpty else {
            return .fail("缺少 command")
        }
        if planMode {
            return .fail("Plan mode 已开启：不能执行 shell 命令。先给出计划，等用户关闭 plan mode。")
        }
        let result = await shell.run(command)
        var text = result.stdout
        if !result.stderr.isEmpty { text += result.stderr }
        if text.isEmpty { text = "(无输出)" }
        let limit = 12000
        if text.count > limit {
            text = String(text.prefix(limit)) + "\n…（输出被截断）"
        }
        text += "\n[exit \(result.status)]"
        return ToolResult(output: text, isError: result.status != 0)
    }

    // MARK: 网络

    private func webFetch(_ args: [String: Any]) async -> ToolResult {
        guard var raw = string(args, "url")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .fail("缺少 url")
        }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .fail("只支持 http/https URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) dsh-ios/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .fail("没有收到 HTTP 响应")
            }
            guard (200..<400).contains(http.statusCode) else {
                return .fail("HTTP \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))")
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let body: String
            if contentType.contains("json") || contentType.contains("text") || contentType.contains("xml") || contentType.isEmpty {
                body = String(data: data.prefix(400_000), encoding: .utf8) ?? "(无法解码为文本)"
            } else {
                return .ok("(二进制响应 \(data.count) 字节, \(contentType))")
            }
            var text = contentType.contains("html") ? SandboxToolExecutor.stripHTML(body) : body
            let limit = 8000
            if text.count > limit {
                text = String(text.prefix(limit)) + "\n…（已截断，共 \(text.count) 字符）"
            }
            return .ok(text)
        } catch {
            return .fail("抓取失败：\(error.localizedDescription)")
        }
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        let patterns = [
            "(?is)<script[^>]*>.*?</script>",
            "(?is)<style[^>]*>.*?</style>",
            "(?is)<noscript[^>]*>.*?</noscript>",
            "(?is)<!--.*?-->"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            }
        }
        let breaks = ["</p>", "</div>", "</li>", "<br", "</h1>", "</h2>", "</h3>", "</tr>", "</section>"]
        for token in breaks {
            text = text.replacingOccurrences(of: token, with: "\n", options: .caseInsensitive)
        }
        if let regex = try? NSRegularExpression(pattern: "(?s)<[^>]+>") {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&hellip;": "…"
        ]
        for (key, value) in entities {
            text = text.replacingOccurrences(of: key, with: value)
        }
        var lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\t", with: " ")
        }
        lines = lines.map { line -> String in
            var value = line
            while value.contains("  ") {
                value = value.replacingOccurrences(of: "  ", with: " ")
            }
            return value.trimmingCharacters(in: .whitespaces)
        }
        var cleaned: [String] = []
        for line in lines {
            if line.isEmpty && cleaned.last?.isEmpty == true { continue }
            cleaned.append(line)
        }
        return cleaned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Todo

    private func todoWrite(_ args: [String: Any]) -> ToolResult {
        guard let rawTodos = args["todos"] as? [[String: Any]] else {
            return .fail("缺少 todos 数组")
        }
        if rawTodos.isEmpty { return .ok("(待办清单已清空)") }
        var out = "待办清单：\n"
        for item in rawTodos {
            let content = (item["content"] as? String) ?? "(未命名)"
            let status = (item["status"] as? String) ?? "pending"
            let mark: String
            switch status {
            case "completed": mark = "☑"
            case "in_progress": mark = "◐"
            default: mark = "☐"
            }
            out += "\(mark) \(content)\n"
        }
        return .ok(out.trimmingCharacters(in: .newlines))
    }
}
