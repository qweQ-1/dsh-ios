import Foundation

// MARK: - ls

struct LsCommand: ShellCommand {
    let name = "ls"
    let summary = "列出目录内容"
    var usage: String { "ls [-l] [-a] [-h] [path ...]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "lah")
        if let bad = parsed.unknown.first {
            return .err("ls: invalid option \(bad)\n", status: 2)
        }
        let longFormat = parsed.has("l")
        let showAll = parsed.has("a")
        let human = parsed.has("h")
        let targets = parsed.operands.isEmpty ? ["."] : parsed.operands
        let multiple = targets.count > 1
        var stdout = ""
        var stderr = ""
        var status: Int32 = 0

        for (index, target) in targets.enumerated() {
            let path = ctx.fs.resolve(target, cwd: ctx.cwd)
            guard let info = ctx.fs.info(path) else {
                stderr += "ls: \(target): No such file or directory\n"
                status = 1
                continue
            }
            if !info.isDirectory {
                stdout += render(name: target, path: path, fs: ctx.fs, long: longFormat, human: human) + "\n"
                continue
            }
            if multiple { stdout += "\(target):\n" }
            let names = ((try? ctx.fs.contents(path)) ?? [])
                .filter { showAll || !$0.hasPrefix(".") }
            if longFormat {
                for entry in names {
                    stdout += render(name: entry,
                                     path: ctx.fs.join(path, entry),
                                     fs: ctx.fs,
                                     long: true,
                                     human: human) + "\n"
                }
            } else if !names.isEmpty {
                stdout += columns(names: names, dir: path, fs: ctx.fs)
            }
            if multiple && index < targets.count - 1 { stdout += "\n" }
        }
        return CommandResult(stdout: stdout, stderr: stderr, status: status)
    }

    private func render(name: String, path: String, fs: VirtualFS, long: Bool, human: Bool) -> String {
        let info = fs.info(path)
        let isDir = info?.isDirectory ?? false
        let colored = colorize(name: name, path: path, isDir: isDir, fs: fs)
        guard long else { return colored }
        let mode: String
        if isDir {
            mode = "drwxr-xr-x"
        } else if fs.isExecutable(path) {
            mode = "-rwxr-xr-x"
        } else {
            mode = "-rw-r--r--"
        }
        let size = info?.size ?? 0
        let sizeText = human ? Fmt.humanSize(size) : String(size)
        let date = Fmt.shortDate.string(from: info?.modified ?? Date())
        return "\(mode)  1 dsh  staff \(sizeText.leftPadded(6)) \(date) \(colored)"
    }

