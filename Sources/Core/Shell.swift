import Foundation

struct ShellResult: Equatable {
    var stdout: String = ""
    var stderr: String = ""
    var status: Int32 = 0
    var effect: ShellEffect = .none
}

final class CommandRegistry {
    private(set) var commands: [String: ShellCommand] = [:]

    init(commands: [ShellCommand] = CommandRegistry.defaultCommands) {
        for command in commands {
            self.commands[command.name] = command
        }
    }

    func command(_ name: String) -> ShellCommand? { commands[name] }

    var names: [String] { commands.keys.sorted() }

    static var defaultCommands: [ShellCommand] {
        [
            // 文件系统
            LsCommand(), CdCommand(), PwdCommand(), CatCommand(), MkdirCommand(),
            TouchCommand(), RmCommand(), RmdirCommand(), CpCommand(), MvCommand(),
            HeadCommand(), TailCommand(), WcCommand(), FindCommand(), TreeCommand(),
            StatCommand(), FileCommand(), DuCommand(), BasenameCommand(), DirnameCommand(),
            RealpathCommand(),

            // 文本
            EchoCommand(), PrintfCommand(), GrepCommand(), SortCommand(), UniqCommand(),
            RevCommand(), CutCommand(), Base64Command(), Sha256Command(),

            // 系统
            WhoamiCommand(), HostnameCommand(), UnameCommand(), DateCommand(),
            UptimeCommand(), EnvCommand(), ExportCommand(), UnsetCommand(),
            AliasCommand(), UnaliasCommand(), HistoryCommand(), ClearCommand(),
            HelpCommand(), ManCommand(), WhichCommand(), TypeCommand(), ExitCommand(),
            VersionCommand(), NeofetchCommand(), SudoCommand(), TrueCommand(), FalseCommand(),

            // 网络
            CurlCommand()
        ]
    }
}

final class Shell {
    let fs: VirtualFS
    let registry: CommandRegistry

    var cwd: String
    var previousDirectory: String
    var vars: [String: String]
    var aliases: [String: String]
    private(set) var history: [String] = []
    private(set) var lastStatus: Int32 = 0
    let startedAt = Date()
    let hostname: String
    private(set) var commandCount: Int = 0

    init(fs: VirtualFS, registry: CommandRegistry = CommandRegistry()) {
        self.fs = fs
        self.registry = registry
        self.cwd = VirtualFS.home
        self.previousDirectory = VirtualFS.home
        self.hostname = "iphone"
        self.vars = [
            "HOME": VirtualFS.home,
            "USER": "dsh",
            "LOGNAME": "dsh",
            "SHELL": "/usr/bin/zsh",
            "PWD": VirtualFS.home,
            "OLDPWD": VirtualFS.home,
            "TERM": "xterm-256color",
            "LANG": "zh_CN.UTF-8",
            "HOSTNAME": "iphone",
            "EDITOR": "nvim",
            "PATH": "/usr/local/bin:/usr/bin:/bin"
        ]
        self.aliases = [
            "ll": "ls -l",
            "la": "ls -la",
            "..": "cd ..",
            "g": "grep"
        ]
    }

    // MARK: - 变量

    func value(for name: String) -> String {
        switch name {
        case "?": return String(lastStatus)
        case "PWD": return cwd
        case "OLDPWD": return previousDirectory
        default: return vars[name] ?? ""
        }
    }

    func setVar(_ name: String, _ value: String) {
        vars[name] = value
    }

    func remember(_ line: String) {
        guard history.last != line else { return }
        history.append(line)
        if history.count > 500 {
            history.removeFirst(history.count - 500)
        }
    }

    func clearHistory() {
        history.removeAll()
    }

    // MARK: - 执行

