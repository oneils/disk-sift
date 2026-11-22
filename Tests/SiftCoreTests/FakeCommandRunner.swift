import Foundation
import os

@testable import SiftCore

/// Returns canned results keyed by the full command line ("exe arg1 arg2") and records every call.
final class FakeCommandRunner: CommandRunner {
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        var results: [String: CommandResult]
        var calls: [[String]] = []
    }

    /// Result for commands without a canned entry.
    let fallback: CommandResult

    init(_ results: [String: CommandResult] = [:], fallback: CommandResult = CommandResult(status: 1)) {
        state = OSAllocatedUnfairLock(initialState: State(results: results))
        self.fallback = fallback
    }

    var calls: [[String]] {
        state.withLock { $0.calls }
    }

    func set(_ commandLine: String, _ result: CommandResult) {
        state.withLock { $0.results[commandLine] = result }
    }

    func run(_ exe: String, _ args: [String]) async throws -> CommandResult {
        let key = ([exe] + args).joined(separator: " ")
        let fallback = fallback
        return state.withLock { state in
            state.calls.append([exe] + args)
            return state.results[key] ?? fallback
        }
    }
}