    private func colorize(name: String, path: String, isDir: Bool, fs: VirtualFS) -> String {
        if isDir { return Ansi.wrap("1;34", name) }
        if fs.isExecutable(path) { return Ansi.wrap("1;32", name) }
        if name.hasSuffix(".png") || name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") {
            return Ansi.wrap("1;35", name)
        }
        if name.hasSuffix(".md") || name.hasSuffix(".txt") {
            return Ansi.wrap("0;37", name)
        }
        return name
    }

    private func columns(names: [String], dir: String, fs: VirtualFS) -> String {
        let width = 42
        let longest = names.map { $0.count }.max() ?? 0
        let columnWidth = longest + 2
        let perLine = max(1, width / max(1, columnWidth))
        var lines: [String] = []
        var index = 0
        while index < names.count {
            var parts: [String] = []
            for offset in 0..<perLine {
                let position = index + offset
                guard position < names.count else { break }
                let entry = names[position]
                let full = fs.join(dir, entry)
                let colored = colorize(name: entry, path: full, isDir: fs.isDirectory(full), fs: fs)
                let isLast = offset == perLine - 1 || position == names.count - 1
                parts.append(isLast ? colored : colored + String(repeating: " ", count: max(1, columnWidth - entry.count)))
            }
            lines.append(parts.joined().trimmedRight())
            index += perLine
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - 导航

struct CdCommand: ShellCommand {
    let name = "cd"
    let summary = "切换目录"
    var usage: String { "cd [path|-]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let target = ctx.args.first ?? VirtualFS.home
        var path: String
        if target == "-" {
            path = ctx.shell.previousDirectory
        } else if target == "~" {
            path = VirtualFS.home
        } else {
            path = ctx.fs.resolve(target, cwd: ctx.cwd)
        }
        guard ctx.fs.isDirectory(path) else {
            return .err("cd: no such file or directory: \(target)\n")
        }
        ctx.shell.previousDirectory = ctx.cwd
        ctx.shell.cwd = path
        ctx.shell.setVar("PWD", path)
        ctx.shell.setVar("OLDPWD", ctx.shell.previousDirectory)
        return target == "-" ? .out(path + "\n") : .empty
    }
}

struct PwdCommand: ShellCommand {
    let name = "pwd"
    let summary = "显示当前目录"
    var usage: String { "pwd" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        .out(ctx.cwd + "\n")
    }
}

// MARK: - 读文件

struct CatCommand: ShellCommand {
    let name = "cat"
    let summary = "输出文件内容"
    var usage: String { "cat [file ...]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        if ctx.args.isEmpty { return .out(ctx.stdin) }
        var stdout = ""
        var stderr = ""
        var status: Int32 = 0
        for file in ctx.args {
            if file == "-" {
                stdout += ctx.stdin
                continue
            }
            let path = ctx.fs.resolve(file, cwd: ctx.cwd)
            do {
                stdout += try ctx.fs.read(path)
            } catch let error as ShellError {
                stderr += "cat: \(error.message)\n"
                status = 1
            } catch {
                stderr += "cat: \(error.localizedDescription)\n"
                status = 1
            }
        }
        return CommandResult(stdout: stdout, stderr: stderr, status: status)
    }
}

struct HeadCommand: ShellCommand {
    let name = "head"
    let summary = "看文件开头 N 行"
    var usage: String { "head [-n N] [file ...]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let (count, files, error) = LinesOptions.parse(ctx.args, defaultCount: 10)
        if let error = error { return .err("head: \(error)\n", status: 2) }
        let text = readAll(files: files, ctx: ctx)
        let lines = text.components(separatedBy: "\n")
        let result = lines.prefix(max(0, count)).joined(separator: "\n")
        return .out(result + (result.isEmpty ? "" : "\n"))
    }
}

struct TailCommand: ShellCommand {
    let name = "tail"
    let summary = "看文件末尾 N 行"
    var usage: String { "tail [-n N] [file ...]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let (count, files, error) = LinesOptions.parse(ctx.args, defaultCount: 10)
        if let error = error { return .err("tail: \(error)\n", status: 2) }
        var text = readAll(files: files, ctx: ctx)
        if text.hasSuffix("\n") { text.removeLast() }
        var lines = text.components(separatedBy: "\n")
        let take = max(0, count)
        if lines.count > take {
            lines = Array(lines.suffix(take))
        }
        let result = lines.joined(separator: "\n")
        return .out(result + (result.isEmpty ? "" : "\n"))
    }
}

enum LinesOptions {
    static func parse(_ args: [String], defaultCount: Int) -> (Int, [String], String?) {
        var count = defaultCount
        var files: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-n" {
                guard index + 1 < args.count, let value = Int(args[index + 1]) else {
                    return (count, files, "-n 需要一个数字")
                }
                count = value
                index += 2
                continue
            }
            if arg.hasPrefix("-n"), let value = Int(arg.dropFirst(2)) {
                count = value
                index += 1
                continue
            }
            if arg.hasPrefix("-"), arg.count > 1, Int(arg.dropFirst()) != nil {
                count = Int(arg.dropFirst()) ?? count
                index += 1
                continue
            }
            files.append(arg)
            index += 1
        }
        return (count, files, nil)
    }
}

func readAll(files: [String], ctx: CommandContext) -> String {
    if files.isEmpty { return ctx.stdin }
    var text = ""
    for file in files {
        let path = ctx.fs.resolve(file, cwd: ctx.cwd)
        if let content = try? ctx.fs.read(path) {
            text += content
        }
    }
    return text
}

struct WcCommand: ShellCommand {
    let name = "wc"
    let summary = "统计行数 / 词数 / 字节数"
    var usage: String { "wc [-l] [-w] [-c] [file ...]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "lwc")
        if let bad = parsed.unknown.first {
            return .err("wc: invalid option \(bad)\n", status: 2)
        }
        let flags = parsed.flags.isEmpty ? Set<Character>(["l", "w", "c"]) : parsed.flags
        let text = readAll(files: parsed.operands, ctx: ctx)
        let lineCount = text.isEmpty ? 0 : text.components(separatedBy: "\n").count - (text.hasSuffix("\n") ? 1 : 0)
        let wordCount = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        let byteCount = text.utf8.count
        var parts: [String] = []
        if flags.contains("l") { parts.append(String(lineCount).leftPadded(6)) }
        if flags.contains("w") { parts.append(String(wordCount).leftPadded(6)) }
        if flags.contains("c") { parts.append(String(byteCount).leftPadded(6)) }
        return .out(parts.joined(separator: " ") + "\n")
    }
}

