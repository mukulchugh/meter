import Foundation
import Synchronization

/// One running `codex app-server`: newline-delimited JSON over stdio (RESEARCH.md section 13).
public protocol CodexSession: Sendable {
    /// Writes one JSON message plus a newline.
    func send(_ line: String) async throws
    /// Every line the server prints. Finishes when the server exits or the session is closed.
    var lines: AsyncStream<String> { get }
    func close() async
}

/// Starts the app-server. Throws `CodexLaunchError.notInstalled` when there is no `codex`.
public protocol CodexLauncher: Sendable {
    func launch() async throws -> any CodexSession
}

public enum CodexLaunchError: Error, Equatable, Sendable { case notInstalled, failed(String) }

/// Reads ChatGPT plan limits from the user's own Codex login through the official app-server JSON-RPC:
/// `initialize`, `initialized`, `account/read`, then `account/rateLimits/read`. Meter never reads
/// `~/.codex/auth.json` and never logs in; the user's existing Codex login is used by `codex` itself.
public struct CodexPlanSource: Sendable {
    public static let defaultTimeout: TimeInterval = 15

    private let launcher: any CodexLauncher
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date

    public init(launcher: any CodexLauncher, timeout: TimeInterval = CodexPlanSource.defaultTimeout,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.launcher = launcher
        self.timeout = timeout
        self.now = now
    }

    public func read() async -> PlanUsage {
        let session: any CodexSession
        do { session = try await launcher.launch() } catch CodexLaunchError.notInstalled {
            return result(.notInstalled, detail: "Codex is not installed.")
        } catch {
            return result(.error, detail: "Could not start Codex.")
        }
        let timeout = self.timeout
        let out = await withTaskGroup(of: PlanUsage?.self) { group in
            group.addTask { await exchange(session) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await session.close()
        return out ?? result(.error, detail: "Codex did not answer in time.")
    }

    private func result(_ state: PlanUsageState, plan: String? = nil, windows: [PlanWindow] = [], detail: String? = nil) -> PlanUsage {
        PlanUsage(provider: .chatgpt, planName: plan, windows: windows, fetchedAt: now(), state: state, detail: detail)
    }

    private func exchange(_ session: any CodexSession) async -> PlanUsage? {
        var it = session.lines.makeAsyncIterator()
        // Sends a request and waits for the reply with the same id. Notifications, log lines and replies
        // to other ids are skipped.
        func request(_ id: Int, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            try await session.send(Self.encode(["method": method, "id": id, "params": params]))
            while let line = await it.next() {
                guard let obj = Self.decode(line), (obj["id"] as? Int) == id, obj["method"] == nil else { continue }
                if obj["error"] != nil { throw RPCError() }
                return obj["result"] as? [String: Any] ?? [:]
            }
            throw RPCError()
        }
        do {
            _ = try await request(0, "initialize", ["clientInfo": ["name": "meter", "title": "Meter", "version": "1.0"]])
            try await session.send(Self.encode(["method": "initialized", "params": [String: Any]()]))
            let account = try await request(1, "account/read", ["refreshToken": false])
            guard let acct = account["account"] as? [String: Any] else {
                return result(.notLoggedIn, detail: "Codex is not signed in. Run codex login in a terminal.")
            }
            guard (acct["type"] as? String) == "chatgpt" else {
                return result(.noPlanLimits, detail: "Codex is signed in with an API key, which has no plan limits.")
            }
            let limits = try await request(2, "account/rateLimits/read", [:])
            return Self.parse(limits, accountPlan: acct["planType"] as? String, fetchedAt: now())
        } catch is CancellationError {
            return nil
        } catch {
            return result(.error, detail: "Codex returned an error reading plan limits.")
        }
    }

    private struct RPCError: Error {}

    static func encode(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decode(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return o as? [String: Any]
    }

    /// `account/rateLimits/read` result: prefers the `codex` bucket of `rateLimitsByLimitId`, else the
    /// single-bucket `rateLimits`. Windows are named from `windowDurationMins`.
    static func parse(_ result: [String: Any], accountPlan: String?, fetchedAt: Date) -> PlanUsage {
        let byId = result["rateLimitsByLimitId"] as? [String: Any]
        let bucket = (byId?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any])
        guard let bucket else {
            return PlanUsage(provider: .chatgpt, fetchedAt: fetchedAt, state: .error, detail: "Codex returned no plan limits.")
        }
        var windows = [PlanWindow]()
        for key in ["primary", "secondary"] {
            guard let w = bucket[key] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let mins = (w["windowDurationMins"] as? NSNumber)?.intValue
            let reset = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(PlanWindow(name: PlanWindow.name(forMinutes: mins), windowMinutes: mins, usedPercent: used, resetsAt: reset))
        }
        // Shortest window first, so "5-hour" precedes "weekly" whatever the server called them.
        windows.sort { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
        let plan = (bucket["planType"] as? String) ?? accountPlan
        return PlanUsage(provider: .chatgpt, planName: plan.map(planDisplayName), windows: windows, fetchedAt: fetchedAt,
                         state: windows.isEmpty ? .error : .ok,
                         detail: windows.isEmpty ? "Codex returned no usage windows." : nil)
    }

    static func planDisplayName(_ raw: String) -> String {
        switch raw {
        case "prolite": "ChatGPT Pro Lite"
        case "promax": "ChatGPT Pro Max"
        case "unknown": "ChatGPT"
        default: "ChatGPT " + raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// The real launcher: `codex app-server` over a pipe pair. Not exercised by tests.
public struct ProcessCodexLauncher: CodexLauncher {
    private let locator: ToolLocator

    public init(locator: ToolLocator = ToolLocator(name: "codex")) { self.locator = locator }

    public func launch() async throws -> any CodexSession {
        guard let path = await locator.find() else { throw CodexLaunchError.notInstalled }
        return try ProcessCodexSession(executable: path)
    }
}

final class ProcessCodexSession: CodexSession, @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    let lines: AsyncStream<String>

    init(executable: String) throws {
        // Writing to a codex that already exited must be an error, not a SIGPIPE that ends Meter.
        signal(SIGPIPE, SIG_IGN)
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let (stream, cont) = AsyncStream<String>.makeStream()
        lines = stream
        let buffer = Mutex(Data())
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                cont.finish()
                return
            }
            let complete: [Data] = buffer.withLock { b in
                b.append(d)
                var out = [Data]()
                while let i = b.firstIndex(of: 0x0A) {
                    out.append(b.subdata(in: b.startIndex..<i))
                    b.removeSubrange(b.startIndex...i)
                }
                return out
            }
            for line in complete { cont.yield(String(decoding: line, as: UTF8.self)) }
        }
        process.terminationHandler = { _ in cont.finish() }
        cont.onTermination = { _ in }
        do { try process.run() } catch { throw CodexLaunchError.failed(error.localizedDescription) }
    }

    func send(_ line: String) async throws {
        try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func close() async {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
