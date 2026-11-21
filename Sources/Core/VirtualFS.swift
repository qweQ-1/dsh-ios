import Foundation

/// 沙盒文件系统：把 App 的 Application Support 目录当成 `/`，
/// 所有虚拟路径都映射到它下面，`..` 永远出不去。
final class VirtualFS {
    /// 虚拟路径里的家目录。
    static let home = "/home/dsh"

    let root: URL
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    // MARK: - 路径

    /// 把任意写法（相对、绝对、`~`、`.`、`..`）规整成绝对虚拟路径。
    /// 越过根目录的部分会被吃掉（`/..` → `/`），保证不会逃出沙盒。
    func resolve(_ path: String, cwd: String) -> String {
        var raw = path
        if raw == "~" {
            raw = VirtualFS.home
        } else if raw.hasPrefix("~/") {
            raw = VirtualFS.home + String(raw.dropFirst(1))
        }
        if raw.isEmpty {
            raw = cwd
        }

        var comps: [String] = raw.hasPrefix("/") ? [] : cwd.split(separator: "/").map(String.init)
        for comp in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch comp {
            case ".":
                continue
            case "..":
                if !comps.isEmpty { comps.removeLast() }
            default:
                comps.append(String(comp))
            }
        }
        return "/" + comps.joined(separator: "/")
    }

    func url(for virtualPath: String) -> URL {
        var url = root
        for comp in virtualPath.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(comp))
        }
        return url
    }

    func parent(of virtualPath: String) -> String {
        let comps = virtualPath.split(separator: "/").map(String.init)
        if comps.count <= 1 { return "/" }
        return "/" + comps.dropLast().joined(separator: "/")
    }

    func join(_ dir: String, _ name: String) -> String {
        if dir == "/" { return "/" + name }
        return dir + "/" + name
    }

    /// 相对路径（用于 `find` / glob 输出）。
    func relative(_ virtualPath: String, from cwd: String) -> String {
        if virtualPath == cwd { return "." }
        if cwd == "/" { return String(virtualPath.dropFirst()) }
        if virtualPath.hasPrefix(cwd + "/") {
            return String(virtualPath.dropFirst(cwd.count + 1))
        }
        return virtualPath
    }

    // MARK: - 基本查询

    func exists(_ virtualPath: String) -> Bool {
        fm.fileExists(atPath: url(for: virtualPath).path)
    }

    func isDirectory(_ virtualPath: String) -> Bool {
        var isDir: ObjCBool = false
        let found = fm.fileExists(atPath: url(for: virtualPath).path, isDirectory: &isDir)
        return found && isDir.boolValue
    }

    func isExecutable(_ virtualPath: String) -> Bool {
        fm.isExecutableFile(atPath: url(for: virtualPath).path)
    }

    struct Info {
        var name: String
        var isDirectory: Bool
        var size: Int64
        var modified: Date
    }

    func info(_ virtualPath: String) -> Info? {
        let path = url(for: virtualPath).path
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let name = (virtualPath as NSString).lastPathComponent
        return Info(name: name.isEmpty ? "/" : name,
                    isDirectory: isDir,
                    size: isDir ? 4096 : size,
                    modified: modified)
    }

    // MARK: - 读写

    func contents(_ virtualPath: String) throws -> [String] {
        guard isDirectory(virtualPath) else {
            throw ShellError("not a directory: \(virtualPath)")
        }
        do {
            return try fm.contentsOfDirectory(atPath: url(for: virtualPath).path).sorted()
        } catch {
            throw ShellError("cannot list \(virtualPath): \(error.localizedDescription)")
        }
    }

    func read(_ virtualPath: String) throws -> String {
        guard exists(virtualPath) else { throw ShellError("no such file: \(virtualPath)") }
        guard !isDirectory(virtualPath) else { throw ShellError("is a directory: \(virtualPath)") }
        do {
            return try String(contentsOf: url(for: virtualPath), encoding: .utf8)
        } catch {
            throw ShellError("cannot read \(virtualPath): \(error.localizedDescription)")
        }
    }

    func readData(_ virtualPath: String) throws -> Data {
        guard exists(virtualPath) else { throw ShellError("no such file: \(virtualPath)") }
        guard !isDirectory(virtualPath) else { throw ShellError("is a directory: \(virtualPath)") }
        do {
            return try Data(contentsOf: url(for: virtualPath))
        } catch {
            throw ShellError("cannot read \(virtualPath): \(error.localizedDescription)")
        }
    }

    func write(_ text: String, to virtualPath: String, append: Bool) throws {
        try ensureParent(of: virtualPath)
        let target = url(for: virtualPath)
        if append {
            if exists(virtualPath) {
                guard !isDirectory(virtualPath) else { throw ShellError("is a directory: \(virtualPath)") }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = text.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } else {
                try Data(text.utf8).write(to: target, options: .atomic)
            }
        } else {
            try Data(text.utf8).write(to: target, options: .atomic)
        }
    }

    func writeData(_ data: Data, to virtualPath: String) throws {
        try ensureParent(of: virtualPath)
        try data.write(to: url(for: virtualPath), options: .atomic)
    }

    private func ensureParent(of virtualPath: String) throws {
        let dir = parent(of: virtualPath)
        guard isDirectory(dir) else { throw ShellError("no such directory: \(dir)") }
    }

    // MARK: - 变更

    func mkdir(_ virtualPath: String, parents: Bool) throws {
        if exists(virtualPath) {
            if parents && isDirectory(virtualPath) { return }
            throw ShellError("file exists: \(virtualPath)")
        }
        do {
            try fm.createDirectory(at: url(for: virtualPath),
                                   withIntermediateDirectories: parents)
        } catch {
            throw ShellError("cannot create \(virtualPath): \(error.localizedDescription)")
        }
    }

    func touch(_ virtualPath: String) throws {
        if exists(virtualPath) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url(for: virtualPath).path)
            return
        }
        try write("", to: virtualPath, append: false)
    }

    func remove(_ virtualPath: String, recursive: Bool) throws {
        guard exists(virtualPath) else { throw ShellError("no such file or directory: \(virtualPath)") }
        if virtualPath == "/" { throw ShellError("refusing to remove /") }
        if isDirectory(virtualPath) && !recursive {
            throw ShellError("is a directory (use -r): \(virtualPath)")
        }
        do {
            try fm.removeItem(at: url(for: virtualPath))
        } catch {
            throw ShellError("cannot remove \(virtualPath): \(error.localizedDescription)")
        }
    }

    func copy(_ source: String, to destination: String) throws {
        guard exists(source) else { throw ShellError("no such file or directory: \(source)") }
        var target = destination
        if isDirectory(destination) {
            target = join(destination, (source as NSString).lastPathComponent)
        }
        if exists(target) {
            throw ShellError("file exists: \(target)")
        }
        try ensureParent(of: target)
        do {
            try fm.copyItem(at: url(for: source), to: url(for: target))
        } catch {
            throw ShellError("cannot copy: \(error.localizedDescription)")
        }
    }

    func move(_ source: String, to destination: String) throws {
        guard exists(source) else { throw ShellError("no such file or directory: \(source)") }
        var target = destination
        if isDirectory(destination) {
            target = join(destination, (source as NSString).lastPathComponent)
        }
        if exists(target) { throw ShellError("file exists: \(target)") }
        try ensureParent(of: target)
        do {
            try fm.moveItem(at: url(for: source), to: url(for: target))
        } catch {
            throw ShellError("cannot move: \(error.localizedDescription)")
        }
    }

    /// 递归大小。
    func diskUsage(_ virtualPath: String) -> Int64 {
        guard let item = info(virtualPath) else { return 0 }
        if !item.isDirectory { return item.size }
        var total: Int64 = 0
        if let names = try? contents(virtualPath) {
            for name in names {
                total += diskUsage(join(virtualPath, name))
            }
        }
        return total
    }

    // MARK: - 通配符

    func glob(_ pattern: String, cwd: String) -> [String] {
        let isAbsolute = pattern.hasPrefix("/") || pattern.hasPrefix("~")
        var body = pattern
        if body == "~" {
            body = ""
        } else if body.hasPrefix("~/") {
            body = String(body.dropFirst(2))
        }
        let segments = body.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var current: [String] = isAbsolute ? ["/"] : [cwd]

        for segment in segments {
            if segment == "." { continue }
            if segment == ".." {
                current = current.map { parent(of: $0) }
                continue
            }
            if !segment.contains("*") && !segment.contains("?") {
                current = current.map { join($0, segment) }.filter { exists($0) }
                continue
            }
            var next: [String] = []
            for dir in current {
                let names = (try? contents(dir)) ?? []
                for name in names where VirtualFS.wildcardMatch(segment, name) {
                    next.append(join(dir, name))
                }
            }
            current = next
        }

        let resolved = current.filter { exists($0) }.sorted()
        if isAbsolute && pattern.hasPrefix("/") {
            return resolved
        }
        return resolved.map { relative($0, from: cwd) }
    }

    static func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0
        var ti = 0
        var starIndex = -1
        var matchIndex = 0

        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
                pi += 1
                ti += 1
            } else if pi < p.count && p[pi] == "*" {
                starIndex = pi
                matchIndex = ti
                pi += 1
            } else if starIndex >= 0 {
                pi = starIndex + 1
                matchIndex += 1
                ti = matchIndex
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: - 初始目录树

    /// 幂等：已经存在的内容不会被覆盖。
    func bootstrap() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dirs = [
            "/home/dsh",
            "/home/dsh/notes",
            "/home/dsh/projects",
            "/home/dsh/.config",
            "/etc",
            "/tmp",
            "/var/log",
            "/usr/bin",
            "/usr/local/bin"
        ]
        for dir in dirs where !isDirectory(dir) {
            try fm.createDirectory(at: url(for: dir), withIntermediateDirectories: true)
        }

        try seed("/etc/hostname", "iphone\n")
        try seed("/etc/motd", "\u{1B}[1;36mdsh\u{1B}[0m — a pocket Unix shell for iOS. Type `help`.\n")
        try seed("/etc/passwd", "root:x:0:0:root:/root:/bin/sh\ndsh:x:501:20:dsh:/home/dsh:/usr/bin/zsh\n")
        try seed("/etc/shells", "/bin/sh\n/usr/bin/zsh\n/usr/local/bin/dsh\n")
        try seed("/home/dsh/.zshrc", VirtualFS.defaultZshrc)
        try seed("/home/dsh/README.md", VirtualFS.defaultReadme)
        try seed("/home/dsh/notes/todo.md", VirtualFS.defaultTodo)
        try seed("/var/log/dsh.log", "")
    }

    private func seed(_ virtualPath: String, _ text: String) throws {
        guard !exists(virtualPath) else { return }
        try write(text, to: virtualPath, append: false)
    }

    static let defaultZshrc = """
    # ~/.zshrc — dsh 自带的一份示例配置（真实文件，可以随便改）
    export EDITOR=nvim
    export LANG=zh_CN.UTF-8

    alias ll='ls -l'
    alias la='ls -la'
    alias ..='cd ..'
    alias g='grep'

    # dsh 的提示符由 App 渲染，这里只影响 `cat ~/.zshrc` 看到的内容。
    PROMPT='%F{green}dsh@iphone%f:%F{cyan}%~%f %# '
    """

    static let defaultReadme = """
    # welcome to dsh

    这是 dsh 的沙盒根目录里的一份说明文件，位于 `~/README.md`。

    - `help`            查看所有命令
    - `neofetch`        看设备信息
    - `theme dracula`   换配色
    - `curl <url>`      发一个真实的 HTTP 请求

    文件都真实保存在 App 的沙盒里（Application Support/DshRoot），
    卸载 App 才会消失。`ls -la` 看看目录结构吧。
    """

    static let defaultTodo = """
    # TODO

    - [x] 打开 dsh
    - [ ] cat ~/README.md
    - [ ] 试试 echo hello > hello.txt && cat hello.txt
    - [ ] neofetch
    """
}