// MARK: - 写文件

struct MkdirCommand: ShellCommand {
    let name = "mkdir"
    let summary = "创建目录"
    var usage: String { "mkdir [-p] path ..." }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "p")
        if let bad = parsed.unknown.first { return .err("mkdir: invalid option \(bad)\n", status: 2) }
        if parsed.operands.isEmpty { return .err("mkdir: missing operand\n", status: 2) }
        var stderr = ""
        var status: Int32 = 0
        for operand in parsed.operands {
            let path = ctx.fs.resolve(operand, cwd: ctx.cwd)
            do {
                try ctx.fs.mkdir(path, parents: parsed.has("p"))
            } catch let error as ShellError {
                stderr += "mkdir: \(error.message)\n"
                status = 1
            } catch {
                stderr += "mkdir: \(error.localizedDescription)\n"
                status = 1
            }
        }
        return CommandResult(stderr: stderr, status: status)
    }
}

struct TouchCommand: ShellCommand {
    let name = "touch"
    let summary = "创建空文件 / 更新时间"
    var usage: String { "touch path ..." }

    func run(_ ctx: CommandContext) async -> CommandResult {
        if ctx.args.isEmpty { return .err("touch: missing file operand\n", status: 2) }
        var stderr = ""
        var status: Int32 = 0
        for operand in ctx.args {
            do {
                try ctx.fs.touch(ctx.fs.resolve(operand, cwd: ctx.cwd))
            } catch let error as ShellError {
                stderr += "touch: \(error.message)\n"
                status = 1
            } catch {
                stderr += "touch: \(error.localizedDescription)\n"
                status = 1
            }
        }
        return CommandResult(stderr: stderr, status: status)
    }
}

struct RmCommand: ShellCommand {
    let name = "rm"
    let summary = "删除文件（-r 删目录）"
    var usage: String { "rm [-r] [-f] path ..." }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "rf")
        if let bad = parsed.unknown.first { return .err("rm: invalid option \(bad)\n", status: 2) }
        if parsed.operands.isEmpty { return .err("rm: missing operand\n", status: 2) }
        var stderr = ""
        var status: Int32 = 0
        for operand in parsed.operands {
            let path = ctx.fs.resolve(operand, cwd: ctx.cwd)
            if !ctx.fs.exists(path) {
                if !parsed.has("f") {
                    stderr += "rm: \(operand): No such file or directory\n"
                    status = 1
                }
                continue
            }
            do {
                try ctx.fs.remove(path, recursive: parsed.has("r"))
            } catch let error as ShellError {
                if !parsed.has("f") {
                    stderr += "rm: \(error.message)\n"
                    status = 1
                }
            } catch {
                stderr += "rm: \(error.localizedDescription)\n"
                status = 1
            }
        }
        return CommandResult(stderr: stderr, status: status)
    }
}

struct RmdirCommand: ShellCommand {
    let name = "rmdir"
    let summary = "删除空目录"
    var usage: String { "rmdir path ..." }

    func run(_ ctx: CommandContext) async -> CommandResult {
        var stderr = ""
        var status: Int32 = 0
        for operand in ctx.args {
            let path = ctx.fs.resolve(operand, cwd: ctx.cwd)
            if let contents = try? ctx.fs.contents(path), !contents.isEmpty {
                stderr += "rmdir: \(operand): Directory not empty\n"
                status = 1
                continue
            }
            do {
                try ctx.fs.remove(path, recursive: false)
            } catch let error as ShellError {
                stderr += "rmdir: \(error.message)\n"
                status = 1
            } catch {
                stderr += "rmdir: \(error.localizedDescription)\n"
                status = 1
            }
        }
        return CommandResult(stderr: stderr, status: status)
    }
}

struct CpCommand: ShellCommand {
    let name = "cp"
    let summary = "复制文件或目录"
    var usage: String { "cp [-r] source target" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "r")
        guard parsed.operands.count == 2 else {
            return .err("cp: source and target required\n", status: 2)
        }
        let source = ctx.fs.resolve(parsed.operands[0], cwd: ctx.cwd)
        let target = ctx.fs.resolve(parsed.operands[1], cwd: ctx.cwd)
        if ctx.fs.isDirectory(source) && !parsed.has("r") {
            return .err("cp: \(parsed.operands[0]) is a directory (use -r)\n")
        }
        do {
            try ctx.fs.copy(source, to: target)
            return .empty
        } catch let error as ShellError {
            return .err("cp: \(error.message)\n")
        } catch {
            return .err("cp: \(error.localizedDescription)\n")
        }
    }
}

