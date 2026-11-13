import Foundation
import Synchronization

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
}

/// Runs one command to completion. The seam every external tool goes through (`ant`, the login-shell
/// lookup), so tests never start a real one. Honors Task cancellation by killing the process.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

/// `Process` with stdin on /dev/null, both pipes drained, and the process killed on timeout or cancel.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    private final class Box: @unchecked Sendable {
        let process = Process()
        let flags = Mutex<(timedOut: Bool, cancelled: Bool)>((false, false))
        func terminate(timedOut: Bool = false, cancelled: Bool = false) {
            flags.withLock { if timedOut { $0.timedOut = true }; if cancelled { $0.cancelled = true } }
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            // SIGTERM can be ignored; make sure it ends.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if self.process.isRunning { kill(pid, SIGKILL) } }
        }
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let box = Box()
        let timer = Task {
            try await Task.sleep(for: .seconds(timeout))
            box.terminate(timedOut: true)
        }
        defer { timer.cancel() }
        let result: CommandResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
                let p = box.process
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                p.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                let outData = Mutex(Data()), errData = Mutex(Data())
                let group = DispatchGroup()
                group.enter(); group.enter(); group.enter()
                p.terminationHandler = { _ in group.leave() }
                do { try p.run() } catch {
                    cont.resume(throwing: CommandError.launchFailed(error.localizedDescription))
                    return
                }
                let outHandle = out.fileHandleForReading, errHandle = err.fileHandleForReading
                DispatchQueue.global().async { outData.withLock { $0 = outHandle.readDataToEndOfFile() }; group.leave() }
                DispatchQueue.global().async { errData.withLock { $0 = errHandle.readDataToEndOfFile() }; group.leave() }
                group.notify(queue: .global()) {
                    cont.resume(returning: CommandResult(
                        status: box.process.terminationStatus,
                        stdout: String(decoding: outData.withLock { $0 }, as: UTF8.self),
                        stderr: String(decoding: errData.withLock { $0 }, as: UTF8.self)))
                }
            }
        } onCancel: {
            box.terminate(cancelled: true)
        }
        let f = box.flags.withLock { $0 }
        if f.cancelled { throw CancellationError() }
        if f.timedOut { throw CommandError.timedOut }
        return result
    }
}

/// Finds an installed tool: the usual absolute locations, then the login shell's PATH. Never executes
/// the tool itself, only `command -v` in a login shell.
public struct ToolLocator: Sendable {
    public var name: String
    public var home: String
    public var isExecutable: @Sendable (String) -> Bool
    public var runner: any CommandRunner

    public init(name: String, home: String = NSHomeDirectory(),
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                runner: any CommandRunner = ProcessCommandRunner()) {
        self.name = name
        self.home = home
        self.isExecutable = isExecutable
        self.runner = runner
    }

    public func find() async -> String? {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"].map { "\($0)/\(name)" }
        for c in candidates where isExecutable(c) { return c }
        guard let r = try? await runner.run("/bin/zsh", ["-lc", "command -v \(name)"], timeout: 5), r.status == 0 else { return nil }
        // Login shells can print banners first: the answer is the last absolute-path line.
        let line = r.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let line, isExecutable(line) else { return nil }
        return line
    }
}
