import CryptoKit
import Foundation

// MARK: - echo / printf

struct EchoCommand: ShellCommand {
    let name = "echo"
    let summary = "输出文本（-n 不换行，-e 解释转义）"
    var usage: String { "echo [-n] [-e] [text ...]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        var newline = true
        var interpret = false
        var args = ctx.args
        var index = 0
        while index < args.count {
            let arg = args[index]
            guard arg.hasPrefix("-"), arg.count > 1, !arg.hasPrefix("--") else { break }
            let flags = arg.dropFirst()
            guard flags.allSatisfy({ $0 == "n" || $0 == "e" || $0 == "E" }) else { break }
            if flags.contains("n") { newline = false }
            if flags.contains("e") { interpret = true }
            if flags.contains("E") { interpret = false }
            index += 1
        }
        args = Array(args.dropFirst(index))
        var text = args.joined(separator: " ")
        if interpret {
            text = ShellEscapes.unescape(text)
        }
        return .out(text + (newline ? "\n" : ""))
    }
}

enum ShellEscapes {
    static func unescape(_ text: String) -> String {
        var result = ""
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            guard c == "\\", index + 1 < chars.count else {
                result.append(c)
                index += 1
                continue
            }
            let next = chars[index + 1]
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "e", "E": result.append("\u{1B}")
            case "\\": result.append("\\")
            case "0": result.append("\0")
            default: result.append(next)
            }
            index += 2
        }
        return result
    }
}

struct PrintfCommand: ShellCommand {
    let name = "printf"
    let summary = "按格式输出"
    var usage: String { "printf format [args ...]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        guard let format = ctx.args.first else { return .err("printf: missing format\n", status: 2) }
        let values = Array(ctx.args.dropFirst())
        var out = ""
        var valueIndex = 0
        let chars = Array(format)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\\", index + 1 < chars.count {
                out += ShellEscapes.unescape("\\" + String(chars[index + 1]))
                index += 2
                continue
            }
            if c == "%", index + 1 < chars.count {
                let spec = chars[index + 1]
                if spec == "%" {
                    out += "%"
                    index += 2
                    continue
                }
                if spec == "s" || spec == "d" {
                    let value = valueIndex < values.count ? values[valueIndex] : ""
                    valueIndex += 1
                    if spec == "s" {
                        out += value
                    } else {
                        out += String(Int(value) ?? 0)
                    }
                    index += 2
                    continue
                }
            }
            out.append(c)
            index += 1
        }
        if valueIndex < values.count {
            out += values[valueIndex...].joined(separator: " ")
        }
        return .out(out)
    }
}

// MARK: - grep

struct GrepCommand: ShellCommand {
    let name = "grep"
    let summary = "按文本筛选行"
    var usage: String { "grep [-i] [-n] [-v] [-c] pattern [file ...]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "invcl")
        if let bad = parsed.unknown.first { return .err("grep: invalid option \(bad)\n", status: 2) }
        guard let pattern = parsed.operands.first else {
            return .err("usage: grep [-invc] pattern [file ...]\n", status: 2)
        }
        let files = Array(parsed.operands.dropFirst())
        let ignoreCase = parsed.has("i")
        let showNumbers = parsed.has("n")
        let invert = parsed.has("v")
        let countOnly = parsed.has("c")

        var sources: [(name: String, text: String)] = []
        if files.isEmpty {
            sources.append(("", ctx.stdin))
        } else {
            for file in files {
                let path = ctx.fs.resolve(file, cwd: ctx.cwd)
                if let text = try? ctx.fs.read(path) {
                    sources.append((file, text))
                } else {
                    return .err("grep: \(file): No such file\n", status: 2)
                }
            }
        }

        var out = ""
        var matched = false
        for source in sources {
            var lines = source.text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            var count = 0
            var local = ""
            for (lineIndex, line) in lines.enumerated() {
                let hit: Bool
                if ignoreCase {
                    hit = line.range(of: pattern, options: .caseInsensitive) != nil
                } else {
                    hit = line.contains(pattern)
                }
                let include = invert ? !hit : hit
                if include {
                    count += 1
                    matched = true
                    var prefix = ""
                    if files.count > 1 { prefix += source.name + ":" }
                    if showNumbers { prefix += "\(lineIndex + 1):" }
                    local += prefix + line + "\n"
                }
            }
            if countOnly {
                var prefix = ""
                if files.count > 1 { prefix = source.name + ":" }
                out += prefix + String(count) + "\n"
            } else {
                out += local
            }
        }
        return CommandResult(stdout: out, status: matched ? 0 : 1)
    }
}

