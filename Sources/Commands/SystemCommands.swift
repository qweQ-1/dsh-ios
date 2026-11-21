import Foundation

enum SystemInfo {
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "arm64" }
            return String(cString: base)
        }
    }

    static var powerState: String {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? "省电模式" : "正常"
    }

    static var disk: (free: String, total: String) {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        return (Fmt.humanSize(free), Fmt.humanSize(total))
    }
}

struct WhoamiCommand: ShellCommand {
    let name = "whoami"
    let summary = "当前用户"
    var usage: String { "whoami" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        .out((ctx.shell.vars["USER"] ?? "dsh") + "\n")
    }
}

struct HostnameCommand: ShellCommand {
    let name = "hostname"
    let summary = "主机名"
    var usage: String { "hostname" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        .out(ctx.shell.hostname + "\n")
    }
}

struct UnameCommand: ShellCommand {
    let name = "uname"
    let summary = "系统信息"
    var usage: String { "uname [-a] [-s] [-n] [-r] [-m]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let parsed = ctx.args.parseOptions(allowed: "asnrm")
        let all = parsed.has("a") || parsed.flags.isEmpty
        var parts: [String] = []
        if all || parsed.has("s") { parts.append("Darwin") }
        if all || parsed.has("n") { parts.append(ctx.shell.hostname) }
        if all || parsed.has("r") { parts.append("24.0.0") }
        if all || parsed.has("m") { parts.append(SystemInfo.machine) }
        if all { parts.append(SystemInfo.osVersion) }
        return .out(parts.joined(separator: " ") + "\n")
    }
}

struct DateCommand: ShellCommand {
    let name = "date"
    let summary = "当前时间（支持 +格式）"
    var usage: String { "date [+format]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let now = Date()
        if let pattern = ctx.args.first, pattern.hasPrefix("+") {
            return .out(DateCommand.format(String(pattern.dropFirst()), date: now) + "\n")
        }
        return .out(Fmt.unixDate.string(from: now) + "\n")
    }

    static func format(_ pattern: String, date: Date) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let monthNames = ["January", "February", "March", "April", "May", "June",
                          "July", "August", "September", "October", "November", "December"]
        let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let month = max(1, min(12, comps.month ?? 1))
        let weekday = max(0, min(6, (comps.weekday ?? 1) - 1))
        let zone = TimeZone.current
        let offset = zone.secondsFromGMT(for: date)
        let sign = offset >= 0 ? "+" : "-"
        let offsetHours = abs(offset) / 3600
        let offsetMinutes = (abs(offset) % 3600) / 60
        let offsetText = String(format: "%@%02d%02d", sign, offsetHours, offsetMinutes)

        var result = ""
        let chars = Array(pattern)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            guard c == "%", index + 1 < chars.count else {
                result.append(c)
                index += 1
                continue
            }
            let spec = chars[index + 1]
            switch spec {
            case "Y": result += String(comps.year ?? 1970)
            case "y": result += String(format: "%02d", (comps.year ?? 1970) % 100)
            case "m": result += String(format: "%02d", month)
            case "d": result += String(format: "%02d", comps.day ?? 1)
            case "e": result += String(format: "%2d", comps.day ?? 1)
            case "H": result += String(format: "%02d", comps.hour ?? 0)
            case "I":
                let hour = (comps.hour ?? 0) % 12
                result += String(format: "%02d", hour == 0 ? 12 : hour)
            case "M": result += String(format: "%02d", comps.minute ?? 0)
            case "S": result += String(format: "%02d", comps.second ?? 0)
            case "p": result += (comps.hour ?? 0) < 12 ? "AM" : "PM"
            case "A": result += weekdayNames[weekday]
            case "a": result += String(weekdayNames[weekday].prefix(3))
            case "B": result += monthNames[month - 1]
            case "b": result += String(monthNames[month - 1].prefix(3))
            case "j": result += String(format: "%03d", dayOfYear)
            case "Z": result += zone.abbreviation(for: date) ?? ""
            case "z": result += offsetText
            case "s": result += String(Int(date.timeIntervalSince1970))
            case "F": result += String(format: "%04d-%02d-%02d", comps.year ?? 1970, month, comps.day ?? 1)
            case "T": result += String(format: "%02d:%02d:%02d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
            case "%": result += "%"
            default: result += "%\(spec)"
            }
            index += 2
        }
        return result
    }
}

