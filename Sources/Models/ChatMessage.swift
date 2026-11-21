import Foundation

/// 一次工具调用（OpenAI / DeepSeek 兼容格式）。
struct ToolCall: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var arguments: String

    init(id: String = UUID().uuidString, name: String, arguments: String = "{}") {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// 对话里的一条消息。assistant 消息可以带 toolCalls，tool 消息用 toolCallID 对上。
struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
        case tool
    }

    var id: UUID
    var role: Role
    var content: String
    var reasoning: String?
    var toolCalls: [ToolCall]?
    var toolCallID: String?
    var createdAt: Date
    var isError: Bool

    init(id: UUID = UUID(),
         role: Role,
         content: String = "",
         reasoning: String? = nil,
         toolCalls: [ToolCall]? = nil,
         toolCallID: String? = nil,
         createdAt: Date = Date(),
         isError: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.createdAt = createdAt
        self.isError = isError
    }
}

struct TokenUsage: Codable, Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0
    var cacheHitTokens: Int = 0
    var cacheMissTokens: Int = 0

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cacheHitTokens = "prompt_cache_hit_tokens"
        case cacheMissTokens = "prompt_cache_miss_tokens"
    }

    var summary: String {
        "\(totalTokens) tokens · 输入 \(promptTokens) / 输出 \(completionTokens)"
    }
}

extension TokenUsage {
    // DeepSeek 的 usage 里缓存字段可能缺失，缺了就按 0 处理。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        cacheHitTokens = try container.decodeIfPresent(Int.self, forKey: .cacheHitTokens) ?? 0
        cacheMissTokens = try container.decodeIfPresent(Int.self, forKey: .cacheMissTokens) ?? 0
    }
}

struct ToolResult: Equatable {
    var output: String
    var isError: Bool

    static func ok(_ text: String) -> ToolResult { ToolResult(output: text, isError: false) }
    static func fail(_ text: String) -> ToolResult { ToolResult(output: text, isError: true) }
}

/// 会话。整个对象会被序列化成 JSON 存到 Application Support/Sessions。
struct ChatSession: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var model: String
    var planMode: Bool
    var messages: [ChatMessage]

    init(id: UUID = UUID(),
         title: String = "新会话",
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         model: String,
         planMode: Bool = false,
         messages: [ChatMessage] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.planMode = planMode
        self.messages = messages
    }

    var isUntitled: Bool { title.isEmpty || title == "新会话" }

    mutating func autoTitleIfNeeded() {
        guard isUntitled else { return }
        guard let first = messages.first(where: { $0.role == .user }) else { return }
        let text = first.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        title = text.count > 36 ? String(text.prefix(36)) + "…" : text
    }
}
