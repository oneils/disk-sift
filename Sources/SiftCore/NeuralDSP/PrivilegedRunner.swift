import Foundation

/// One item the administrator step deletes: `rm -rf` of `name` run inside `parent`, which is pinned with
/// `cd -P` and checked with `pwd -P` first, so a parent swapped after validation can't redirect it.
public struct PrivilegedRemoval: Equatable, Sendable {
    /// Canonical (realpath'd) parent directory.
    public var parent: String
    /// Last path component.
    public var name: String
    /// Receipt forgotten only after `rm` succeeded.
    public var receipt: String?

    public init(parent: String, name: String, receipt: String? = nil) {
        self.parent = parent
        self.name = name
        self.receipt = receipt
    }
}

public enum PrivilegedOutcome: Equatable, Sendable {
    /// The command ran; what it removed is checked on disk afterwards.
    case finished
    /// The user cancelled the password prompt; nothing ran.
    case cancelled
    case failed(String)
}

/// Runs deletions and receipt removals as root after one macOS administrator password prompt.
public protocol PrivilegedRunner: Sendable {
    func run(_ removals: [PrivilegedRemoval], forgetting receipts: [String]) async -> PrivilegedOutcome
}

/// `osascript ... do shell script ... with administrator privileges`. Paths reach the shell only as
/// `osascript` arguments quoted with AppleScript's `quoted form of`, never interpolated into source.
public struct OSAScriptPrivilegedRunner: PrivilegedRunner {
    private let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// Separates removal triples from standalone receipts in argv. It can't collide with a removal's
    /// first value, which is always an absolute path; keep it in argv and never interpolate.
    static let receiptsMarker = "receipts:"

    /// Builds the shell command from argv: triples (parent, name, receipt or ""), the marker, receipts.
    /// Each removal runs in a subshell, so one failure doesn't stop the rest; `true` at the end keeps a
    /// stale `--forget` from failing the run (results are verified on disk).
    static let builder = """
        on build(argv)
        	set cmd to ""
        	set i to 1
        	set n to count of argv
        	repeat while i ≤ n
        		set a to item i of argv
        		if a is "\(receiptsMarker)" then
        			set i to i + 1
        			repeat while i ≤ n
        				set cmd to cmd & "/usr/sbin/pkgutil --forget " & quoted form of (item i of argv) & " >/dev/null 2>&1; "
        				set i to i + 1
        			end repeat
        		else
        			set p to quoted form of a
        			set seg to "(cd -P -- " & p & " && [ \\"$(pwd -P)\\" = " & p & " ] && /bin/rm -rf -- " & quoted form of (item (i + 1) of argv)
        			set r to item (i + 2) of argv
        			if r is not "" then set seg to seg & " && /usr/sbin/pkgutil --forget " & quoted form of r & " >/dev/null 2>&1"
        			set cmd to cmd & seg & "); "
        			set i to i + 3
        		end if
        	end repeat
        	return cmd & "true"
        end build
        """

    static let productionScript =
        builder + """

            on run argv
            	do shell script (my build(argv)) with administrator privileges
            end run
            """

    /// Returns the command instead of running it (tests).
    static let commandOnlyScript =
        builder + """

            on run argv
            	return my build(argv)
            end run
            """

    static func arguments(_ removals: [PrivilegedRemoval], receipts: [String]) -> [String] {
        removals.flatMap { [$0.parent, $0.name, $0.receipt ?? ""] } + [receiptsMarker] + receipts
    }

    public func run(_ removals: [PrivilegedRemoval], forgetting receipts: [String]) async -> PrivilegedOutcome {
        guard !removals.isEmpty || !receipts.isEmpty else { return .finished }
        let args = ["-e", Self.productionScript] + Self.arguments(removals, receipts: receipts)
        do {
            let result = try await runner.run("/usr/bin/osascript", args)
            return Self.outcome(result)
        } catch {
            Log.removal.error("osascript failed to launch: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    static func outcome(_ result: CommandResult) -> PrivilegedOutcome {
        if result.status == 0 { return .finished }
        // "User canceled. (-128)"
        if result.stderr.contains("-128") { return .cancelled }
        Log.removal.error("administrator step failed: \(result.stderr, privacy: .public)")
        return .failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