struct UptimeCommand: ShellCommand {
    let name = "uptime"
    let summary = "运行时长"
    var usage: String { "uptime" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let seconds = Int(Date().timeIntervalSince(ctx.shell.startedAt))
        let text: String
        if seconds < 60 {
            text = "\(seconds) secs"
        } else if seconds < 3600 {
            text = "\(seconds / 60) mins"
        } else {
            text = "\(seconds / 3600) hrs \(seconds % 3600 / 60) mins"
        }
        let time = DateCommand.format("%H:%M", date: Date())
        return .out("\(time)  up \(text), 1 user, load averages: 0.00 0.00 0.00\n")
    }
}

struct EnvCommand: ShellCommand {
    let name = "env"
    let summary = "列出环境变量"
    var usage: String { "env" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let lines = ctx.shell.vars.keys.sorted().map { "\($0)=\(ctx.shell.vars[$0] ?? "")" }
        return .out(lines.joined(separator: "\n") + "\n")
    }
}

struct ExportCommand: ShellCommand {
    let name = "export"
    let summary = "设置环境变量"
    var usage: String { "export KEY=VALUE ..." }

    func run(_ ctx: CommandContext) async -> CommandResult {
        if ctx.args.isEmpty {
            let lines = ctx.shell.vars.keys.sorted().map { "export \($0)=\(ctx.shell.vars[$0] ?? "")" }
            return .out(lines.joined(separator: "\n") + "\n")
        }
        var out = ""
        for arg in ctx.args {
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else {
                out += "export: invalid name\n"
                continue
            }
            let value = parts.count > 1 ? String(parts[1]) : (ctx.shell.vars[String(key)] ?? "")
            ctx.shell.setVar(String(key), value)
        }
        return out.isEmpty ? .empty : .err(out)
    }
}

struct UnsetCommand: ShellCommand {
    let name = "unset"
    let summary = "删除环境变量"
    var usage: String { "unset KEY ..." }

    func run(_ ctx: CommandContext) async -> CommandResult {
        for key in ctx.args {
            ctx.shell.vars.removeValue(forKey: key)
        }
        return .empty
    }
}

struct AliasCommand: ShellCommand {
    let name = "alias"
    let summary = "查看 / 设置别名"
    var usage: String { "alias [name=value ...]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        if ctx.args.isEmpty {
            let lines = ctx.shell.aliases.keys.sorted().map {
                "alias \($0)='\(ctx.shell.aliases[$0] ?? "")'"
            }
            return .out(lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
        }
        var out = ""
        for arg in ctx.args {
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else {
                out += "alias: expected name=value\n"
                continue
            }
            ctx.shell.aliases[String(parts[0])] = String(parts[1])
        }
        return out.isEmpty ? .empty : .err(out)
    }
}

struct UnaliasCommand: ShellCommand {
    let name = "unalias"
    let summary = "删除别名"
    var usage: String { "unalias name|-a" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        if ctx.args.first == "-a" {
            ctx.shell.aliases.removeAll()
            return .empty
        }
        for name in ctx.args {
            ctx.shell.aliases.removeValue(forKey: name)
        }
        return .empty
    }
}

struct HistoryCommand: ShellCommand {
    let name = "history"
    let summary = "命令历史"
    var usage: String { "history [-c]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        if ctx.args.first == "-c" {
            ctx.shell.clearHistory()
            return .empty
        }
        var out = ""
        for (index, line) in ctx.shell.history.enumerated() {
            out += String(index + 1).leftPadded(4) + "  " + line + "\n"
        }
        return .out(out)
    }
}

struct ClearCommand: ShellCommand {
    let name = "clear"
    let summary = "清屏"
    var usage: String { "clear" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        CommandResult(effect: .clear)
    }
}

