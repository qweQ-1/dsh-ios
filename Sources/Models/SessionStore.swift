import Foundation

/// 会话仓库：一个会话一个 JSON 文件，放在 Application Support/Sessions。
final class SessionStore {
    let root: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL) {
        self.root = root
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json")
    }

    func loadAll() -> [ChatSession] {
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var sessions: [ChatSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(ChatSession.self, from: data) else {
                continue
            }
            sessions.append(session)
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ session: ChatSession) {
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: url(for: session.id), options: .atomic)
    }

    func delete(_ id: UUID) {
        try? fm.removeItem(at: url(for: id))
    }

    func create(model: String, planMode: Bool) -> ChatSession {
        let session = ChatSession(model: model, planMode: planMode)
        save(session)
        return session
    }
}
