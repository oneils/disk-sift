import Foundation
import Testing

@testable import SiftCore

@Suite struct LocalSnapshotsTests {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    @Test func parsesNamesAndDatesOldestFirst() {
        let output = """
            Snapshots for disk /:
            com.apple.TimeMachine.2026-11-21-180637.local
            com.apple.TimeMachine.2026-11-20-090001.local

            """
        let snapshots = LocalSnapshots.parse(output)
        #expect(
            snapshots.map(\.name) == [
                "com.apple.TimeMachine.2026-11-20-090001.local", "com.apple.TimeMachine.2026-11-21-180637.local",
            ])
        #expect(snapshots.map(\.date) == [date(2026, 11, 20, 9, 0, 1), date(2026, 11, 21, 18, 6, 37)])
    }

    @Test func namesWithoutAStampKeepNoDateAndSortLast() {
        let snapshots = LocalSnapshots.parse(
            "Snapshots for disk /:\ncom.apple.os.update-ABC\ncom.apple.TimeMachine.2026-11-21-180637.local\n")
        #expect(snapshots.map(\.name) == ["com.apple.TimeMachine.2026-11-21-180637.local", "com.apple.os.update-ABC"])
        #expect(snapshots[1].date == nil)
    }

    @Test func headerOnlyMeansNoSnapshots() {
        #expect(LocalSnapshots.parse("Snapshots for disk /:\n").isEmpty)
        #expect(LocalSnapshots.parse("").isEmpty)
    }

    @Test func listRunsTmutilForTheVolume() async {
        let runner = FakeCommandRunner([
            "/usr/bin/tmutil listlocalsnapshots /": CommandResult(
                stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-21-180637.local\n")
        ])
        let snapshots = await LocalSnapshots.list(runner: runner)
        #expect(snapshots.count == 1)
        #expect(runner.calls == [["/usr/bin/tmutil", "listlocalsnapshots", "/"]])
    }

    @Test func failureGivesNothing() async {
        #expect(await LocalSnapshots.list(runner: FakeCommandRunner()).isEmpty)
        let failing = FakeCommandRunner([
            "/usr/bin/tmutil listlocalsnapshots /": CommandResult(
                stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-21-180637.local\n", status: 1)
        ])
        #expect(await LocalSnapshots.list(runner: failing).isEmpty)
    }
}
