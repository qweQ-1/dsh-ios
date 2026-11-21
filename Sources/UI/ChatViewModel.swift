import Foundation

enum ToolPresentation {
    static func summary(_ call: ToolCall) -> String {
        let args = SandboxToolExecutor.parseArguments(call.arguments) ?? [:]
        switch call.name {
        case "read_file", "write_file", "edit_file", "list_dir":
            return (args["path"] as? String) ?? "."
        case "run_shell":
            let command = (args["command"] as? String) ?? ""
            return command.count > 80 ? String(command.prefix(80)) + "…" : command
        case "web_fetch":
            return (args["url"] as? String) ?? ""
        case "todo_write":
            let todos = (args["todos"] as? [[String: Any]])?.count ?? 0
            return "\(todos) 项"
        default:
            return String(call.arguments.prefix(60))
        }
    }

    static func icon(_ name: String) -> String {
        switch name {
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        case "edit_file": return "pencil.line"
        case "list_dir": return "folder"
        case "run_shell": return "terminal"
        case "web_fetch": return "globe"
        case "todo_write": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }

    static func title(_ name: String) -> String {
        switch name {
        case "read_file": return "读取文件"
        case "write_file": return "写入文件"
        case "edit_file": return "修改文件"
        case "list_dir": return "列目录"
        case "run_shell": return "执行命令"
        case "web_fetch": return "抓取网页"
        case "todo_write": return "更新待办"
        default: return name
        }
    }
}

struct LiveTool: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    var result: ToolResult?
    var startedAt: Date

    init(call: ToolCall) {
        id = call.id
        name = call.name
        summary = ToolPresentation.summary(call)
        result = nil
        startedAt = Date()
    }
}

enum DisplayItem: Identifiable {
    case user(ChatMessage)
    case assistant(ChatMessage)
    case tool(call: ToolCall, result: ToolResult?, running: Bool)
    case error(ChatMessage)

    var id: String {
        switch self {
        case .user(let message), .assistant(let message), .error(let message):
            return message.id.uuidString
        case .tool(let call, _, _):
            return "tool-\(call.id)"
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var session: ChatSession {
        didSet { refreshPromptState() }
    }
    @Published private(set) var sessions: [ChatSession]
    @Published var input: String = ""
    @Published private(set) var isRunning = false
    @Published private(set) var streamingText = ""
    @Published private(set) var streamingReasoning = ""
    @Published private(set) var lastUsage: TokenUsage?
    @Published var pendingApproval: ToolCall?
    @Published var notice: String?
    @Published var errorBanner: String?
    @Published var showSettings = false
    @Published private(set) var scrollSignal = 0

    let settings: SettingsStore
    let fs: VirtualFS
    let shell: Shell
    private let store: SessionStore
    private let engine: AgentEngine
    private var runTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var lastScrollBump = Date(timeIntervalSince1970: 0)

    init(settings: SettingsStore) {
        self.settings = settings
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let fsRoot = support.appendingPathComponent("DshRoot", isDirectory: true)
        let sessionsRoot = support.appendingPathComponent("Sessions", isDirectory: true)

        let fs = VirtualFS(root: fsRoot)
        try? fs.bootstrap()
        let shell = Shell(fs: fs)
        let executor = SandboxToolExecutor(fs: fs, shell: shell)
        let engine = AgentEngine(client: DeepSeekClient(), executor: executor)
        let store = SessionStore(root: sessionsRoot)

        let existing = store.loadAll()
        let session = existing.first ?? store.create(model: settings.model, planMode: settings.planModeDefault)

        self.fs = fs
        self.shell = shell
        self.engine = engine
        self.store = store
        self.session = session
        self.sessions = existing.isEmpty ? [session] : existing
    }

    // MARK: - 展示

    func displayItems() -> [DisplayItem] {
        var toolMessages: [String: ChatMessage] = [:]
        for message in session.messages where message.role == .tool {
            if let id = message.toolCallID {
                toolMessages[id] = message
            }
        }

        var items: [DisplayItem] = []
        for message in session.messages {
            switch message.role {
            case .user:
                items.append(.user(message))
            case .assistant:
                if message.isError {
                    items.append(.error(message))
                } else if message.content.isEmpty && (message.toolCalls?.isEmpty ?? true) {
                    continue
                } else {
                    items.append(.assistant(message))
                }
                for call in message.toolCalls ?? [] {
                    if let toolMessage = toolMessages[call.id] {
                        let finished = !toolMessage.content.isEmpty
                        let result = finished
                            ? ToolResult(output: toolMessage.content, isError: toolMessage.isError)
                            : nil
                        items.append(.tool(call: call, result: result, running: !finished && isRunning))
                    } else {
                        items.append(.tool(call: call, result: nil, running: isRunning))
                    }
                }
            case .tool, .system:
                continue
            }
        }
        return items
    }

    var workspacePath: String { fs.root.path }

    var filesCount: Int {
        countFiles("/home/dsh")
    }

    private func countFiles(_ path: String) -> Int {
        guard let names = try? fs.contents(path) else { return 0 }
        var total = 0
        for name in names where !name.hasPrefix(".") {
            let child = fs.join(path, name)
            if fs.isDirectory(child) {
                total += countFiles(child)
            } else {
                total += 1
            }
            if total > 999 { return total }
        }
        return total
    }

    // MARK: - 发送

    var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard settings.isConfigured else {
            errorBanner = "还没有配置 DeepSeek API Key。"
            showSettings = true
            return
        }
        input = ""
        errorBanner = nil
        notice = nil
        session.messages.append(ChatMessage(role: .user, content: text))
        session.autoTitleIfNeeded()
        save()
        startRun()
    }

    func sendSuggestion(_ text: String) {
        input = text
        send()
    }

    private func startRun() {
        isRunning = true
        streamingText = ""
        streamingReasoning = ""
        notice = nil
        lastUsage = nil
        bumpScroll(force: true)

        let history = session.messages
        let sessionID = session.id
        let apiKey = settings.apiKey
        let baseURL = settings.baseURL
        let model = session.model
        let planMode = session.planMode
        let systemPrompt = settings.systemPrompt(planMode: planMode)
        let temperature = settings.temperature
        let maxTokens = settings.maxTokens
        let maxSteps = settings.maxSteps
        let requireApproval = settings.requireApproval
        let engine = self.engine

        runTask = Task { [weak self] in
            guard let self else { return }
            let result = await engine.run(
                history: history,
                apiKey: apiKey,
                baseURL: baseURL,
                systemPrompt: systemPrompt,
                model: model,
                temperature: temperature,
                maxTokens: maxTokens,
                maxSteps: maxSteps,
                planMode: planMode,
                requireApproval: requireApproval,
                approval: { call in
                    await self.requestApproval(call)
                },
                emit: { update in
                    self.apply(update)
                }
            )

            if self.session.id == sessionID {
                self.session.messages = result
                self.session.updatedAt = Date()
                self.store.save(self.session)
                self.refreshSessions()
            }
            self.isRunning = false
            self.streamingText = ""
            self.streamingReasoning = ""
            self.approvalContinuation = nil
            self.pendingApproval = nil
            self.bumpScroll(force: true)
        }
    }

    private func apply(_ update: AgentUpdate) {
        switch update {
        case .content(let text):
            streamingText += text
            bumpScroll()

        case .reasoning(let text):
            streamingReasoning += text
            bumpScroll()

        case .assistantCommitted(let message):
            if !session.messages.contains(where: { $0.id == message.id }) {
                session.messages.append(message)
            }
            streamingText = ""
            streamingReasoning = ""
            save()
            bumpScroll(force: true)

        case .toolStarted(let call):
            if !session.messages.contains(where: { $0.role == .tool && $0.toolCallID == call.id }) {
                session.messages.append(ChatMessage(role: .tool, content: "", toolCallID: call.id))
            }
            bumpScroll(force: true)

        case .toolFinished(let call, let result):
            if let index = session.messages.firstIndex(where: { $0.role == .tool && $0.toolCallID == call.id }) {
                session.messages[index].content = result.output
                session.messages[index].isError = result.isError
            } else {
                var message = ChatMessage(role: .tool, content: result.output, toolCallID: call.id)
                message.isError = result.isError
                session.messages.append(message)
            }
            save()
            bumpScroll(force: true)

        case .usage(let usage):
            lastUsage = usage

        case .notice(let text):
            notice = text

        case .failed(let text):
            errorBanner = text
        }
    }

    // MARK: - 审批

    private func requestApproval(_ call: ToolCall) async -> Bool {
        if !settings.requireApproval { return true }
        if approvalContinuation != nil { return false }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = call
            bumpScroll(force: true)
        }
    }

