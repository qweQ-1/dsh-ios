import Foundation

/// 把会话历史修成 DeepSeek 能接受的样子。
///
/// 规则：assistant 带了 tool_calls，就必须紧跟每个 call 对应的 tool 消息。
/// App 被中断（停止、切会话、进程被杀）时会出现“只执行了一半”的历史，
/// 直接发出去会 400：`An assistant message with 'tool_calls' must be followed by
/// tool messages responding to each 'tool_call_id'`。
enum ChatHistorySanitizer {
    static let missingResult = "（这次工具调用没有返回结果：上一轮可能被中断了。需要的话请重新执行。）"

    static func sanitize(_ messages: [ChatMessage]) -> [ChatMessage] {
        var output: [ChatMessage] = []
        var pending: [ToolCall] = []
        var answered = Set<String>()

        func flushPending() {
            for call in pending where !answered.contains(call.id) {
                var message = ChatMessage(role: .tool, content: missingResult, toolCallID: call.id)
                message.isError = true
                output.append(message)
            }
            pending = []
            answered = []
        }

        for message in messages {
            switch message.role {
            case .assistant:
                flushPending()
                output.append(message)
                pending = message.toolCalls ?? []
                answered = []

            case .tool:
                guard let id = message.toolCallID,
                      pending.contains(where: { $0.id == id }),
                      !answered.contains(id) else {
                    // 孤立的 tool 消息、重复的 tool 消息都会让 API 报错，直接丢掉。
                    continue
                }
                var copy = message
                if copy.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    copy.content = missingResult
                    copy.isError = true
                }
                output.append(copy)
                answered.insert(id)

            case .user, .system:
                flushPending()
                output.append(message)
            }
        }
        flushPending()
        return output
    }
}
