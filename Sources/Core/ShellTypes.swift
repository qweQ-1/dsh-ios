import Foundation

/// 命令执行后需要交给 UI 层的副作用（清屏、退出、打开链接、换主题）。
enum ShellEffect: Equatable {
    case none
    case clear
    case exit(Int32)
    case open(URL)
    case theme(String)

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

/// 单条命令的返回值。stdout / stderr 都是纯文本，可以包含 ANSI 颜色。
struct CommandResult: Equatable {
    var stdout: String
    var stderr: String
    var status: Int32
    var effect: ShellEffect

    init(stdout: String = "", stderr: String = "", status: Int32 = 0, effect: ShellEffect = .none) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.effect = effect
    }

    static func out(_ text: String = "") -> CommandResult {
        CommandResult(stdout: text)
    }

    static func err(_ text: String, status: Int32 = 1) -> CommandResult {
        CommandResult(stderr: text, status: status)
    }

    static var empty: CommandResult { CommandResult() }
}

/// 命令内部抛出的错误，Shell 会把它转成 stderr + 退出码。
struct ShellError: Error, Equatable {
    let message: String
    let status: Int32

    init(_ message: String, status: Int32 = 1) {
        self.message = message
        self.status = status
    }
}

/// 传给每条命令的上下文。
final class CommandContext {
    let shell: Shell
    let argv: [String]
    let stdin: String

    init(shell: Shell, argv: [String], stdin: String = "") {
        self.shell = shell
        self.argv = argv
        self.stdin = stdin
    }

    var name: String { argv.first ?? "" }

    /// 不含命令名的参数。
    var args: [String] { Array(argv.dropFirst()) }

    var fs: VirtualFS { shell.fs }
    var cwd: String { shell.cwd }
}

protocol ShellCommand {
    var name: String { get }
    var summary: String { get }
    var usage: String { get }
    func run(_ ctx: CommandContext) async -> CommandResult
}

extension ShellCommand {
    var summary: String { "" }
    var usage: String { name }
}

/// 解析出来的选项：`ls -la /tmp` → flags [l, a]，operands ["/tmp"]。
struct ParsedArgs {
    var flags: Set<Character> = []
    var operands: [String] = []
    var unknown: [String] = []

    func has(_ flag: Character) -> Bool { flags.contains(flag) }
}

extension Array where Element == String {
    /// 只认短选项，支持 `-la` 合并写法；`--` 之后全是操作数。
    func parseOptions(allowed: String) -> ParsedArgs {
        var result = ParsedArgs()
        var stopped = false
        for arg in self {
            if stopped {
                result.operands.append(arg)
                continue
            }
            if arg == "--" {
                stopped = true
                continue
            }
            if arg.count > 1 && arg.hasPrefix("-") && !arg.hasPrefix("--") {
                for ch in arg.dropFirst() {
                    if allowed.contains(ch) {
                        result.flags.insert(ch)
                    } else {
                        result.unknown.append("-\(ch)")
                    }
                }
                continue
            }
            result.operands.append(arg)
        }
        return result
    }
}
