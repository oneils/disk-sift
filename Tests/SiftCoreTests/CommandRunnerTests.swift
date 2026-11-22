import Foundation
import Testing

@testable import SiftCore

@Suite struct CommandRunnerTests {
    let runner = ProcessCommandRunner()

    @Test func success() async throws {
        let result = try await runner.run("/bin/echo", ["hello", "world"])
        #expect(result == CommandResult(stdout: "hello world\n", stderr: "", status: 0))
    }

    @Test func nonZeroExitCapturesStderr() async throws {
        let result = try await runner.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
    }

    @Test func largeOutputOnBothStreams() async throws {
        // more than a pipe buffer on each stream must not deadlock
        let result = try await runner.run("/bin/sh", ["-c", "yes o | head -c 200000; yes e | head -c 200000 >&2"])
        #expect(result.status == 0)
        #expect(result.stdout.utf8.count == 200_000)
        #expect(result.stderr.utf8.count == 200_000)
    }

    @Test func missingExecutable() async {
        await #expect {
            _ = try await runner.run("/nonexistent/tool", [])
        } throws: { error in
            guard case SiftError.commandLaunchFailed(let exe, _) = error else { return false }
            return exe == "/nonexistent/tool"
        }
    }

    @Test func fakeRunnerRecordsCalls() async throws {
        let fake = FakeCommandRunner(["/usr/sbin/pkgutil --pkgs": CommandResult(stdout: "com.foo.pkg\n")])
        let hit = try await fake.run("/usr/sbin/pkgutil", ["--pkgs"])
        let miss = try await fake.run("/bin/launchctl", ["bootout", "gui/501/x"])
        #expect(hit.stdout == "com.foo.pkg\n")
        #expect(miss.status == 1)
        #expect(fake.calls == [["/usr/sbin/pkgutil", "--pkgs"], ["/bin/launchctl", "bootout", "gui/501/x"]])
    }
}