struct MvCommand: ShellCommand {
    let name = "mv"
    let summary = "移动 / 重命名"
    var usage: String { "mv source target" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        guard ctx.args.count == 2 else { return .err("mv: source and target required\n", status: 2) }
        let source = ctx.fs.resolve(ctx.args[0], cwd: ctx.cwd)
        let target = ctx.fs.resolve(ctx.args[1], cwd: ctx.cwd)
        do {
            try ctx.fs.move(source, to: target)
            return .empty
        } catch let error as ShellError {
            return .err("mv: \(error.message)\n")
        } catch {
            return .err("mv: \(error.localizedDescription)\n")
        }
    }
}

// MARK: - 查找 / 信息

struct FindCommand: ShellCommand {
    let name = "find"
    let summary = "递归查找文件"
    var usage: String { "find [path] [-name pattern] [-type f|d] [-maxdepth N]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        var root = "."
        var namePattern: String?
        var type: String?
        var maxDepth = 8
        var index = 0
        let args = ctx.args
        if let first = args.first, !first.hasPrefix("-") {
            root = first
            index = 1
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-name":
                guard index + 1 < args.count else { return .err("find: -name needs a value\n", status: 2) }
                namePattern = args[index + 1]
                index += 2
            case "-type":
                guard index + 1 < args.count else { return .err("find: -type needs a value\n", status: 2) }
                type = args[index + 1]
                index += 2
            case "-maxdepth":
                guard index + 1 < args.count, let value = Int(args[index + 1]) else {
                    return .err("find: -maxdepth needs a number\n", status: 2)
                }
                maxDepth = value
                index += 2
            default:
                return .err("find: unknown option \(arg)\n", status: 2)
            }
        }

        let start = ctx.fs.resolve(root, cwd: ctx.cwd)
        guard ctx.fs.isDirectory(start) else { return .err("find: \(root): No such directory\n") }
        var matches: [String] = []
        FindCommand.walk(path: start, depth: 0, maxDepth: maxDepth, name: namePattern, type: type, fs: ctx.fs, out: &matches)
        let lines = matches.map { ctx.fs.relative($0, from: ctx.cwd) }
        return .out(lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
    }

    static func walk(path: String, depth: Int, maxDepth: Int, name: String?, type: String?, fs: VirtualFS, out: inout [String]) {
        guard depth <= maxDepth else { return }
        if depth > 0 {
            let info = fs.info(path)
            let isDir = info?.isDirectory ?? false
            let base = (path as NSString).lastPathComponent
            var ok = true
            if let name = name {
                ok = VirtualFS.wildcardMatch(name, base)
            }
            if ok, let type = type {
                ok = (type == "d" && isDir) || (type == "f" && !isDir)
            }
            if ok { out.append(path) }
        }
        guard fs.isDirectory(path) else { return }
        let names = (try? fs.contents(path)) ?? []
        for name in names where !name.hasPrefix(".") {
            walk(path: fs.join(path, name), depth: depth + 1, maxDepth: maxDepth, name: name, type: type, fs: fs, out: &out)
        }
    }
}

struct TreeCommand: ShellCommand {
    let name = "tree"
    let summary = "树状显示目录"
    var usage: String { "tree [-L depth] [path]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        var depth = 3
        var root = "."
        var index = 0
        let args = ctx.args
        while index < args.count {
            let arg = args[index]
            if arg == "-L", index + 1 < args.count, let value = Int(args[index + 1]) {
                depth = value
                index += 2
                continue
            }
            if !arg.hasPrefix("-") { root = arg }
            index += 1
        }
        let path = ctx.fs.resolve(root, cwd: ctx.cwd)
        guard ctx.fs.isDirectory(path) else { return .err("tree: \(root): Not a directory\n") }
        var out = "\(root)\n"
        var dirs = 0
        var files = 0
        TreeCommand.walk(path: path, prefix: "", depth: 1, maxDepth: depth, fs: ctx.fs, out: &out, dirs: &dirs, files: &files)
        out += "\n\(dirs) directories, \(files) files\n"
        return .out(out)
    }

