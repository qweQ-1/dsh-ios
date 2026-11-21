import SwiftUI

@MainActor
struct SessionsSheet: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        vm.newSession()
                        dismiss()
                    } label: {
                        Label("新建会话", systemImage: "plus.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(DshTheme.accent)
                    }
                    .listRowBackground(DshTheme.surface)
                }

                Section {
                    ForEach(vm.sessions) { session in
                        Button {
                            vm.switchTo(session.id)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(DshTheme.text)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text("\(session.messages.filter { $0.role == .user }.count) 条消息")
                                        Text("·")
                                        Text(Fmt.shortDate.string(from: session.updatedAt))
                                        if session.planMode {
                                            Text("PLAN")
                                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                .foregroundColor(DshTheme.accent)
                                        }
                                    }
                                    .font(.system(size: 10.5))
                                    .foregroundColor(DshTheme.textTertiary)
                                }
                                Spacer()
                                if session.id == vm.session.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(DshTheme.accent)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(DshTheme.surface)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                vm.deleteSession(session.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("历史")
                } footer: {
                    Text("会话保存在本机，换一次任务开一个新会话，上下文更干净。")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DshTheme.background)
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(DshTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
