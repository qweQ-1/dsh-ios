import SwiftUI

struct FilePreview: Identifiable {
    let id = UUID()
    let name: String
    let content: String
}

@MainActor
struct WorkspaceBrowser: View {
    let fs: VirtualFS
    @Environment(\.dismiss) private var dismiss
    @State private var path: String = VirtualFS.home
    @State private var preview: FilePreview?

    private var entries: [String] {
        ((try? fs.contents(path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DshTheme.textTertiary)
                        .listRowBackground(DshTheme.surface)
                }

                Section {
                    if entries.isEmpty {
                        Text("空目录")
                            .font(.system(size: 13))
                            .foregroundColor(DshTheme.textTertiary)
                            .listRowBackground(DshTheme.surface)
                    }
                    ForEach(entries, id: \.self) { name in
                        row(name)
                            .listRowBackground(DshTheme.surface)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(DshTheme.background)
            .navigationTitle("工作区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if path != VirtualFS.home {
                            path = fs.parent(of: path)
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(path == VirtualFS.home)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $preview) { file in
                NavigationStack {
                    ScrollView {
                        Text(file.content)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(DshTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .textSelection(.enabled)
                    }
                    .background(DshTheme.background)
                    .navigationTitle(file.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { preview = nil }
                        }
                    }
                }
                .preferredColorScheme(.dark)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ name: String) -> some View {
        let isDirectory = fs.isDirectory(fs.join(path, name))
        let info = fs.info(fs.join(path, name))
        return Button {
            let child = fs.join(path, name)
            if isDirectory {
                path = child
            } else {
                let content = (try? fs.read(child)) ?? "(无法以文本方式打开这个文件)"
                preview = FilePreview(name: name, content: content)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isDirectory ? "folder.fill" : "doc.text")
                    .font(.system(size: 13))
                    .foregroundColor(isDirectory ? DshTheme.accent : DshTheme.textSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13.5))
                        .foregroundColor(DshTheme.text)
                    if let info = info, !isDirectory {
                        Text(Fmt.humanSize(info.size))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(DshTheme.textTertiary)
                    }
                }
                Spacer()
                if isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DshTheme.textTertiary)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
