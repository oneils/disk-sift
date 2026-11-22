import Foundation

/// An APFS local snapshot of a volume, as `tmutil listlocalsnapshots` names it.
public struct LocalSnapshot: Equatable, Sendable {
    /// e.g. `com.apple.TimeMachine.2026-11-21-180637.local`
    public var name: String
    /// Parsed from the name; nil when the name carries no `yyyy-MM-dd-HHmmss` stamp.
    public var date: Date?

    public init(name: String, date: Date?) {
        self.name = name
        self.date = date
    }
}

/// Lists local snapshots. They keep deleted files' blocks alive, so space freed by deleting shows up
/// only after macOS removes them. Listing needs no admin rights; removing them does, so DiskSift doesn't.
public enum LocalSnapshots {
    /// Snapshots of `volume`, oldest first; empty when `tmutil` fails or isn't there.
    public static func list(volume: String = "/", runner: any CommandRunner) async -> [LocalSnapshot] {
        guard let result = try? await runner.run("/usr/bin/tmutil", ["listlocalsnapshots", volume]),
            result.status == 0
        else {
            Log.command.info("tmutil listlocalsnapshots failed")
            return []
        }
        return parse(result.stdout)
    }

    /// Parses `tmutil listlocalsnapshots` output: a "Snapshots for disk /:" header, then one name per line.
    public static func parse(_ output: String) -> [LocalSnapshot] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix(":") }
            .map { LocalSnapshot(name: $0, date: date(in: $0)) }
            .sorted { ($0.date ?? .distantFuture, $0.name) < ($1.date ?? .distantFuture, $1.name) }
    }

    /// The `yyyy-MM-dd-HHmmss` stamp in a snapshot name, in local time (how `tmutil` writes it).
    static func date(in name: String) -> Date? {
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: String(name[range]))
    }
}
