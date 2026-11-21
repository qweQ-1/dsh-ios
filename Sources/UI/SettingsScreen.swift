import SwiftUI

@MainActor
struct SettingsScreen: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var showFiles = false
    @State private var showReset = false

    var body: some View {
        NavigationStack {
            Form {
                apiSection
                modelSection
                agentSection
                personaSection
                workspaceSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(DshTheme.background)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(DshTheme.accent)
                }
            }
            .sheet(isPresented: $showFiles) {
                WorkspaceBrowser(fs: vm.fs)
            }
            .alert("重置工作区？", isPresented: $showReset) {
                Button("取消", role: .cancel) {}
                Button("重置", role: .destructive) { vm.resetWorkspace() }
            } message: {
                Text("会删除沙盒里的所有文件，包括 dsh 写过的内容。这个操作不能撤销。")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - API

    private var apiSection: some View {
        Section {
            SecureField("sk-…", text: $settings.apiKey)
                .font(.system(size: 13, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .listRowBackground(DshTheme.surface)

            TextField("https://api.deepseek.com", text: $settings.baseURL)
                .font(.system(size: 12.5, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .listRowBackground(DshTheme.surface)

            Button {
                testConnection()
            } label: {
                HStack {
                    Text("测试连接")
                        .foregroundColor(DshTheme.accent)
                    Spacer()
                    if testing {
                        ProgressView().scaleEffect(0.75)
                    }
                }
            }
            .listRowBackground(DshTheme.surface)

            if let testResult = testResult {
                Text(testResult)
                    .font(.system(size: 11))
                    .foregroundColor(testFailed ? DshTheme.red : DshTheme.green)
                    .listRowBackground(DshTheme.surface)
            }

            Link(destination: URL(string: "https://platform.deepseek.com/api_keys")!) {
                HStack {
                    Text("获取 DeepSeek API Key")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13))
                .foregroundColor(DshTheme.accent)
            }
            .listRowBackground(DshTheme.surface)
        } header: {
            Text("DeepSeek API")
        } footer: {
            Text("Key 只存在本机的 Keychain 里，不会写进会话文件，也不会出现在日志里。")
        }
    }

    // MARK: - 模型

    private var modelSection: some View {
        Section {
            TextField("deepseek-chat", text: $settings.model)
                .font(.system(size: 13, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .listRowBackground(DshTheme.surface)

            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.1f", settings.temperature))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DshTheme.textSecondary)
            }
            .listRowBackground(DshTheme.surface)
            Slider(value: $settings.temperature, in: 0...1.5, step: 0.1)
                .tint(DshTheme.accent)
                .listRowBackground(DshTheme.surface)

            Stepper(value: $settings.maxTokens, in: 1024...16384, step: 1024) {
                HStack {
                    Text("最大输出")
                    Spacer()
                    Text("\(settings.maxTokens) tokens")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DshTheme.textSecondary)
                }
            }
            .listRowBackground(DshTheme.surface)
        } header: {
            Text("模型")
        } footer: {
            Text("常用：deepseek-chat（快）、deepseek-reasoner（会先思考）。新会话会使用这里的模型。")
        }
    }

    // MARK: - 代理行为

    private var agentSection: some View {
        Section {
            Toggle(isOn: $settings.requireApproval) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("写操作先确认")
                    Text("写文件 / 改文件 / 跑命令前弹确认")
                        .font(.system(size: 10.5))
                        .foregroundColor(DshTheme.textTertiary)
                }
            }
            .tint(DshTheme.accent)
            .listRowBackground(DshTheme.surface)

            Toggle(isOn: $settings.planModeDefault) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("新会话默认计划模式")
                    Text("只读工具，先给方案再动手")
                        .font(.system(size: 10.5))
                        .foregroundColor(DshTheme.textTertiary)
                }
            }
            .tint(DshTheme.accent)
            .listRowBackground(DshTheme.surface)

            Stepper(value: $settings.maxSteps, in: 4...40, step: 2) {
                HStack {
                    Text("单轮最多工具步数")
                    Spacer()
                    Text("\(settings.maxSteps)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DshTheme.textSecondary)
                }
            }
            .listRowBackground(DshTheme.surface)
        } header: {
            Text("代理")
        } footer: {
            Text("关掉「写操作先确认」后 dsh 会自己动手，适合你信任它的任务。")
        }
    }

    // MARK: - 人设

    private var personaSection: some View {
        Section {
            Picker(selection: $settings.personaID) {
                ForEach(Persona.presets) { persona in
                    Text(persona.name).tag(persona.id)
                }
            } label: {
                Text("人设")
            }
            .tint(DshTheme.accent)
            .listRowBackground(DshTheme.surface)

            Text(settings.persona.tagline)
                .font(.system(size: 11))
                .foregroundColor(DshTheme.textTertiary)
                .listRowBackground(DshTheme.surface)

            TextEditor(text: $settings.customPrompt)
                .font(.system(size: 12.5))
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .background(DshTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .listRowBackground(DshTheme.surface)
        } header: {
            Text("人设 / 附加指令")
        } footer: {
            Text("附加指令会拼在人设后面，比如「永远用中文回答」「不要写注释」。")
        }
    }

    // MARK: - 工作区

    private var workspaceSection: some View {
        Section {
            Text(vm.workspacePath)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(DshTheme.textTertiary)
                .textSelection(.enabled)
                .listRowBackground(DshTheme.surface)

            HStack {
                Text("文件数")
                Spacer()
                Text("\(vm.filesCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DshTheme.textSecondary)
            }
            .listRowBackground(DshTheme.surface)

            Button {
                showFiles = true
            } label: {
                HStack {
                    Text("浏览工作区")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DshTheme.textTertiary)
                }
                .foregroundColor(DshTheme.text)
            }
            .listRowBackground(DshTheme.surface)

            Button(role: .destructive) {
                showReset = true
            } label: {
                Text("重置工作区")
            }
            .listRowBackground(DshTheme.surface)
        } header: {
            Text("工作区")
        } footer: {
            Text("dsh 只能读写这个沙盒目录，碰不到系统其它 App 的数据。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text("\(AppInfo.version) (\(AppInfo.build))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DshTheme.textSecondary)
            }
            .listRowBackground(DshTheme.surface)

            Link(destination: URL(string: "https://github.com/qweQ-1/dsh-ios")!) {
                HStack {
                    Text("GitHub 仓库")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(DshTheme.accent)
            }
            .listRowBackground(DshTheme.surface)

            VStack(alignment: .leading, spacing: 4) {
                Text("dsh for iOS")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DshTheme.textSecondary)
                Text("DeepSeek Harness 的原生 iOS 实现：DeepSeek API + 工具循环 + 沙盒文件系统。不是把 Node 塞进手机，所以不用越狱，也不需要 iSH。")
                    .font(.system(size: 11))
                    .foregroundColor(DshTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(DshTheme.surface)
        } header: {
            Text("关于")
        }
    }

    // MARK: - 测试

    private func testConnection() {
        testing = true
        testResult = nil
        testFailed = false
        let key = settings.apiKey
        let base = settings.baseURL
        Task {
            do {
                let models = try await DeepSeekClient().listModels(apiKey: key, baseURL: base)
                testResult = "连接成功，可用模型：\(models.joined(separator: ", "))"
                testFailed = false
            } catch {
                testResult = error.localizedDescription
                testFailed = true
            }
            testing = false
        }
    }
}
