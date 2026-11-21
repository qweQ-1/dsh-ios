import Foundation

struct Redirect: Equatable {
    var path: String
    var append: Bool
}

struct SimpleCommand: Equatable {
    var words: [String]
    var outRedirect: Redirect?
    var errRedirect: Redirect?
    var inFile: String?

    init(words: [String] = [],
         outRedirect: Redirect? = nil,
         errRedirect: Redirect? = nil,
         inFile: String? = nil) {
        self.words = words
        self.outRedirect = outRedirect
        self.errRedirect = errRedirect
        self.inFile = inFile
    }
}

struct Pipeline: Equatable {
    var commands: [SimpleCommand]
}

enum ChainOperator: String, Equatable {
    case seq = ";"
    case and = "&&"
    case or = "||"
}

struct ChainItem: Equatable {
    var pipeline: Pipeline
    var opToNext: ChainOperator?
}

enum Parser {
    static func parse(_ tokens: [ShellToken]) throws -> [ChainItem] {
        var items: [ChainItem] = []
        var commands: [SimpleCommand] = []
        var current = SimpleCommand()
        var i = 0

        func finishCommand() throws {
            guard !current.words.isEmpty else {
                throw ShellError("parse error: empty command")
            }
            commands.append(current)
            current = SimpleCommand()
        }

        func finishPipeline(_ op: ChainOperator?) throws {
            try finishCommand()
            items.append(ChainItem(pipeline: Pipeline(commands: commands), opToNext: op))
            commands = []
        }

        while i < tokens.count {
            switch tokens[i] {
            case .word(let word):
                current.words.append(word)

            case .op(let op):
                switch op {
                case "|":
                    try finishCommand()

                case ";", "&":
                    try finishPipeline(.seq)

                case "&&":
                    try finishPipeline(.and)

                case "||":
                    try finishPipeline(.or)

                case ">", ">>":
                    guard i + 1 < tokens.count, case .word(let target) = tokens[i + 1] else {
                        throw ShellError("parse error: missing redirect target")
                    }
                    current.outRedirect = Redirect(path: target, append: op == ">>")
                    i += 1

                case "2>":
                    guard i + 1 < tokens.count, case .word(let target) = tokens[i + 1] else {
                        throw ShellError("parse error: missing redirect target")
                    }
                    current.errRedirect = Redirect(path: target, append: false)
                    i += 1

                case "<":
                    guard i + 1 < tokens.count, case .word(let target) = tokens[i + 1] else {
                        throw ShellError("parse error: missing input file")
                    }
                    current.inFile = target
                    i += 1

                default:
                    throw ShellError("parse error near '\(op)'")
                }
            }
            i += 1
        }

        if !current.words.isEmpty {
            try finishPipeline(nil)
        } else if !commands.isEmpty {
            throw ShellError("parse error: trailing operator")
        }
        return items
    }
}
