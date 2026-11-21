import XCTest
@testable import Dsh

final class ChatHistorySanitizerTests: XCTestCase {
    func testValidHistoryUnchanged() {
        let messages = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(id: "a", name: "read_file", arguments: "{}"),
                ToolCall(id: "b", name: "list_dir", arguments: "{}")
            ]),
            ChatMessage(role: .tool, content: "one", toolCallID: "a"),
            ChatMessage(role: .tool, content: "two", toolCallID: "b"),
            ChatMessage(role: .assistant, content: "done")
        ]
        let fixed = ChatHistorySanitizer.sanitize(messages)
        XCTAssertEqual(fixed, messages)
    }

    func testFillsMissingToolResults() {
        let messages = [
            ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(id: "a", name: "read_file", arguments: "{}"),
                ToolCall(id: "b", name: "write_file", arguments: "{}")
            ]),
            ChatMessage(role: .tool, content: "one", toolCallID: "a"),
            ChatMessage(role: .assistant, content: "（已停止）")
        ]
        let fixed = ChatHistorySanitizer.sanitize(messages)
        XCTAssertEqual(fixed.count, 4)
        XCTAssertEqual(fixed[1].toolCallID, "a")
        XCTAssertEqual(fixed[2].toolCallID, "b")
        XCTAssertTrue(fixed[2].content.contains("没有返回结果"))
        XCTAssertEqual(fixed[3].role, .assistant)
    }

    func testDropsOrphanAndDuplicateToolMessages() {
        let messages = [
            ChatMessage(role: .tool, content: "orphan", toolCallID: "nope"),
            ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(id: "a", name: "read_file", arguments: "{}")
            ]),
            ChatMessage(role: .tool, content: "first", toolCallID: "a"),
            ChatMessage(role: .tool, content: "second", toolCallID: "a")
        ]
        let fixed = ChatHistorySanitizer.sanitize(messages)
        XCTAssertEqual(fixed.count, 2)
        XCTAssertEqual(fixed[0].role, .assistant)
        XCTAssertEqual(fixed[1].content, "first")
    }

    func testEmptyToolContentIsReplaced() {
        let messages = [
            ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(id: "a", name: "run_shell", arguments: "{}")
            ]),
            ChatMessage(role: .tool, content: "", toolCallID: "a")
        ]
        let fixed = ChatHistorySanitizer.sanitize(messages)
        XCTAssertEqual(fixed.count, 2)
        XCTAssertTrue(fixed[1].content.contains("没有返回结果"))
        XCTAssertTrue(fixed[1].isError)
    }

    func testSanitizedHistoryCanBeEncodedForAPI() {
        let messages = [
            ChatMessage(role: .user, content: "go"),
            ChatMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(id: "a", name: "read_file", arguments: "{}"),
                ToolCall(id: "b", name: "read_file", arguments: "{}")
            ]),
            ChatMessage(role: .tool, content: "one", toolCallID: "a")
        ]
        let encoded = ChatRequestEncoder.apiMessages(ChatHistorySanitizer.sanitize(messages))
        let toolIDs = encoded.compactMap { $0["tool_call_id"] as? String }
        XCTAssertEqual(toolIDs, ["a", "b"])
    }
}
