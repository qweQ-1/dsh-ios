import SwiftUI
import UIKit

@MainActor
struct ChatScreen: View {
    @StateObject private var vm: ChatViewModel
    @ObservedObject private var settings: SettingsStore
    @State private var showSessions = false
    @State private var showSettings = false
    @State private var showFiles = false

    init(settings: SettingsStore) {
        _vm = StateObject(wrappedValue: ChatViewModel(settings: settings))
        _settings = ObservedObject(wrappedValue: settings)
    }

    var body: some View {
        ZStack {
            DshTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                HairlineDivider()
                transcript
                if let notice = vm.notice {
                    noticeBar(notice)
                }
                if let call = vm.pendingApproval {
                    ApprovalCard(call: call) { approved in
                        vm.resolveApproval(approved)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                if let error = vm.errorBanner {
                    errorBar(error)
                }
                Composer(vm: vm, settings: settings) {
                    showSettings = true
                }
            }
        }
        .sheet(isPresented: $showSessions) {
            SessionsSheet(vm: vm)
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen(settings: settings, vm: vm)
        }
        .sheet(isPresented: $showFiles) {
            WorkspaceBrowser(fs: vm.fs)
        }
        .onAppear {
            vm.refreshSessions()
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text("dsh")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(DshTheme.text)
                Text("DeepSeek Harness")
                    .font(.system(size: 9.5, weight: .medium))
                    .tracking(0.5)
                    .foregroundColor(DshTheme.textTertiary)
                Spacer()

                Button {
                    vm.togglePlanMode()
                } label: {
                    Image(systemName: vm.session.planMode ? "shield.lefthalf.filled" : "shield")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(vm.session.planMode ? DshTheme.accent : DshTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(vm.session.planMode ? DshTheme.accentSoft : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .accessibilityLabel(vm.session.planMode ? "关闭计划模式" : "打开计划模式")

                Button {
                    showFiles = true
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DshTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("工作区文件")

                Button {
                    showSessions = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DshTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("会话历史")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DshTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("设置")
            }

            HStack(spacing: 8) {
                Text(vm.session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DshTheme.textSecondary)
                    .lineLimit(1)
                Spacer()
                modelChip
                if vm.session.planMode {
                    Text("PLAN")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(DshTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(DshTheme.accentSoft)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 9)
    }

    private var modelChip: some View {
        Menu {
            ForEach(SettingsStore.knownModels, id: \.self) { model in
                Button {
                    vm.selectModel(model)
                } label: {
                    if model == vm.session.model {
                        Label(model, systemImage: "checkmark")
                    } else {
                        Text(model)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(DshTheme.green)
                    .frame(width: 5, height: 5)
                Text(vm.session.model)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(DshTheme.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(DshTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DshTheme.surfaceRaised)
            .clipShape(Capsule())
        }
    }

    // MARK: - 正文

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if vm.displayItems().isEmpty && vm.streamingText.isEmpty && !vm.isRunning {
                        EmptyState(onSuggestion: { suggestion in
                            vm.sendSuggestion(suggestion)
                        })
                    }

                    ForEach(vm.displayItems()) { item in
                        row(item)
                    }

                    if vm.isRunning {
                        StreamingBubble(text: vm.streamingText, reasoning: vm.streamingReasoning)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.scrollSignal) { _ in
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: DisplayItem) -> some View {
        switch item {
        case .user(let message):
            UserRow(message: message)
        case .assistant(let message):
            AssistantRow(message: message)
        case .error(let message):
            ErrorRow(message: message)
        case .tool(let call, let result, let running):
            ToolCard(call: call, result: result, running: running)
        }
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(DshTheme.textTertiary)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(DshTheme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(DshTheme.surface)
        .onTapGesture { vm.notice = nil }
    }

    private func errorBar(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(DshTheme.red)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(DshTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                vm.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DshTheme.textTertiary)
            }
        }
        .padding(12)
        .background(DshTheme.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

// MARK: - 空状态

private struct EmptyState: View {
    let onSuggestion: (String) -> Void

    private let suggestions = [
        "看看工作区里有什么",
        "写一个部署脚本并解释每一行",
        "把 ~/README.md 翻译成英文"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("dsh")
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundColor(DshTheme.text)
                Text("DeepSeek Harness，跑在你的手机上。")
                    .font(.system(size: 14))
                    .foregroundColor(DshTheme.textSecondary)
                Text("读写沙盒文件、执行命令、抓网页——工具调用会先征求你的同意。")
                    .font(.system(size: 12.5))
                    .foregroundColor(DshTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("试试")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(DshTheme.textTertiary)
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onSuggestion(suggestion)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(DshTheme.accent)
                            Text(suggestion)
                                .font(.system(size: 13))
                                .foregroundColor(DshTheme.text)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(DshTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(DshTheme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - 消息

struct UserRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)
            Text(message.content)
                .font(.system(size: 14.5))
                .foregroundColor(DshTheme.text)
                .lineSpacing(2)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(DshTheme.accent.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .textSelection(.enabled)
        }
    }
}

struct AssistantRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ReasoningView(text: reasoning, live: false)
            }
            if !message.content.isEmpty {
                MarkdownView(text: message.content)
            }
        }
    }
}

struct ReasoningView: View {
    let text: String
    let live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if live {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                    }
                    Text(live ? "思考中…" : "思考过程")
                        .font(.system(size: 11, weight: .medium))
                    Text("· \(text.count) 字")
                        .font(.system(size: 10))
                        .foregroundColor(DshTheme.textTertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundColor(DshTheme.textSecondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(DshTheme.textTertiary)
                    .lineSpacing(2)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(DshTheme.border)
                            .frame(width: 1)
                    }
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(DshTheme.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ErrorRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(DshTheme.red)
                .padding(.top, 1)
            Text(message.content)
                .font(.system(size: 13))
                .foregroundColor(DshTheme.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(DshTheme.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct StreamingBubble: View {
    let text: String
    let reasoning: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !reasoning.isEmpty {
                ReasoningView(text: reasoning, live: true)
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(DshTheme.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            } else if reasoning.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("正在思考…")
                        .font(.system(size: 12))
                        .foregroundColor(DshTheme.textTertiary)
                }
            }
        }
    }
}

// MARK: - 工具卡片

struct ToolCard: View {
    let call: ToolCall
    let result: ToolResult?
    let running: Bool
    @State private var expanded = false

    private var failed: Bool { result?.isError ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(iconBackground)
                        Image(systemName: ToolPresentation.icon(call.name))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(iconColor)
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(ToolPresentation.title(call.name))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DshTheme.text)
                            Text(call.name)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(DshTheme.textTertiary)
                        }
                        Text(ToolPresentation.summary(call))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(DshTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 6)

                    if running {
                        ProgressView().scaleEffect(0.6)
                    } else if failed {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(DshTheme.red)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(DshTheme.green)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(DshTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let result = result, !result.output.isEmpty {
                HairlineDivider()
                ScrollView(.vertical, showsIndicators: true) {
                    Text(result.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(failed ? DshTheme.red.opacity(0.9) : DshTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            }
        }
        .background(DshTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(failed ? DshTheme.red.opacity(0.35) : DshTheme.border, lineWidth: 1)
        )
    }

    private var iconBackground: Color {
        if failed { return DshTheme.red.opacity(0.14) }
        if running { return DshTheme.orange.opacity(0.14) }
        return DshTheme.accentSoft
    }

    private var iconColor: Color {
        if failed { return DshTheme.red }
        if running { return DshTheme.orange }
        return DshTheme.accent
    }
}

// MARK: - 审批卡片

struct ApprovalCard: View {
    let call: ToolCall
    let onResolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundColor(DshTheme.orange)
                Text("dsh 想\(ToolPresentation.title(call.name))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(DshTheme.text)
                Spacer()
                Text(call.name)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DshTheme.textTertiary)
            }

            Text(ToolPresentation.summary(call))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(DshTheme.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(DshTheme.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    onResolve(false)
                } label: {
                    Text("拒绝")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(DshTheme.surfaceRaised)
                        .foregroundColor(DshTheme.textSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    onResolve(true)
                } label: {
                    Text("允许")
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(DshTheme.accent)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(DshTheme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(DshTheme.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - 输入框

struct Composer: View {
    @ObservedObject var vm: ChatViewModel
    @ObservedObject var settings: SettingsStore
    var onOpenSettings: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 9) {
                TextField("让 dsh 做点什么…", text: $vm.input, axis: .vertical)
                    .focused($focused)
                    .lineLimit(1...6)
                    .font(.system(size: 14.5))
                    .foregroundColor(DshTheme.text)
                    .tint(DshTheme.accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(DshTheme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(focused ? DshTheme.accent.opacity(0.5) : DshTheme.border, lineWidth: 1)
                    )

                Button {
                    if vm.isRunning {
                        vm.stop()
                    } else {
                        focused = false
                        vm.send()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(buttonBackground)
                        Image(systemName: vm.isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(buttonForeground)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(!vm.isRunning && !vm.canSend)
            }

            HStack(spacing: 8) {
                if !settings.isConfigured {
                    Button(action: onOpenSettings) {
                        Label("配置 API Key", systemImage: "key.fill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(DshTheme.orange)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(vm.settings.persona.name)
                        .font(.system(size: 10))
                        .foregroundColor(DshTheme.textTertiary)
                }

                Text("·")
                    .font(.system(size: 10))
                    .foregroundColor(DshTheme.textTertiary)

                Text(vm.session.planMode ? "计划模式" : "执行模式")
                    .font(.system(size: 10))
                    .foregroundColor(vm.session.planMode ? DshTheme.accent : DshTheme.textTertiary)

                Spacer()

                if let usage = vm.lastUsage {
                    Text("\(usage.totalTokens) tokens")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(DshTheme.textTertiary)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            DshTheme.surface
                .overlay(alignment: .top) { HairlineDivider() }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var buttonBackground: Color {
        if vm.isRunning { return DshTheme.red.opacity(0.16) }
        return vm.canSend ? DshTheme.accent : DshTheme.surfaceRaised
    }

    private var buttonForeground: Color {
        if vm.isRunning { return DshTheme.red }
        return vm.canSend ? .white : DshTheme.textTertiary
    }
}