    func resolveApproval(_ approved: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        pendingApproval = nil
        continuation.resume(returning: approved)
    }

    // MARK: - 控制

    func stop() {
        resolveApproval(false)
        runTask?.cancel()
        runTask = nil
        isRunning = false
        streamingText = ""
        streamingReasoning = ""
    }

    func cancelRun() {
        stop()
        notice = nil
    }

    func togglePlanMode() {
        session.planMode.toggle()
        save()
    }

    func selectModel(_ model: String) {
        session.model = model
        settings.model = model
        save()
    }

    func newSession() {
        cancelRun()
        save()
        let session = store.create(model: settings.model, planMode: settings.planModeDefault)
        self.session = session
        lastUsage = nil
        notice = nil
        refreshSessions()
    }

    func switchTo(_ id: UUID) {
        guard id != session.id else { return }
        cancelRun()
        save()
        if let target = sessions.first(where: { $0.id == id }) ?? store.loadAll().first(where: { $0.id == id }) {
            session = target
            lastUsage = nil
            notice = nil
        }
        refreshSessions()
    }

    func deleteSession(_ id: UUID) {
        cancelRun()
        store.delete(id)
        if session.id == id {
            let fresh = store.create(model: settings.model, planMode: settings.planModeDefault)
            session = fresh
        }
        refreshSessions()
    }

    func resetWorkspace() {
        cancelRun()
        let root = fs.root
        try? FileManager.default.removeItem(at: root)
        try? fs.bootstrap()
        shell.cwd = VirtualFS.home
        session.messages.removeAll()
        save()
        notice = "工作区已重置为初始状态。"
    }

    func save() {
        session.updatedAt = Date()
        // 落盘前修一遍：App 可能在工具执行到一半时被杀掉，
        // 磁盘上的历史必须始终满足“tool_calls 后面跟着 tool 消息”。
        var snapshot = session
        snapshot.messages = ChatHistorySanitizer.sanitize(session.messages)
        store.save(snapshot)
        refreshSessions()
    }

    func refreshSessions() {
        let all = store.loadAll()
        if all.contains(where: { $0.id == session.id }) {
            sessions = all
        } else {
            sessions = [session] + all
        }
    }

    func dismissError() {
        errorBanner = nil
    }

    private func refreshPromptState() {
        // 切换会话时丢掉上一轮的瞬时状态
        streamingText = ""
        streamingReasoning = ""
        pendingApproval = nil
        errorBanner = nil
    }

    private func bumpScroll(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastScrollBump) < 0.12 { return }
        lastScrollBump = now
        scrollSignal += 1
    }
}
