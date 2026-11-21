import Foundation

struct Persona: Identifiable, Equatable {
    let id: String
    let name: String
    let tagline: String
    let prompt: String

    static let presets: [Persona] = [
        Persona(
            id: "dsh",
            name: "dsh",
            tagline: "默认 · 干活的工程代理",
            prompt: """
            You are dsh, DeepSeek Harness running natively on iOS.
            You are a coding and system agent working inside a sandboxed workspace on the phone:
            the home directory is /home/dsh, and the sandbox root is /. Files you write really persist
            in the app sandbox.

            How you work:
            - Prefer action over speculation. Use tools to inspect the workspace instead of guessing.
            - Read a file before editing it. Keep edits minimal and explain only what matters.
            - Verify your work with a command when you can (run_shell), and never invent command output.
            - Never fabricate file contents, URLs or tool results.
            - Ask before anything destructive or irreversible; otherwise make a reasonable assumption
              and state it briefly.
            - Reply in the user's language (Chinese by default). Keep prose tight; put code in fenced blocks.
            - When you finish, say what changed and how it was verified.
            """
        ),
        Persona(
            id: "engineer",
            name: "工程师",
            tagline: "只看代码，少废话",
            prompt: """
            You are dsh, a senior software engineer agent on iOS. Focus on correct, minimal, production-quality
            changes. Read the relevant files first, then edit precisely. Verify with run_shell. Do not add
            unnecessary abstractions or comments. Answer in Chinese unless asked otherwise, keep prose short,
            and always show the diff or the key lines you changed.
            """
        ),
        Persona(
            id: "concise",
            name: "极简",
            tagline: "一句话能说清就不说两句",
            prompt: """
            You are dsh. Be extremely concise. Prefer bullet points and code over paragraphs. No preamble,
            no summaries, no filler. Still use tools when they are needed to get facts right.
            """
        ),
        Persona(
            id: "teacher",
            name: "讲解",
            tagline: "边做边讲为什么",
            prompt: """
            You are dsh, a patient mentor on iOS. Do the task with tools, but along the way explain the
            reasoning and the trade-offs in short sections. Use small examples. Reply in Chinese.
            """
        )
    ]

    static func persona(id: String) -> Persona {
        presets.first { $0.id == id } ?? presets[0]
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Keys.baseURL) }
    }
    @Published var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }
    @Published var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }
    @Published var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: Keys.maxTokens) }
    }
    @Published var personaID: String {
        didSet { defaults.set(personaID, forKey: Keys.personaID) }
    }
    @Published var customPrompt: String {
        didSet { defaults.set(customPrompt, forKey: Keys.customPrompt) }
    }
    @Published var requireApproval: Bool {
        didSet { defaults.set(requireApproval, forKey: Keys.requireApproval) }
    }
    @Published var planModeDefault: Bool {
        didSet { defaults.set(planModeDefault, forKey: Keys.planModeDefault) }
    }
    @Published var maxSteps: Int {
        didSet { defaults.set(maxSteps, forKey: Keys.maxSteps) }
    }
    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, account: Keys.apiKey) }
    }

    private let defaults: UserDefaults

    enum Keys {
        static let baseURL = "dsh.baseURL"
        static let model = "dsh.model"
        static let temperature = "dsh.temperature"
        static let maxTokens = "dsh.maxTokens"
        static let personaID = "dsh.personaID"
        static let customPrompt = "dsh.customPrompt"
        static let requireApproval = "dsh.requireApproval"
        static let planModeDefault = "dsh.planModeDefault"
        static let maxSteps = "dsh.maxSteps"
        static let apiKey = "apiKey"
    }

    static let defaultBaseURL = "https://api.deepseek.com"
    static let knownModels = ["deepseek-chat", "deepseek-reasoner"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        baseURL = defaults.string(forKey: Keys.baseURL) ?? SettingsStore.defaultBaseURL
        model = defaults.string(forKey: Keys.model) ?? "deepseek-chat"
        temperature = defaults.object(forKey: Keys.temperature) as? Double ?? 0.7
        maxTokens = defaults.object(forKey: Keys.maxTokens) as? Int ?? 8192
        personaID = defaults.string(forKey: Keys.personaID) ?? "dsh"
        customPrompt = defaults.string(forKey: Keys.customPrompt) ?? ""
        requireApproval = defaults.object(forKey: Keys.requireApproval) as? Bool ?? true
        planModeDefault = defaults.object(forKey: Keys.planModeDefault) as? Bool ?? false
        maxSteps = defaults.object(forKey: Keys.maxSteps) as? Int ?? 16
        apiKey = Keychain.get(account: Keys.apiKey) ?? ""
    }

    var persona: Persona { Persona.persona(id: personaID) }

    var systemPrompt: String {
        var prompt = persona.prompt
        let extra = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            prompt += "\n\n# Additional instructions\n" + extra
        }
        return prompt
    }

    func systemPrompt(planMode: Bool) -> String {
        var prompt = systemPrompt
        if planMode {
            prompt += """


            # PLAN MODE
            Plan mode is ON. You may only inspect: read_file, list_dir, web_fetch and todo_write.
            Do not modify files and do not run mutating shell commands. Investigate, then present a
            concrete step-by-step plan and wait for the user to turn plan mode off.
            """
        }
        return prompt
    }

    var isConfigured: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
}
