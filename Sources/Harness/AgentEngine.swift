import Foundation

enum AgentUpdate {
    case content(String)
    case reasoning(String)
    case assistantCommitted(ChatMessage)
    case toolStarted(ToolCall)
    case toolFinished(ToolCall, ToolResult)
    case usage(TokenUsage)
    case notice(String)
    case failed(String)
}

/// dsh 的智能体循环：流式回答 → 有工具调用就执行 → 把结果喂回去 → 直到没有工具调用。
@MainActor
final class AgentEngine {
    private let client: DeepSeekClient
    let executor: SandboxToolExecutor

    init(client: DeepSeekClient, executor: SandboxToolExecutor) {
        self.client = client
        self.executor = executor
    }

    func run(history: [ChatMessage],
             apiKey: String,
             baseURL: String,
             systemPrompt: String,
             model: String,
             temperature: Double,
             maxTokens: Int,
             maxSteps: Int,
             planMode: Bool,
             requireApproval: Bool,
             approval: @escaping (ToolCall) async -> Bool,
             emit: @escaping (AgentUpdate) -> Void) async -> [ChatMessage] {

        // 进来先修一次：旧版本可能在中断时留下“有 tool_calls 但没有 tool 消息”的历史。
        // UI 上的 ⚠️ 报错气泡也不再回传给模型。
        let cleanHistory = history.filter { !($0.role == .assistant && $0.isError) }
        var messages = ChatHistorySanitizer.sanitize(cleanHistory)
        let tools = ToolCatalog.definitions(planMode: planMode)
        executor.planMode = planMode
        let system = ChatMessage(role: .system, content: systemPrompt)

        for _ in 0..<max(1, maxSteps) {
            if Task.isCancelled {
                emit(.notice("已停止。"))
                return messages
            }

            var partialContent = ""
            var partialReasoning = ""
            var outcome: LLMFinal?
            var failure: Error?

            let stream = client.stream(apiKey: apiKey,
                                       baseURL: baseURL,
                                       messages: [system] + messages,
                                       model: model,
                                       temperature: temperature,
                                       maxTokens: maxTokens,
                                       tools: tools)
            do {
                for try await event in stream {
                    switch event {
                    case .content(let text):
                        partialContent += text
                        emit(.content(text))
                    case .reasoning(let text):
                        partialReasoning += text
                        emit(.reasoning(text))
                    case .finished(let final):
                        outcome = final
                    }
                }
            } catch {
                failure = error
            }

            if let failure = failure {
                let cancelled: Bool
                if failure is CancellationError {
                    cancelled = true
                } else if let dsh = failure as? DshError, dsh == .cancelled {
                    cancelled = true
                } else {
                    cancelled = false
                }

                if cancelled {
                    if !partialContent.isEmpty {
                        let message = ChatMessage(role: .assistant, content: partialContent)
                        messages.append(message)
                        emit(.assistantCommitted(message))
                    }
                    emit(.notice("已停止。"))
                    return messages
                }

                let message = ChatMessage(role: .assistant,
                                          content: "⚠️ \(failure.localizedDescription)",
                                          isError: true)
                messages.append(message)
                emit(.assistantCommitted(message))
                emit(.failed(failure.localizedDescription))
                return messages
            }

            guard let final = outcome else {
                let message = ChatMessage(role: .assistant, content: "⚠️ 没有收到模型返回。", isError: true)
                messages.append(message)
                emit(.assistantCommitted(message))
                return messages
            }

            if let usage = final.usage {
                emit(.usage(usage))
            }

            let assistant = ChatMessage(
                role: .assistant,
                content: final.content,
                reasoning: final.reasoning.isEmpty ? nil : final.reasoning,
                toolCalls: final.toolCalls.isEmpty ? nil : final.toolCalls
            )
            messages.append(assistant)
            emit(.assistantCommitted(assistant))

            if final.toolCalls.isEmpty {
                return messages
            }

            for (offset, call) in final.toolCalls.enumerated() {
                if Task.isCancelled {
                    // 已经提交了 assistant(tool_calls)，剩下每个 call 都必须补一条 tool 消息，
                    // 否则这一轮历史永远发不出去（DeepSeek 会 400）。
                    for remaining in final.toolCalls[offset...] {
                        let missing = ToolResult.fail(ChatHistorySanitizer.missingResult)
                        messages.append(ChatMessage(role: .tool,
                                                    content: missing.output,
                                                    toolCallID: remaining.id))
                        emit(.toolFinished(remaining, missing))
                    }
                    emit(.notice("已停止。"))
                    return messages
                }

                emit(.toolStarted(call))
                let result: ToolResult
                if planMode && ToolCatalog.risk(of: call.name) == .mutating {
                    result = .fail("Plan mode 已开启：\(call.name) 被禁用。先检查，然后给出计划。")
                } else if requireApproval && ToolCatalog.risk(of: call.name) == .mutating {
                    let approved = await approval(call)
                    if approved {
                        result = await executor.execute(call)
                    } else {
                        result = .fail("用户拒绝了这个操作。不要重试，先问用户想怎么做。")
                    }
                } else {
                    result = await executor.execute(call)
                }

                let toolMessage = ChatMessage(role: .tool,
                                              content: result.output,
                                              toolCallID: call.id)
                messages.append(toolMessage)
                emit(.toolFinished(call, result))
            }
        }

        let note = ChatMessage(role: .assistant,
                               content: "（已达到 \(maxSteps) 步工具调用上限。回复「继续」我就接着做。）")
        messages.append(note)
        emit(.assistantCommitted(note))
        return messages
    }
}