// MARK: - 文本处理

struct SortCommand: ShellCommand {
    let name = "sort"
    let summary = "排序行"
    var usage: String { "sort [-r] [-n] [-u] [file]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "rnu")
        if let bad = parsed.unknown.first { return .err("sort: invalid option \(bad)\n", status: 2) }
        var text = readAll(files: parsed.operands, ctx: ctx)
        if text.hasSuffix("\n") { text.removeLast() }
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if parsed.has("n") {
            lines.sort { (Double($0) ?? 0) < (Double($1) ?? 0) }
        } else {
            lines.sort()
        }
        if parsed.has("r") { lines.reverse() }
        if parsed.has("u") {
            var unique: [String] = []
            for line in lines where unique.last != line {
                unique.append(line)
            }
            lines = unique
        }
        return .out(lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
    }
}

struct UniqCommand: ShellCommand {
    let name = "uniq"
    let summary = "去掉相邻重复行"
    var usage: String { "uniq [-c] [file]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "c")
        if let bad = parsed.unknown.first { return .err("uniq: invalid option \(bad)\n", status: 2) }
        var text = readAll(files: parsed.operands, ctx: ctx)
        if text.hasSuffix("\n") { text.removeLast() }
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        var out = ""
        var index = 0
        while index < lines.count {
            var count = 1
            while index + count < lines.count && lines[index + count] == lines[index] {
                count += 1
            }
            if parsed.has("c") {
                out += String(count).leftPadded(4) + " " + lines[index] + "\n"
            } else {
                out += lines[index] + "\n"
            }
            index += count
        }
        return .out(out)
    }
}

struct RevCommand: ShellCommand {
    let name = "rev"
    let summary = "反转每一行"
    var usage: String { "rev [file]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let text = readAll(files: ctx.args, ctx: ctx)
        let lines = text.components(separatedBy: "\n").map { String($0.reversed()) }
        return .out(lines.joined(separator: "\n"))
    }
}

struct CutCommand: ShellCommand {
    let name = "cut"
    let summary = "按分隔符取字段"
    var usage: String { "cut -d <delimiter> -f <n> [file]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        var delimiter: Character = "\t"
        var field = 1
        var files: [String] = []
        var index = 0
        let args = ctx.args
        while index < args.count {
            let arg = args[index]
            if arg == "-d", index + 1 < args.count {
                delimiter = args[index + 1].first ?? "\t"
                index += 2
                continue
            }
            if arg == "-f", index + 1 < args.count, let value = Int(args[index + 1]) {
                field = max(1, value)
                index += 2
                continue
            }
            files.append(arg)
            index += 1
        }
        let text = readAll(files: files, ctx: ctx)
        var out = ""
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.split(separator: delimiter, omittingEmptySubsequences: false)
            if parts.count >= field {
                out += String(parts[field - 1]) + "\n"
            } else {
                out += "\n"
            }
        }
        return .out(out)
    }
}

struct Base64Command: ShellCommand {
    let name = "base64"
    let summary = "base64 编解码（-d 解码）"
    var usage: String { "base64 [-d] [file]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "d")
        if let bad = parsed.unknown.first { return .err("base64: invalid option \(bad)\n", status: 2) }
        let text = readAll(files: parsed.operands, ctx: ctx)
        if parsed.has("d") {
            let cleaned = text.replacingOccurrences(of: "\n", with: "")
            guard let data = Data(base64Encoded: cleaned),
                  let decoded = String(data: data, encoding: .utf8) else {
                return .err("base64: invalid input\n")
            }
            return .out(decoded)
        }
        let data = Data(text.utf8)
        return .out(data.base64EncodedString() + "\n")
    }
}

struct Sha256Command: ShellCommand {
    let name = "sha256sum"
    let summary = "算 SHA-256"
    var usage: String { "sha256sum [file ...]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        if ctx.args.isEmpty {
            let digest = SHA256.hash(data: Data(ctx.stdin.utf8))
            return .out(digest.map { String(format: "%02x", $0) }.joined() + "  -\n")
        }
        var out = ""
        for file in ctx.args {
            let path = ctx.fs.resolve(file, cwd: ctx.cwd)
            guard let data = try? ctx.fs.readData(path) else {
                return .err("sha256sum: \(file): No such file\n")
            }
            let digest = SHA256.hash(data: data)
            out += digest.map { String(format: "%02x", $0) }.joined() + "  " + file + "\n"
        }
        return .out(out)
    }
}
