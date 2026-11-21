import Foundation

/// 变量 / 波浪号 / 通配符展开。
struct Expander {
    unowned let shell: Shell

    func expand(_ words: [String]) -> [String] {
        var result: [String] = []
        for word in words {
            var text = expandVariables(word)
            if text == "~" {
                text = VirtualFS.home
            } else if text.hasPrefix("~/") {
                text = VirtualFS.home + String(text.dropFirst(1))
            }

            if text.contains("*") || text.contains("?") {
                let matches = shell.fs.glob(text, cwd: shell.cwd)
                if !matches.isEmpty {
                    result.append(contentsOf: matches)
                    continue
                }
            }
            result.append(text)
        }
        return result
    }

    func expandVariables(_ input: String) -> String {
        var result = ""
        let chars = Array(input)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            guard c == "$" else {
                result.append(c)
                i += 1
                continue
            }
            guard i + 1 < chars.count else {
                result.append("$")
                i += 1
                continue
            }

            let next = chars[i + 1]
            if next == "{" {
                var j = i + 2
                var name = ""
                while j < chars.count && chars[j] != "}" {
                    name.append(chars[j])
                    j += 1
                }
                result += shell.value(for: name)
                i = min(j + 1, chars.count)
                continue
            }
            if next == "?" {
                result += String(shell.lastStatus)
                i += 2
                continue
            }
            if next == "$" {
                result += String(ProcessInfo.processInfo.processIdentifier)
                i += 2
                continue
            }
            if next == "(" {
                result.append("$")
                i += 1
                continue
            }
            if next.isLetter || next == "_" {
                var j = i + 1
                var name = ""
                while j < chars.count,
                      chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    name.append(chars[j])
                    j += 1
                }
                result += shell.value(for: name)
                i = j
                continue
            }
            result.append("$")
            i += 1
        }
        return result
    }
}
