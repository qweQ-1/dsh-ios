import XCTest
@testable import Dsh

final class ScriptedTransport: HTTPStreaming {
    private let scripts: [[String]]
    private(set) var requestCount = 0

    init(scripts: [[String]]) {
        self.scripts = scripts
    }

    func lines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        let index = requestCount
        requestCount += 1
        let script = index < scripts.count ? scripts[index] : []
        return AsyncThrowingStream { continuation in
            for line in script {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }
}

final class AgentEngineTests: XCTestCase {
    var root: URL!
    var fs: VirtualFS!
    var shell: Shell!
    var executor: SandboxToolExecutor!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-agent-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    func testEngineExecutesToolAndFinishes() async throws {
        let transport = ScriptedTransport(scripts: [Self.toolScript, Self.finalScript])
        let engine = AgentEngine(client: DeepSeekClient(transport: transport), executor: executor)
        var toolFinished = 0
        var committed = 0

        let messages = await engine.run(
            history: [ChatMessage(role: .user, content: "读一下 README")],
            apiKey: "sk-test",
            baseURL: "https://api.deepseek.com",
            systemPrompt: "test system",
            model: "deepseek-chat",
            temperature: 0.2,
            maxTokens: 256,
            maxSteps: 4,
            planMode: false,
            requireApproval: true,
            approval: { _ in true },
            emit: { update in
                switch update {
                case .toolFinished:
                    toolFinished += 1
                case .assistantCommitted:
                    committed += 1
                default:
                    break
                }
            }
        )

        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(toolFinished, 1)
        XCTAssertEqual(committed, 2)
        XCTAssertTrue(messages.contains { $0.role == .tool && $0.content.contains("welcome to dsh") })
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertTrue(messages.last?.content.contains("done") ?? false)
    }

    @MainActor
    func testDeniedApprovalBecomesToolMessage() async {
        let transport = ScriptedTransport(scripts: [Self.writeScript, Self.finalScript])
        let engine = AgentEngine(client: DeepSeekClient(transport: transport), executor: executor)

        let messages = await engine.run(
            history: [ChatMessage(role: .user, content: "写个文件")],
            apiKey: "sk-test",
            baseURL: "https://api.deepseek.com",
            systemPrompt: "test",
            model: "deepseek-chat",
            temperature: 0.2,
            maxTokens: 256,
            maxSteps: 4,
            planMode: false,
            requireApproval: true,
            approval: { _ in false },
            emit: { _ in }
        )

        XCTAssertTrue(messages.contains { $0.role == .tool && $0.content.contains("用户拒绝") })
        XCTAssertFalse(fs.exists("/home/dsh/denied.txt"))
    }

    @MainActor
    func testPlanModeBlocksWrites() async {
        let transport = ScriptedTransport(scripts: [Self.writeScript, Self.finalScript])
        let engine = AgentEngine(client: DeepSeekClient(transport: transport), executor: executor)

        let messages = await engine.run(
            history: [ChatMessage(role: .user, content: "写个文件")],
            apiKey: "sk-test",
            baseURL: "https://api.deepseek.com",
            systemPrompt: "test",
            model: "deepseek-chat",
            temperature: 0.2,
            maxTokens: 256,
            maxSteps: 4,
            planMode: true,
            requireApproval: false,
            approval: { _ in true },
            emit: { _ in }
        )

        XCTAssertTrue(messages.contains { $0.role == .tool && $0.content.contains("Plan mode") })
        XCTAssertFalse(fs.exists("/home/dsh/denied.txt"))
    }

    // MARK: 脚本

    static let toolScript: [String] = [
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"path\":\"README.md\"}"}}]}}]}"#,
        #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        "data: [DONE]"
    ]

    static let writeScript: [String] = [
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_2","function":{"name":"write_file","arguments":"{\"path\":\"denied.txt\",\"content\":\"nope\"}"}}]}}]}"#,
        #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        "data: [DONE]"
    ]

    static let finalScript: [String] = [
        #"data: {"choices":[{"delta":{"content":"done"}}]}"#,
        #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}"#,
        "data: [DONE]"
    ]
}

final class SessionStoreTests: XCTestCase {
    func testSaveLoadDeleteAndTitle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        var session = store.create(model: "deepseek-chat", planMode: false)
        session.messages.append(ChatMessage(role: .user, content: "帮我看一下这个仓库的目录结构"))
        session.autoTitleIfNeeded()
        store.save(session)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "帮我看一下这个仓库的目录结构")
        XCTAssertEqual(loaded.first?.messages.count, 1)

        store.delete(session.id)
        XCTAssertTrue(store.loadAll().isEmpty)
    }
}

final class SettingsTests: XCTestCase {
    @MainActor
    func testPersistsValuesAndPrompt() {
        let name = "dsh.settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            return XCTFail("cannot create defaults")
        }
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.model = "deepseek-reasoner"
        store.temperature = 0.3
        store.requireApproval = false
        store.personaID = "concise"

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.model, "deepseek-reasoner")
        XCTAssertEqual(reloaded.temperature, 0.3, accuracy: 0.0001)
        XCTAssertFalse(reloaded.requireApproval)
        XCTAssertEqual(reloaded.personaID, "concise")
        XCTAssertTrue(reloaded.systemPrompt(planMode: true).contains("PLAN MODE"))
    }
}

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let source = """
        # 标题

        普通 **文本**

        - 第一项
        1. 编号

        ```swift
        let a = 1
        ```

        > 引用
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertTrue(blocks.contains(.heading(level: 1, text: "标题")))
        XCTAssertTrue(blocks.contains(.paragraph("普通 **文本**")))
        XCTAssertTrue(blocks.contains(.bullet("第一项")))
        XCTAssertTrue(blocks.contains(.numbered(marker: "1.", text: "编号")))
        XCTAssertTrue(blocks.contains(.code(language: "swift", content: "let a = 1")))
        XCTAssertTrue(blocks.contains(.quote("引用")))
    }

    func testUnclosedCodeFenceStillRenders() {
        let blocks = MarkdownParser.parse("```\nhello\nworld")
        XCTAssertEqual(blocks, [.code(language: nil, content: "hello\nworld")])
    }
}