    static func walk(path: String, prefix: String, depth: Int, maxDepth: Int, fs: VirtualFS, out: inout String, dirs: inout Int, files: inout Int) {
        guard depth <= maxDepth else { return }
        let names = ((try? fs.contents(path)) ?? []).filter { !$0.hasPrefix(".") }
        for (index, name) in names.enumerated() {
            let isLast = index == names.count - 1
            let full = fs.join(path, name)
            let isDir = fs.isDirectory(full)
            out += prefix + (isLast ? "└── " : "├── ") + (isDir ? Ansi.wrap("1;34", name) : name) + "\n"
            if isDir {
                dirs += 1
                walk(path: full, prefix: prefix + (isLast ? "    " : "│   "), depth: depth + 1, maxDepth: maxDepth, fs: fs, out: &out, dirs: &dirs, files: &files)
            } else {
                files += 1
            }
        }
    }
}

struct StatCommand: ShellCommand {
    let name = "stat"
    let summary = "看文件详情"
    var usage: String { "stat path ..." }

    func run(_ ctx: CommandContext) async -> CommandResult {
        guard !ctx.args.isEmpty else { return .err("stat: missing operand\n", status: 2) }
        var out = ""
        var status: Int32 = 0
        for operand in ctx.args {
            let path = ctx.fs.resolve(operand, cwd: ctx.cwd)
            guard let info = ctx.fs.info(path) else {
                out += "stat: \(operand): No such file or directory\n"
                status = 1
                continue
            }
            let type = info.isDirectory ? "directory" : "regular file"
            let mode = info.isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
            out += "  File: \(operand)\n"
            out += "  Size: \(info.size)    Type: \(type)\n"
            out += "  Modified: \(Fmt.longDate.string(from: info.modified))\n"
            out += "  Mode: \(mode)\n"
        }
        return CommandResult(stdout: out, status: status)
    }
}

struct FileCommand: ShellCommand {
    let name = "file"
    let summary = "猜文件类型"
    var usage: String { "file path ..." }

    func run(_ ctx: CommandContext) async -> CommandResult {
        var out = ""
        for operand in ctx.args {
            let path = ctx.fs.resolve(operand, cwd: ctx.cwd)
            guard let info = ctx.fs.info(path) else {
                out += "\(operand): cannot open\n"
                continue
            }
            if info.isDirectory {
                out += "\(operand): directory\n"
                continue
            }
            let ext = (operand as NSString).pathExtension.lowercased()
            let type: String
            switch ext {
            case "md": type = "Markdown text"
            case "txt", "log", "zshrc": type = "ASCII text"
            case "json": type = "JSON data"
            case "swift": type = "Swift source"
            case "py": type = "Python script"
            case "sh": type = "POSIX shell script"
            case "html", "htm": type = "HTML document"
            case "css": type = "CSS stylesheet"
            case "js": type = "JavaScript source"
            case "yml", "yaml": type = "YAML document"
            case "png": type = "PNG image"
            case "jpg", "jpeg": type = "JPEG image"
            case "zip": type = "Zip archive"
            case "ipa": type = "iOS app archive"
            default: type = "data"
            }
            out += "\(operand): \(type) (\(info.size) bytes)\n"
        }
        return .out(out)
    }
}

struct DuCommand: ShellCommand {
    let name = "du"
    let summary = "看目录占用空间"
    var usage: String { "du [-h] [path]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "h")
        let target = parsed.operands.first ?? "."
        let path = ctx.fs.resolve(target, cwd: ctx.cwd)
        guard ctx.fs.exists(path) else { return .err("du: \(target): No such file or directory\n") }
        let size = ctx.fs.diskUsage(path)
        let text = parsed.has("h") ? Fmt.humanSize(size) : String(size)
        return .out("\(text)\t\(target)\n")
    }
}

struct BasenameCommand: ShellCommand {
    let name = "basename"
    let summary = "取路径最后一段"
    var usage: String { "basename path" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        guard let first = ctx.args.first else { return .err("basename: missing operand\n", status: 2) }
        var name = (first as NSString).lastPathComponent
        if let suffix = ctx.args.dropFirst().first, name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return .out(name + "\n")
    }
}

struct DirnameCommand: ShellCommand {
    let name = "dirname"
    let summary = "取路径目录部分"
    var usage: String { "dirname path" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        guard let first = ctx.args.first else { return .err("dirname: missing operand\n", status: 2) }
        let dir = (first as NSString).deletingLastPathComponent
        return .out((dir.isEmpty ? "." : dir) + "\n")
    }
}

struct RealpathCommand: ShellCommand {
    let name = "realpath"
    let summary = "规范化路径"
    var usage: String { "realpath path" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        guard let first = ctx.args.first else { return .err("realpath: missing operand\n", status: 2) }
        return .out(ctx.fs.resolve(first, cwd: ctx.cwd) + "\n")
    }
}
