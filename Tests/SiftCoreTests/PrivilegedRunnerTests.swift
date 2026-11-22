import Foundation
import Testing

@testable import SiftCore

@Suite struct PrivilegedRunnerTests {
    private let hostile = ["it's", "a \"quoted\" name", "$(touch pwned)", "semi;colon", "back`tick`", "-rf", "sp ace"]

    @Test func argumentsCarryPathsVerbatim() async {
        let runner = FakeCommandRunner(fallback: CommandResult(status: 0))
        let removals =
            hostile.map { PrivilegedRemoval(parent: "/p", name: $0) } + [
                PrivilegedRemoval(parent: "/q", name: "X.component", receipt: "com.neuraldsp.XAU.pkg")
            ]
        let outcome = await OSAScriptPrivilegedRunner(runner: runner).run(
            removals, forgetting: ["com.neuraldsp.XManual.pkg"])
        #expect(outcome == .finished)
        let call = try! #require(runner.calls.first)
        #expect(call[0] == "/usr/bin/osascript")
        #expect(call[1] == "-e")
        #expect(call[2] == OSAScriptPrivilegedRunner.productionScript)
        let expected =
            hostile.flatMap { ["/p", $0, ""] } + ["/q", "X.component", "com.neuraldsp.XAU.pkg"]
            + ["receipts:", "com.neuraldsp.XManual.pkg"]
        #expect(Array(call.dropFirst(3)) == expected)
        // nothing from the paths ends up in the script source
        for name in hostile where name != "-rf" { #expect(!OSAScriptPrivilegedRunner.productionScript.contains(name)) }
        #expect(OSAScriptPrivilegedRunner.productionScript.contains("with administrator privileges"))
    }

    @Test func nothingToDoRunsNothing() async {
        let runner = FakeCommandRunner()
        #expect(await OSAScriptPrivilegedRunner(runner: runner).run([], forgetting: []) == .finished)
        #expect(runner.calls.isEmpty)
    }

    @Test func outcomes() {
        #expect(OSAScriptPrivilegedRunner.outcome(CommandResult(status: 0)) == .finished)
        #expect(
            OSAScriptPrivilegedRunner.outcome(
                CommandResult(stderr: "0:12: execution error: User canceled. (-128)\n", status: 1)) == .cancelled)
        #expect(
            OSAScriptPrivilegedRunner.outcome(CommandResult(stderr: "execution error: boom (1)\n", status: 1))
                == .failed("execution error: boom (1)"))
    }

    @Test func launchFailureIsFailed() async {
        struct Boom: CommandRunner {
            func run(_ exe: String, _ args: [String]) async throws -> CommandResult {
                throw SiftError.commandLaunchFailed(executable: exe, reason: "boom")
            }
        }
        let outcome = await OSAScriptPrivilegedRunner(runner: Boom()).run(
            [PrivilegedRemoval(parent: "/p", name: "x")], forgetting: [])
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
    }

    /// Runs the real AppleScript builder and executes the command it returns with /bin/sh (no root):
    /// exactly the intended entries go, decoys stay, and receipts are forgotten only after their `rm`.
    @Test func realScriptRemovesExactlyTheGivenEntries() async throws {
        let fx = try Fixture()
        let dir = try fx.mkdir("plugins")
        for name in hostile {
            try fx.write("plugins/\(name)/inner", "x")
            try fx.write("plugins/decoy \(name)/inner", "x")
        }
        try fx.write("plugins/gone.component/x", "x")
        var removals = hostile.map { PrivilegedRemoval(parent: dir.path, name: $0) }
        removals.append(
            PrivilegedRemoval(parent: dir.path, name: "gone.component", receipt: "com.neuraldsp.GoneAU.pkg"))
        // rm can't run inside a parent that isn't where it claims: the pinned check refuses it
        try fx.write("other/keep/x", "x")
        try fx.symlink("plugins-link", to: dir.path)
        removals.append(PrivilegedRemoval(parent: fx.url("plugins-link").path, name: "decoy it's"))
        // a missing parent fails only its own subshell; its receipt stays
        removals.append(
            PrivilegedRemoval(parent: fx.url("missing").path, name: "x", receipt: "com.neuraldsp.KeepAU.pkg"))

        let args = OSAScriptPrivilegedRunner.arguments(removals, receipts: ["com.neuraldsp.LoneManual.pkg"])
        let built = try await ProcessCommandRunner().run(
            "/usr/bin/osascript", ["-e", OSAScriptPrivilegedRunner.commandOnlyScript] + args)
        #expect(built.status == 0, "\(built.stderr)")
        let command = built.stdout.trimmingCharacters(in: .newlines)
            .replacingOccurrences(of: "/usr/sbin/pkgutil --forget", with: "echo forget")
            .replacingOccurrences(of: ">/dev/null 2>&1", with: "")
        let ran = try await ProcessCommandRunner().run("/bin/sh", ["-c", command])
        #expect(ran.status == 0, "\(ran.stderr)")

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == Set(hostile.map { "decoy \($0)" }))
        #expect(!FileManager.default.fileExists(atPath: fx.url("pwned").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned").path))
        let forgotten = ran.stdout.split(separator: "\n").map(String.init)
        #expect(forgotten == ["forget com.neuraldsp.GoneAU.pkg", "forget com.neuraldsp.LoneManual.pkg"])
    }
}