    func run(_ line: String) async -> ShellResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ShellResult() }

        remember(trimmed)
        commandCount += 1

        do {
            let tokens = try Tokenizer.tokenize(trimmed)
            let items = try Parser.parse(tokens)
            var stdout = ""
            var stderr = ""
            var status: Int32 = 0
            var effect: ShellEffect = .none
            var previousOp: ChainOperator?
            var previousStatus: Int32 = 0

            for item in items {
                var shouldRun = true
                if let op = previousOp {
                    switch op {
                    case .seq: shouldRun = true
                    case .and: shouldRun = previousStatus == 0
                    case .or: shouldRun = previousStatus != 0
                    }
                }

                if shouldRun {
                    let result = await runPipeline(item.pipeline)
                    stdout += result.stdout
                    stderr += result.stderr
                    status = result.status
                    previousStatus = result.status
                    if !result.effect.isNone { effect = result.effect }
                } else {
                    status = previousStatus
                }
                previousOp = item.opToNext
            }

            lastStatus = status
            return ShellResult(stdout: stdout, stderr: stderr, status: status, effect: effect)
        } catch let error as ShellError {
            lastStatus = error.status
            return ShellResult(stderr: "dsh: \(error.message)\n", status: error.status)
        } catch {
            lastStatus = 1
            return ShellResult(stderr: "dsh: \(error.localizedDescription)\n", status: 1)
        }
    }

    private func runPipeline(_ pipeline: Pipeline) async -> ShellResult {
        var stdin = ""
        var stderr = ""
        var status: Int32 = 0
        var effect: ShellEffect = .none
        var finalStdout = ""

        let total = pipeline.commands.count
        for (index, rawCommand) in pipeline.commands.enumerated() {
            var command = expandAliases(in: rawCommand)

            if let inputFile = command.inFile {
                let path = fs.resolve(inputFile, cwd: cwd)
                do {
                    stdin = try fs.read(path)
                } catch let error as ShellError {
                    return ShellResult(stderr: "dsh: \(error.message)\n", status: 1)
                } catch {
                    return ShellResult(stderr: "dsh: \(error.localizedDescription)\n", status: 1)
                }
            }

            command.words = Expander(shell: self).expand(command.words)
            guard let name = command.words.first else { continue }

            guard let executable = registry.command(name) else {
                let notFound = CommandResult(stderr: "dsh: command not found: \(name)\n", status: 127)
                stderr += notFound.stderr
                status = notFound.status
                stdin = ""
                if index == total - 1 { finalStdout = "" }
                continue
            }

            let ctx = CommandContext(shell: self, argv: command.words, stdin: stdin)
            var result = await executable.run(ctx)

            if let redirect = command.outRedirect {
                let path = fs.resolve(redirect.path, cwd: cwd)
                do {
                    try fs.write(result.stdout, to: path, append: redirect.append)
                    result.stdout = ""
                } catch let error as ShellError {
                    result.stderr += "dsh: \(error.message)\n"
                    result.status = 1
                } catch {
                    result.stderr += "dsh: \(error.localizedDescription)\n"
                    result.status = 1
                }
            }

            if let redirect = command.errRedirect {
                let path = fs.resolve(redirect.path, cwd: cwd)
                do {
                    try fs.write(result.stderr, to: path, append: redirect.append)
                    result.stderr = ""
                } catch let error as ShellError {
                    result.stderr += "dsh: \(error.message)\n"
                    result.status = 1
                } catch {
                    result.stderr += "dsh: \(error.localizedDescription)\n"
                    result.status = 1
                }
            }

            stderr += result.stderr
            status = result.status
            if !result.effect.isNone { effect = result.effect }

            if index == total - 1 {
                finalStdout = result.stdout
            } else {
                stdin = result.stdout
            }
        }

        return ShellResult(stdout: finalStdout, stderr: stderr, status: status, effect: effect)
    }

    private func expandAliases(in command: SimpleCommand) -> SimpleCommand {
        var result = command
        var rounds = 0
        while let first = result.words.first,
              let value = aliases[first],
              rounds < 8 {
            guard let tokens = try? Tokenizer.tokenize(value) else { break }
            var aliasWords: [String] = []
            var valid = true
            for token in tokens {
                if case .word(let word) = token {
                    aliasWords.append(word)
                } else {
                    valid = false
                    break
                }
            }
            if !valid || aliasWords.isEmpty { break }
            result.words = aliasWords + Array(result.words.dropFirst())
            rounds += 1
        }
        return result
    }

    // MARK: - 提示符

    func displayPath() -> String {
        if cwd == VirtualFS.home { return "~" }
        if cwd.hasPrefix(VirtualFS.home + "/") {
            return "~" + String(cwd.dropFirst(VirtualFS.home.count))
        }
        return cwd
    }

    func gitBranch() -> String? {
        var dir = cwd
        for _ in 0..<12 {
            let gitPath = fs.join(dir, ".git")
            if fs.exists(gitPath) {
                let headPath = fs.join(gitPath, "HEAD")
                if let head = try? fs.read(headPath) {
                    let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.hasPrefix("ref: refs/heads/") {
                        return String(text.dropFirst("ref: refs/heads/".count))
                    }
                    return String(text.prefix(7))
                }
                return "detached"
            }
            if dir == "/" { break }
            dir = fs.parent(of: dir)
        }
        return nil
    }

    func prompt() -> String {
        var path = displayPath()
        if path.count > 26 {
            path = "…" + String(path.suffix(24))
        }
        var branch = ""
        if let name = gitBranch() {
            branch = " \u{1B}[1;34m(\(name))\u{1B}[0m"
        }
        return "\u{1B}[1;32mdsh@\(hostname)\u{1B}[0m:\u{1B}[1;36m\(path)\u{1B}[0m\(branch) \u{1B}[1;35m%\u{1B}[0m"
    }

    /// 给 UI 用：不带 ANSI 的提示符（复制输出时更干净）。
    func plainPrompt() -> String {
        "dsh@\(hostname):\(displayPath()) %"
    }

    // MARK: - Tab 补全

    /// 返回（补全后的输入, 候选列表）。候选多于一个时 UI 把它们打出来。
    func complete(_ input: String) -> (String, [String]) {
        let parts = input.components(separatedBy: " ")
        let isCommandPosition = parts.count == 1
        let prefix = parts.last ?? ""
        var pieces = parts

        if isCommandPosition {
            var candidates = registry.names.filter { $0.hasPrefix(prefix) }
            candidates += aliases.keys.filter { $0.hasPrefix(prefix) && !candidates.contains($0) }
            candidates.sort()
            if candidates.isEmpty { return (input, []) }
            if candidates.count == 1 {
                pieces[pieces.count - 1] = candidates[0] + " "
                return (pieces.joined(separator: " "), [])
            }
            let common = Shell.longestCommonPrefix(candidates)
            if common.count > prefix.count {
                pieces[pieces.count - 1] = common
                return (pieces.joined(separator: " "), candidates)
            }
            return (input, candidates)
        }

        let dirPart: String
        let namePrefix: String
        if let index = prefix.lastIndex(of: "/") {
            dirPart = String(prefix[prefix.startIndex...index])
            namePrefix = String(prefix[prefix.index(after: index)...])
        } else {
            dirPart = ""
            namePrefix = prefix
        }

        let baseDir = dirPart.isEmpty ? "." : String(dirPart.dropLast())
        let basePath = fs.resolve(baseDir, cwd: cwd)
        guard let names = try? fs.contents(basePath) else { return (input, []) }

        var candidates: [(text: String, isDirectory: Bool)] = []
        var seen = Set<String>()
        for name in names {
            if name.hasPrefix(".") && !namePrefix.hasPrefix(".") { continue }
            guard name.hasPrefix(namePrefix) else { continue }
            let fullPath = fs.join(basePath, name)
            let isDir = fs.isDirectory(fullPath)
            let text = dirPart + name + (isDir ? "/" : "")
            if seen.insert(text).inserted {
                candidates.append((text, isDir))
            }
        }
        candidates.sort { $0.text < $1.text }

        if candidates.isEmpty { return (input, []) }
        if candidates.count == 1, let only = candidates.first {
            pieces[pieces.count - 1] = only.text + (only.isDirectory ? "" : " ")
            return (pieces.joined(separator: " "), [])
        }

        let texts = candidates.map { $0.text }
        let common = Shell.longestCommonPrefix(texts)
        if common.count > prefix.count {
            pieces[pieces.count - 1] = common
            return (pieces.joined(separator: " "), texts)
        }
        return (input, texts)
    }

    static func longestCommonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for value in strings.dropFirst() {
            while !value.hasPrefix(prefix) && !prefix.isEmpty {
                prefix.removeLast()
            }
            if prefix.isEmpty { break }
        }
        return prefix
    }
}
