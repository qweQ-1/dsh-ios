import Foundation

enum DshError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidURL
    case server(status: Int, message: String)
    case network(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "还没有配置 DeepSeek API Key。打开设置填入 sk-… 后再试。"
        case .invalidURL:
            return "API 地址不合法。"
        case .server(let status, let message):
            return "DeepSeek 返回 HTTP \(status)：\(message.isEmpty ? "无响应体" : message)"
        case .network(let message):
            return "网络错误：\(message)"
        case .cancelled:
            return "已取消。"
        }
    }
}

// MARK: - SSE 数据块

struct ToolCallDelta: Decodable {
    struct Function: Decodable {
        let name: String?
        let arguments: String?
    }

    let index: Int?
    let id: String?
    let function: Function?
}

struct ChatChunk: Decodable {
    struct Delta: Decodable {
        let content: String?
        let reasoningContent: String?
        let toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }

    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]?
    let usage: TokenUsage?
}

// MARK: - 流式结果

struct LLMFinal {
    var content: String
    var reasoning: String
    var toolCalls: [ToolCall]
    var finishReason: String?
    var usage: TokenUsage?
}

enum LLMEvent {
    case content(String)
    case reasoning(String)
    case finished(LLMFinal)
}

/// 把一串 SSE chunk 累积成最终结果；纯逻辑，方便单测。
struct StreamAccumulator {
    struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private(set) var content = ""
    private(set) var reasoning = ""
    private(set) var finishReason: String?
    private(set) var usage: TokenUsage?
    private var calls: [Int: PartialCall] = [:]

    mutating func consume(_ chunk: ChatChunk) -> [LLMEvent] {
        var events: [LLMEvent] = []
        if let usage = chunk.usage {
            self.usage = usage
        }
        for choice in chunk.choices ?? [] {
            if let delta = choice.delta {
                if let text = delta.content, !text.isEmpty {
                    content += text
                    events.append(.content(text))
                }
                if let thought = delta.reasoningContent, !thought.isEmpty {
                    reasoning += thought
                    events.append(.reasoning(thought))
                }
                for callDelta in delta.toolCalls ?? [] {
                    let index = callDelta.index ?? 0
                    var partial = calls[index] ?? PartialCall()
                    if let id = callDelta.id, !id.isEmpty { partial.id = id }
                    if let name = callDelta.function?.name, !name.isEmpty { partial.name = name }
                    if let arguments = callDelta.function?.arguments {
                        partial.arguments += arguments
                    }
                    calls[index] = partial
                }
            }
            if let reason = choice.finishReason {
                finishReason = reason
            }
        }
        return events
    }

    var final: LLMFinal {
        let ordered = calls.keys.sorted().compactMap { index -> ToolCall? in
            guard let partial = calls[index], !partial.name.isEmpty else { return nil }
            let id = partial.id.isEmpty ? "call_\(index)" : partial.id
            let arguments = partial.arguments.isEmpty ? "{}" : partial.arguments
            return ToolCall(id: id, name: partial.name, arguments: arguments)
        }
        return LLMFinal(content: content,
                        reasoning: reasoning,
                        toolCalls: ordered,
                        finishReason: finishReason,
                        usage: usage)
    }
}

// MARK: - 请求编码

enum ChatRequestEncoder {
    static func apiMessages(_ messages: [ChatMessage]) -> [[String: Any]] {
        messages.map { message in
            switch message.role {
            case .system, .user:
                return ["role": message.role.rawValue, "content": message.content]
            case .assistant:
                var dict: [String: Any] = [
                    "role": "assistant",
                    "content": message.content
                ]
                if let calls = message.toolCalls, !calls.isEmpty {
                    dict["tool_calls"] = calls.map { call -> [String: Any] in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": call.arguments
                            ]
                        ]
                    }
                }
                return dict
            case .tool:
                return [
                    "role": "tool",
                    "tool_call_id": message.toolCallID ?? "",
                    "content": message.content
                ]
            }
        }
    }
}

// MARK: - 传输层

protocol HTTPStreaming {
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error>
}

struct URLSessionStreaming: HTTPStreaming {
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw DshError.network("没有收到 HTTP 响应")
                    }
                    if !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line + "\n"
                            if body.count > 4000 { break }
                        }
                        throw DshError.server(status: http.statusCode, message: body)
                    }
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: DshError.cancelled)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: DshError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - 客户端

final class DeepSeekClient {
    private let transport: HTTPStreaming
    private let session: URLSession

    init(transport: HTTPStreaming = URLSessionStreaming()) {
        self.transport = transport
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration)
    }

    func makeRequest(apiKey: String,
                     baseURL: String,
                     messages: [ChatMessage],
                     model: String,
                     temperature: Double,
                     maxTokens: Int,
                     tools: [ToolDefinition]) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DshError.missingAPIKey }

        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard var url = URL(string: base) else { throw DshError.invalidURL }
        if !url.path.hasSuffix("/chat/completions") {
            url = url.appendingPathComponent("chat").appendingPathComponent("completions")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": ChatRequestEncoder.apiMessages(messages),
            "stream": true,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream_options": ["include_usage": true]
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.jsonObject }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("dsh-ios/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func stream(apiKey: String,
                baseURL: String,
                messages: [ChatMessage],
                model: String,
                temperature: Double,
                maxTokens: Int,
                tools: [ToolDefinition]) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.makeRequest(apiKey: apiKey,
                                                       baseURL: baseURL,
                                                       messages: messages,
                                                       model: model,
                                                       temperature: temperature,
                                                       maxTokens: maxTokens,
                                                       tools: tools)
                    var accumulator = StreamAccumulator()
                    for try await line in self.transport.lines(for: request) {
                        if Task.isCancelled { throw DshError.cancelled }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        var payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }
                        if payload.hasPrefix(":") { continue }
                        payload = payload.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}"))
                        guard let data = payload.data(using: .utf8) else { continue }
                        guard let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data) else {
                            continue
                        }
                        for event in accumulator.consume(chunk) {
                            continuation.yield(event)
                        }
                    }
                    continuation.yield(.finished(accumulator.final))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: DshError.cancelled)
                } catch let error as DshError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: DshError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 设置页的「测试连接」：GET /models。
    func listModels(apiKey: String, baseURL: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DshError.missingAPIKey }
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard var url = URL(string: base) else { throw DshError.invalidURL }
        if !url.path.hasSuffix("/models") {
            url = url.appendingPathComponent("models")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DshError.network("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw DshError.server(status: http.statusCode, message: text)
        }
        struct ModelsResponse: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { $0.id }
    }
}
