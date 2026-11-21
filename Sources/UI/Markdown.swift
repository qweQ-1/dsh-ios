import SwiftUI
import UIKit

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(marker: String, text: String)
    case quote(String)
    case code(language: String?, content: String)
    case divider
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: codeLanguage, content: codeLines.joined(separator: "\n")))
                    codeLines = []
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    var language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if language.isEmpty { language = "" }
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }

            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }

            if trimmed.hasPrefix("#") {
                var level = 0
                for character in trimmed {
                    if character == "#" { level += 1 } else { break }
                }
                if level >= 1 && level <= 6 {
                    let rest = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty {
                        flushParagraph()
                        blocks.append(.heading(level: level, text: rest))
                        continue
                    }
                }
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                var text = String(trimmed.dropFirst())
                if text.hasPrefix(" ") { text.removeFirst() }
                blocks.append(.quote(text))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }

            if let numbered = numberedLine(trimmed) {
                flushParagraph()
                blocks.append(.numbered(marker: numbered.marker, text: numbered.text))
                continue
            }

            paragraph.append(line)
        }

        if inCode {
            blocks.append(.code(language: codeLanguage, content: codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func numberedLine(_ line: String) -> (marker: String, text: String)? {
        let parts = line.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let digits = parts[0]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }
        var rest = String(parts[1])
        guard rest.hasPrefix(" ") else { return nil }
        rest.removeFirst()
        return ("\(digits).", rest)
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundColor(DshTheme.text)
                .padding(.top, level <= 2 ? 4 : 0)

        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 15))
                .foregroundColor(DshTheme.text)
                .lineSpacing(3)
                .textSelection(.enabled)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 7) {
                Text("•")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DshTheme.textSecondary)
                Text(inline(text))
                    .font(.system(size: 15))
                    .foregroundColor(DshTheme.text)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }

        case .numbered(let marker, let text):
            HStack(alignment: .top, spacing: 7) {
                Text(marker)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(DshTheme.textSecondary)
                    .padding(.top, 2)
                Text(inline(text))
                    .font(.system(size: 15))
                    .foregroundColor(DshTheme.text)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                Rectangle()
                    .fill(DshTheme.accent.opacity(0.6))
                    .frame(width: 2)
                Text(inline(text))
                    .font(.system(size: 14))
                    .foregroundColor(DshTheme.textSecondary)
                    .italic()
            }

        case .code(let language, let content):
            CodeBlockView(language: language, code: content)

        case .divider:
            HairlineDivider().padding(.vertical, 3)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 18
        case 3: return 16.5
        default: return 15.5
        }
    }

    private func inline(_ text: String) -> AttributedString {
        var result: AttributedString
        do {
            result = try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                               failurePolicy: .returnPartiallyParsedIfPossible)
            )
        } catch {
            return AttributedString(text)
        }
        var codeRanges: [Range<AttributedString.Index>] = []
        var strongRanges: [Range<AttributedString.Index>] = []
        for run in result.runs {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { codeRanges.append(run.range) }
                if intent.contains(.stronglyEmphasized) { strongRanges.append(run.range) }
            }
        }
        for range in codeRanges {
            result[range].font = .system(size: 13.5, design: .monospaced)
            result[range].backgroundColor = DshTheme.codeBackground
        }
        for range in strongRanges {
            result[range].font = .system(size: 15, weight: .semibold)
        }
        return result
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(DshTheme.textTertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制")
                    }
                    .font(.system(size: 10.5))
                    .foregroundColor(copied ? DshTheme.green : DshTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HairlineDivider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(DshTheme.text)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .background(DshTheme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DshTheme.border, lineWidth: 1)
        )
    }
}
