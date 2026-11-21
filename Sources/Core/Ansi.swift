import Foundation

enum AnsiColor: Equatable {
    case basic(Int)   // 0-7
    case bright(Int)  // 0-7
    case fixed(Int)   // 256 色
}

struct AnsiStyle: Equatable {
    var foreground: AnsiColor?
    var background: AnsiColor?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
}

struct AnsiSpan: Equatable {
    var text: String
    var style: AnsiStyle
}

enum Ansi {
    static let reset = "\u{1B}[0m"

    static func wrap(_ code: String, _ text: String) -> String {
        "\u{1B}[\(code)m\(text)\(reset)"
    }
}

enum AnsiParser {
    static func parse(_ text: String) -> [AnsiSpan] {
        var spans: [AnsiSpan] = []
        var buffer = ""
        var style = AnsiStyle()
        let chars = Array(text)
        var i = 0

        func flush() {
            if !buffer.isEmpty {
                spans.append(AnsiSpan(text: buffer, style: style))
                buffer = ""
            }
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                flush()
                var j = i + 2
                var params = ""
                while j < chars.count, chars[j].isNumber || chars[j] == ";" {
                    params.append(chars[j])
                    j += 1
                }
                let command = j < chars.count ? chars[j] : "m"
                if command == "m" {
                    apply(params, to: &style)
                }
                i = min(j + 1, chars.count)
                continue
            }
            if c == "\r" {
                i += 1
                continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return spans
    }

    private static func apply(_ params: String, to style: inout AnsiStyle) {
        if params.isEmpty {
            style = AnsiStyle()
            return
        }
        let values = params.split(separator: ";", omittingEmptySubsequences: false).map {
            Int($0) ?? 0
        }
        var index = 0
        while index < values.count {
            let value = values[index]
            switch value {
            case 0:
                style = AnsiStyle()
            case 1:
                style.bold = true
            case 2:
                style.dim = true
            case 3:
                style.italic = true
            case 4:
                style.underline = true
            case 22:
                style.bold = false
                style.dim = false
            case 23:
                style.italic = false
            case 24:
                style.underline = false
            case 30...37:
                style.foreground = .basic(value - 30)
            case 39:
                style.foreground = nil
            case 40...47:
                style.background = .basic(value - 40)
            case 49:
                style.background = nil
            case 90...97:
                style.foreground = .bright(value - 90)
            case 100...107:
                style.background = .bright(value - 100)
            case 38, 48:
                let isForeground = value == 38
                if index + 1 < values.count, values[index + 1] == 5, index + 2 < values.count {
                    let color = AnsiColor.fixed(max(0, min(255, values[index + 2])))
                    if isForeground { style.foreground = color } else { style.background = color }
                    index += 2
                } else if index + 1 < values.count, values[index + 1] == 2, index + 4 < values.count {
                    let r = max(0, min(255, values[index + 2]))
                    let g = max(0, min(255, values[index + 3]))
                    let b = max(0, min(255, values[index + 4]))
                    let approx = 16 + 36 * (r * 5 / 255) + 6 * (g * 5 / 255) + (b * 5 / 255)
                    let color = AnsiColor.fixed(approx)
                    if isForeground { style.foreground = color } else { style.background = color }
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }
}

/// 去掉 ANSI 之后的可见文本（复制、测宽用）。
enum AnsiStripper {
    static func strip(_ text: String) -> String {
        AnsiParser.parse(text).map { $0.text }.joined()
    }
}
