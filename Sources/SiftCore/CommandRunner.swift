import Foundation

/// Output of a finished external command.
public struct CommandResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var status: Int32

    public init(stdout: String = "", stderr: String = "", status: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }
}

/// Runs external commands (`pkgutil`, `launchctl`). Faked in tests.
public protocol CommandRunner: Sendable {
    func run(_ exe: String, _ args: [String]) async throws -> CommandResult
}

/// Runs commands with `Process`, capturing stdout, stderr and the exit status.
/// A non-zero exit is not an error; failing to launch throws `SiftError.commandLaunchFailed`.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ exe: String, _ args: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.runBlocking(exe, args) })
            }
        }
    }

    private static func runBlocking(_ exe: String, _ args: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw SiftError.commandLaunchFailed(executable: exe, reason: error.localizedDescription)
        }
        // drain stderr concurrently so a chatty command can't block on a full pipe
        let errData = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return CommandResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData.data, as: UTF8.self),
            status: process.terminationStatus
        )
    }
}

/// Written by one reader thread and read only after `DispatchGroup.wait()`.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
