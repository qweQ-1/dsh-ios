import XCTest
@testable import Dsh

final class CoreTests: XCTestCase {
    var root: URL!
    var fs: VirtualFS!
    var shell: Shell!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fs = VirtualFS(root: root)
        try fs.bootstrap()
        shell = Shell(fs: fs)
    }

    override func tearDownWithError() throws {
        if let root = root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: 路径

    func testResolveStaysInsideSandbox() {
        XCTAssertEqual(fs.resolve("../../etc/passwd", cwd: "/home/dsh"), "/etc/passwd")
        XCTAssertEqual(fs.resolve("/..", cwd: "/home/dsh"), "/")
        XCTAssertEqual(fs.resolve("~", cwd: "/"), "/home/dsh")
        XCTAssertEqual(fs.resolve("notes/../README.md", cwd: "/home/dsh"), "/home/dsh/README.md")
        XCTAssertEqual(fs.resolve("", cwd: "/home/dsh"), "/home/dsh")
    }

    func testBootstrapCreatesHome() {
        XCTAssertTrue(fs.isDirectory("/home/dsh"))
        XCTAssertTrue(fs.exists("/home/dsh/.zshrc"))
        XCTAssertTrue(fs.exists("/etc/hostname"))
    }

    // MARK: 分词

    func testTokenizerQuotesAndOperators() throws {
        let tokens = try Tokenizer.tokenize(#"echo "a b" 'c d' > out.txt"#)
        XCTAssertEqual(tokens, [
            .word("echo"), .word("a b"), .word("c d"), .op(">"), .word("out.txt")
        ])
    }

    func testTokenizerEscapesAndComment() throws {
        let tokens = try Tokenizer.tokenize(#"echo a\ b # trailing"#)
        XCTAssertEqual(tokens, [.word("echo"), .word("a b")])
    }

    func testTokenizerRejectsUnterminatedQuote() {
        XCTAssertThrowsError(try Tokenizer.tokenize(#"echo "oops"#))
    }

    // MARK: 语法

    func testParserBuildsPipeline() throws {
        let tokens = try Tokenizer.tokenize("cat README.md | grep dsh > out.txt")
        let items = try Parser.parse(tokens)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].pipeline.commands.count, 2)
        XCTAssertEqual(items[0].pipeline.commands[1].outRedirect?.path, "out.txt")
        XCTAssertEqual(items[0].pipeline.commands[1].outRedirect?.append, false)
    }

    func testParserChains() throws {
        let tokens = try Tokenizer.tokenize("false && echo no || echo yes")
        let items = try Parser.parse(tokens)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].opToNext, .and)
        XCTAssertEqual(items[1].opToNext, .or)
        XCTAssertNil(items[2].opToNext)
    }

    func testParserRejectsTrailingPipe() {
        XCTAssertThrowsError(try Parser.parse(Tokenizer.tokenize("echo hi |")))
    }

    // MARK: 执行

    func testEchoRedirectAndCat() async {
        let write = await shell.run("echo hello > a.txt")
        XCTAssertEqual(write.status, 0)
        let read = await shell.run("cat a.txt")
        XCTAssertEqual(read.stdout, "hello\n")
    }

    func testAppendAndPipeline() async {
        _ = await shell.run("echo one > f.txt")
        _ = await shell.run("echo two >> f.txt")
        let wc = await shell.run("cat f.txt | wc -l")
        XCTAssertEqual(wc.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testChainsShortCircuit() async {
        let result = await shell.run("false && echo no || echo yes")
        XCTAssertEqual(result.stdout, "yes\n")
        XCTAssertEqual(result.status, 0)
    }

    func testVariableExpansion() async {
        let result = await shell.run("echo $HOME")
        XCTAssertEqual(result.stdout, "/home/dsh\n")
    }

    func testAliasExpansion() async {
        _ = await shell.run("alias hi=echo")
        let result = await shell.run("hi hello")
        XCTAssertEqual(result.stdout, "hello\n")
    }

    func testUnknownCommandReturns127() async {
        let result = await shell.run("definitely-not-a-command")
        XCTAssertEqual(result.status, 127)
        XCTAssertTrue(result.stderr.contains("command not found"))
    }

    func testGlobExpansion() async {
        _ = await shell.run("touch b.txt")
        _ = await shell.run("touch a.txt")
        let result = await shell.run("echo *.txt")
        XCTAssertEqual(result.stdout, "a.txt b.txt\n")
    }

    func testCdAndPwd() async {
        let mkdir = await shell.run("mkdir -p projects/demo")
        XCTAssertEqual(mkdir.status, 0)
        _ = await shell.run("cd projects/demo")
        let pwd = await shell.run("pwd")
        XCTAssertEqual(pwd.stdout, "/home/dsh/projects/demo\n")
        let back = await shell.run("cd -")
        XCTAssertEqual(back.status, 0)
        let pwd2 = await shell.run("pwd")
        XCTAssertEqual(pwd2.stdout, "/home/dsh\n")
    }

    func testGrepStatusAndLines() async {
        _ = await shell.run("printf 'alpha\\nbeta\\ngamma\\n' > words.txt")
        let hit = await shell.run("grep -n 'et' words.txt")
        XCTAssertEqual(hit.status, 0)
        XCTAssertEqual(hit.stdout, "2:beta\n")
        let miss = await shell.run("grep zzz words.txt")
        XCTAssertEqual(miss.status, 1)
        XCTAssertEqual(miss.stdout, "")
    }

    func testCompletion() {
        let (commandInput, commandCandidates) = shell.complete("neo")
        XCTAssertEqual(commandInput, "neofetch ")
        XCTAssertTrue(commandCandidates.isEmpty)

        _ = fs.write("x", to: "/home/dsh/README.md", append: false)
        let (fileInput, _) = shell.complete("cat REA")
        XCTAssertEqual(fileInput, "cat README.md ")
    }

    func testAnsiParser() {
        let spans = AnsiParser.parse("\u{1B}[31mred\u{1B}[0m plain")
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].text, "red")
        XCTAssertEqual(spans[0].style.foreground, .basic(1))
        XCTAssertEqual(spans[1].text, " plain")
        XCTAssertNil(spans[1].style.foreground)
    }

    func testWildcardMatch() {
        XCTAssertTrue(VirtualFS.wildcardMatch("*.swift", "App.swift"))
        XCTAssertFalse(VirtualFS.wildcardMatch("*.swift", "App.swift.txt"))
        XCTAssertTrue(VirtualFS.wildcardMatch("a?c", "abc"))
    }
}