struct HelpCommand: ShellCommand {
    let name = "help"
    let summary = "查看命令列表"
    var usage: String { "help [command]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        if let target = ctx.args.first {
            return ManCommand().render(target, shell: ctx.shell)
        }
        let groups: [(String, [String])] = [
            ("文件", ["ls", "cd", "pwd", "cat", "mkdir", "touch", "rm", "cp", "mv", "head", "tail", "wc", "find", "tree", "stat", "file", "du"]),
            ("文本", ["echo", "printf", "grep", "sort", "uniq", "rev", "cut", "base64", "sha256sum"]),
            ("系统", ["whoami", "hostname", "uname", "date", "uptime", "env", "export", "unset", "alias", "unalias", "history", "which", "type", "clear", "exit", "version", "neofetch"]),
            ("网络", ["curl"])
        ]
        var out = "dsh 1.0.0 — DeepSeek Harness 的沙盒 shell\n\n"
        for group in groups {
            let names = group.1.filter { ctx.shell.registry.command($0) != nil }
            guard !names.isEmpty else { continue }
            out += group.0 + "\n"
            for name in names {
                guard let command = ctx.shell.registry.command(name) else { continue }
                out += "  " + Fmt.padded(name, 12) + command.summary + "\n"
            }
            out += "\n"
        }
        out += "输入 `help <命令>` 或 `man <命令>` 查看用法。"
        return .out(out + "\n")
    }
}

struct ManCommand: ShellCommand {
    let name = "man"
    let summary = "查看命令用法"
    var usage: String { "man command" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        guard let target = ctx.args.first else {
            return .err("man: what manual page do you want?\n", status: 2)
        }
        return render(target, shell: ctx.shell)
    }

    func render(_ target: String, shell: Shell) -> CommandResult {
        guard let command = shell.registry.command(target) else {
            return .err("man: \(target): no such command\n", status: 2)
        }
        var out = "\(command.name)\n\n"
        out += "用法: \(command.usage)\n"
        if !command.summary.isEmpty {
            out += "说明: \(command.summary)\n"
        }
        return .out(out)
    }
}

struct WhichCommand: ShellCommand {
    let name = "which"
    let summary = "命令在哪"
    var usage: String { "which name ..." }

    func run(_ ctx: CommandContext) async -> CommandResult {
        var out = ""
        var status: Int32 = 0
        for name in ctx.args {
            if ctx.shell.registry.command(name) != nil {
                out += "/usr/bin/\(name)\n"
            } else {
                status = 1
            }
        }
        return CommandResult(stdout: out, status: status)
    }
}

struct TypeCommand: ShellCommand {
    let name = "type"
    let summary = "命令类型"
    var usage: String { "type name ..." }

    func run(_ ctx: CommandContext) async -> CommandResult {
        var out = ""
        var status: Int32 = 0
        for name in ctx.args {
            if let alias = ctx.shell.aliases[name] {
                out += "\(name) is an alias for '\(alias)'\n"
            } else if ctx.shell.registry.command(name) != nil {
                out += "\(name) is a shell builtin\n"
            } else {
                out += "type: \(name): not found\n"
                status = 1
            }
        }
        return CommandResult(stdout: out, status: status)
    }
}

struct ExitCommand: ShellCommand {
    let name = "exit"
    let summary = "退出 shell（重置当前会话的命令环境）"
    var usage: String { "exit [code]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let code = Int32(ctx.args.first ?? "0") ?? 0
        return CommandResult(status: code, effect: .exit(code))
    }
}

struct VersionCommand: ShellCommand {
    let name = "version"
    let summary = "版本信息"
    var usage: String { "version" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        .out("dsh 1.0.0 (iOS) — DeepSeek Harness\n沙盒 shell · \(SystemInfo.osVersion) · \(SystemInfo.machine)\n")
    }
}

