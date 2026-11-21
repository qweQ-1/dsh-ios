import Foundation

/// 分词结果：word 可能是空串（`echo ""`），operator 是 `|` `&&` `>` 之类。
enum ShellToken: Equatable {
    case word(String)
    case op(String)

    var isWord: Bool {
        if case .word = self { return true }
        return false
    }
}

enum Tokenizer {
    static func tokenize(_ line: String) throws -> [ShellToken] {
        var tokens: [ShellToken] = []
        let chars = Array(line)
        var i = 0

        func isOperator(_ c: Character) -> Bool {
            c == "|" || c == "&" || c == ";" || c == "<" || c == ">"
        }

        while i < chars.count {
            let c = chars[i]

            if c == " " || c == "\t" {
                i += 1
                continue
            }
            if c == "#" {
                break
            }
            if c == "2", i + 1 < chars.count, chars[i + 1] == ">" {
                tokens.append(.op("2>"))
                i += 2
                continue
            }
            if isOperator(c) {
                let two = i + 1 < chars.count ? String([c, chars[i + 1]]) : ""
                if two == "&&" || two == "||" || two == ">>" {
                    tokens.append(.op(two))
                    i += 2
                } else {
                    tokens.append(.op(String(c)))
                    i += 1
                }
                continue
            }

            var word = ""
            var hasContent = false
            while i < chars.count {
                let ch = chars[i]
                if ch == " " || ch == "\t" || isOperator(ch) { break }
                if ch == "2", word.isEmpty, i + 1 < chars.count, chars[i + 1] == ">" { break }

                if ch == "'" {
                    i += 1
                    var closed = false
                    while i < chars.count {
                        if chars[i] == "'" {
                            i += 1
                            closed = true
                            break
                        }
                        word.append(chars[i])
                        i += 1
                    }
                    if !closed { throw ShellError("unterminated quote") }
                    hasContent = true
                    continue
                }

                if ch == "\"" {
                    i += 1
                    var closed = false
                    while i < chars.count {
                        let d = chars[i]
                        if d == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                            word.append(chars[i + 1])
                            i += 2
                            continue
                        }
                        if d == "\"" {
                            i += 1
                            closed = true
                            break
                        }
                        word.append(d)
                        i += 1
                    }
                    if !closed { throw ShellError("unterminated quote") }
                    hasContent = true
                    continue
                }

                if ch == "\\" {
                    if i + 1 < chars.count {
                        word.append(chars[i + 1])
                        i += 2
                    } else {
                        i += 1
                    }
                    hasContent = true
                    continue
                }

                word.append(ch)
                i += 1
                hasContent = true
            }

            if hasContent {
                tokens.append(.word(word))
            }
        }
        return tokens
    }
}
