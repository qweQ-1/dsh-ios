import XCTest
@testable import Dsh

final class ToolTests: XCTestCase {
    var root: URL!
    var fs: VirtualFS!
    var shell: Shell!
    var executor: SandboxToolExecutor!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fs = VirtualFS(root: root)
        try fs.bootstrap()
        shell = Shell(fs: fs)
        executor = SandboxToolExecutor(fs: fs, shell: shell)
    }

    override func tearDownWithError() throws {
        if let root = root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testWriteReadAndEdit() async throws {
        let write = await executor.execute(ToolCall(
            name: "write_file",
            arguments: #"{"path":"notes/hello.md","content":"hello world"}"#
        ))
        XCTAssertFalse(write.isError, write.output)

        let read = await executor.execute(ToolCall(
            name: "read_file",
            arguments: #"{"path":"notes/hello.md"}"#
        ))
        XCTAssertTrue(read.output.contains("1\thello world"))

        let edit = await executor.execute(ToolCall(
            name: "edit_file",
            arguments: #"{"path":"notes/hello.md","old_string":"world","new_string":"dsh"}"#
        ))
        XCTAssertFalse(edit.isError, edit.output)
        XCTAssertEqual(try fs.read("/home/dsh/notes/hello.md"), "hello dsh")
    }

    func testEditRequiresUniqueMatch() async throws {
        _ = await executor.execute(ToolCall(
            name: "write_file",
            arguments: #"{"path":"dup.txt","content":"a b a"}"#
        ))
        let ambiguous = await executor.execute(ToolCall(
            name: "edit_file",
            arguments: #"{"path":"dup.txt","old_string":"a","new_string":"c"}"#
        ))
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.output.contains("2"))

        let replaceAll = await executor.execute(ToolCall(
            name: "edit_file",
            arguments: #"{"path":"dup.txt","old_string":"a","new_string":"c","replace_all":true}"#
        ))
        XCTAssertFalse(replaceAll.isError)
        XCTAssertEqual(try fs.read("/home/dsh/dup.txt"), "c b c")
    }

    func testRunShell() async {
        let result = await executor.execute(ToolCall(
            name: "run_shell",
            arguments: #"{"command":"echo hi && pwd"}"#
        ))
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("hi"))
        XCTAssertTrue(result.output.contains("/home/dsh"))
        XCTAssertTrue(result.output.contains("[exit 0]"))
    }

    func testPlanModeBlocksShell() async {
        executor.planMode = true
        let result = await executor.execute(ToolCall(
            name: "run_shell",
            arguments: #"{"command":"echo should-not-run"}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Plan mode"))
    }

    func testListDirTree() async {
        _ = await executor.execute(ToolCall(
            name: "write_file",
            arguments: #"{"path":"projects/app/main.swift","content":"print(1)"}"#
        ))
        let listing = await executor.execute(ToolCall(
            name: "list_dir",
            arguments: #"{"path":"projects","depth":3}"#
        ))
        XCTAssertFalse(listing.isError)
        XCTAssertTrue(listing.output.contains("app/"))
        XCTAssertTrue(listing.output.contains("main.swift"))
    }

    func testPlanModeToolListOmitsMutatingTools() {
        let readOnly = Set(ToolCatalog.definitions(planMode: true).map { $0.name })
        XCTAssertTrue(readOnly.contains("read_file"))
        XCTAssertTrue(readOnly.contains("list_dir"))
        XCTAssertFalse(readOnly.contains("write_file"))
        XCTAssertFalse(readOnly.contains("run_shell"))
        XCTAssertEqual(ToolCatalog.risk(of: "write_file"), .mutating)
        XCTAssertEqual(ToolCatalog.risk(of: "read_file"), .readOnly)
    }

    func testHTMLStrip() {
        let html = "<html><body><h1>Hello</h1><script>alert(1)</script><p>World &amp; friends</p></body></html>"
        let text = SandboxToolExecutor.stripHTML(html)
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("World & friends"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("<h1>"))
    }
}

// MARK: - SSE

final class StreamTests: XCTestCase {
    func testAccumulatorContentAndUsage() throws {
        var accumulator = StreamAccumulator()
        let json = #"{"choices":[{"delta":{"content":"你好"}}]}"#
        _ = accumulator.consume(try decode(json))
        let finish = #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}"#
        _ = accumulator.consume(try decode(finish))
        let final = accumulator.final
        XCTAssertEqual(final.content, "你好")
        XCTAssertEqual(final.finishReason, "stop")
        XCTAssertEqual(final.usage?.totalTokens, 12)
        XCTAssertEqual(final.usage?.cacheHitTokens, 0)
    }

    func testAccumulatorToolCallsAcrossChunks() throws {
        var accumulator = StreamAccumulator()
        let first = #"{"choices":[{"delta":{"reasoning_content":"想一下","tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"path\":"}}]}}]}"#
        let second = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"README.md\"}"}}]},"finish_reason":"tool_calls"}]}"#
        _ = accumulator.consume(try decode(first))
        _ = accumulator.consume(try decode(second))
        let final = accumulator.final
        XCTAssertEqual(final.reasoning, "想一下")
        XCTAssertEqual(final.toolCalls.count, 1)
        XCTAssertEqual(final.toolCalls[0].id, "call_1")
        XCTAssertEqual(final.toolCalls[0].name, "read_file")
        XCTAssertEqual(final.toolCalls[0].arguments, #"{"path":"README.md"}"#)
        XCTAssertEqual(final.finishReason, "tool_calls")
    }

    func testRequestEncoding() throws {
        let messages = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "call_9", name: "ls", arguments: "{}")]),
            ChatMessage(role: .tool, content: "file.txt", toolCallID: "call_9")
        ]
        let encoded = ChatRequestEncoder.apiMessages(messages)
        XCTAssertEqual(encoded.count, 4)
        XCTAssertEqual(encoded[0]["role"] as? String, "system")
        let calls = encoded[2]["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(calls?.count, 1)
        XCTAssertEqual(encoded[3]["tool_call_id"] as? String, "call_9")
    }

    func testMakeRequestURLAndHeaders() throws {
        let client = DeepSeekClient(transport: ScriptedTransport(scripts: []))
        let request = try client.makeRequest(apiKey: "sk-test",
                                             baseURL: "https://api.deepseek.com",
                                             messages: [ChatMessage(role: .user, content: "hi")],
                                             model: "deepseek-chat",
                                             temperature: 0.2,
                                             maxTokens: 100,
                                             tools: ToolCatalog.definitions(planMode: false))
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "deepseek-chat")
        XCTAssertEqual((body?["tools"] as? [[String: Any]])?.count, 7)
        XCTAssertEqual((body?["stream"] as? Bool), true)
    }

    private func decode(_ json: String) throws -> ChatChunk {
        try JSONDecoder().decode(ChatChunk.self, from: Data(json.utf8))
    }
}