struct NeofetchCommand: ShellCommand {
    let name = "neofetch"
    let summary = "设备信息"
    var usage: String { "neofetch" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        let logo = """
              .:odOo:.
            .dOOOOOOOOo
           oOOOOOOOOOOOo
           OOOOOOOOOOOO
           OOOOOOOOOOOOo
            'oOOOOOOOo'
              ':ooo:'
        """
        let disk = SystemInfo.disk
        let info = [
            "\(ctx.shell.vars["USER"] ?? "dsh")@\(ctx.shell.hostname)",
            "-----------------",
            "OS: \(SystemInfo.osVersion) \(SystemInfo.machine)",
            "Host: \(SystemInfo.machine)",
            "Shell: dsh 1.0.0",
            "Power: \(SystemInfo.powerState)",
            "Disk: \(disk.free) free / \(disk.total)",
            "CWD: \(ctx.cwd)"
        ]
        let logoLines = logo.components(separatedBy: "\n")
        let width = logoLines.map { $0.count }.max() ?? 0
        var out = ""
        let rows = max(logoLines.count, info.count)
        for index in 0..<rows {
            let left = index < logoLines.count ? logoLines[index] : ""
            let right = index < info.count ? info[index] : ""
            out += Fmt.padded(left, width + 2) + right + "\n"
        }
        return .out(out)
    }
}

struct SudoCommand: ShellCommand {
    let name = "sudo"
    let summary = "你已经是这台手机的主人了"
    var usage: String { "sudo [command]" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        .out("dsh: 这台手机已经是你的了，不需要 sudo。\n")
    }
}

struct TrueCommand: ShellCommand {
    let name = "true"
    let summary = "永远成功"
    var usage: String { "true" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        .empty
    }
}

struct FalseCommand: ShellCommand {
    let name = "false"
    let summary = "永远失败"
    var usage: String { "false" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        CommandResult(status: 1)
    }
}

// MARK: - curl

struct CurlCommand: ShellCommand {
    let name = "curl"
    let summary = "发 HTTP 请求"
    var usage: String { "curl [-I] [-i] [-s] [-o file] <url>" }

    func run(_ ctx: CommandContext) async -> CommandResult {
        var headOnly = false
        var includeHeaders = false
        var silent = false
        var outputFile: String?
        var urlString: String?
        var index = 0
        let args = ctx.args

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-I", "--head":
                headOnly = true
            case "-i":
                includeHeaders = true
            case "-s", "--silent":
                silent = true
            case "-L", "--location":
                break
            case "-o", "--output":
                guard index + 1 < args.count else {
                    return .err("curl: option \(arg) requires an argument\n", status: 2)
                }
                outputFile = args[index + 1]
                index += 1
            default:
                if arg.hasPrefix("-"), arg.count > 1 {
                    return .err("curl: unsupported option \(arg)\n", status: 2)
                }
                urlString = arg
            }
            index += 1
        }

        guard var target = urlString else {
            return .err("usage: curl [-I] [-i] [-s] [-o file] <url>\n", status: 2)
        }
        if !target.contains("://") { target = "https://" + target }
        guard let url = URL(string: target),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .err("curl: invalid URL\n", status: 3)
        }

        var request = URLRequest(url: url)
        request.httpMethod = headOnly ? "HEAD" : "GET"
        request.timeoutInterval = 30
        request.setValue("dsh-ios/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .err("curl: no response\n", status: 6)
            }
            var out = ""
            if includeHeaders || headOnly {
                out += "HTTP/1.1 \(http.statusCode)\n"
                let headers = http.allHeaderFields
                    .compactMap { key, value -> String? in
                        guard let key = key as? String else { return nil }
                        return "\(key): \(value)"
                    }
                    .sorted()
                out += headers.joined(separator: "\n") + "\n\n"
            }
            if headOnly { return .out(out) }
            if let file = outputFile {
                do {
                    try ctx.fs.writeData(data, to: ctx.fs.resolve(file, cwd: ctx.cwd))
                    return .out("Saved \(data.count) bytes to \(file)\n")
                } catch let error as ShellError {
                    return .err("curl: \(error.message)\n")
                }
            }
            let limit = 20000
            if let text = String(data: data.prefix(limit), encoding: .utf8) {
                out += text
                if data.count > limit {
                    out += "\n… (\(data.count) bytes total, truncated)\n"
                }
            } else {
                out += "(binary response, \(data.count) bytes)\n"
            }
            _ = silent
            return .out(out)
        } catch {
            return .err("curl: \(error.localizedDescription)\n", status: 6)
        }
    }
}
