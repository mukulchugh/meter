import Foundation
import Synchronization

/// The file `meter-statusline` writes and Meter reads: `claude-plan.json` (RESEARCH.md section 13).
/// Claude Code pipes `rate_limits` to its status line only for claude.ai Pro, Max and Ultra, only after
/// the first API response of a session, so the file is as fresh as the last Claude Code session.
public enum ClaudePlanFile {
    /// Pulls the plan fields out of the status line JSON. Returns nil when there is no `rate_limits` window
    /// to record. `now` stamps `updated_at`.
    public static func extract(fromStatusLine stdin: Data, now: Date) -> Data? {
        guard let root = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        var rate = [String: Any]()
        for key in ["five_hour", "seven_day"] {
            guard let w = limits[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            var entry: [String: Any] = ["used_percentage": used]
            if let r = (w["resets_at"] as? NSNumber)?.doubleValue { entry["resets_at"] = r }
            rate[key] = entry
        }
        guard !rate.isEmpty else { return nil }
        var out: [String: Any] = ["version": 1, "updated_at": now.timeIntervalSince1970, "rate_limits": rate]
        if let name = (root["model"] as? [String: Any])?["display_name"] as? String { out["model"] = name }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// Reads the file. `enabled` is whether Meter's status line hook is on.
    public static func read(at url: URL, enabled: Bool, now: Date) -> PlanUsage {
        guard let data = try? Data(contentsOf: url) else {
            return PlanUsage(provider: .claude, fetchedAt: now, state: enabled ? .waiting : .notEnabled,
                             detail: enabled ? "Waiting for a Claude Code session to report." : "Turn on the Claude Code hook in Settings.")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let updated = (root["updated_at"] as? NSNumber)?.doubleValue,
              let rate = root["rate_limits"] as? [String: Any] else {
            return PlanUsage(provider: .claude, fetchedAt: now, state: .error, detail: "Meter could not read the Claude Code plan file.")
        }
        var windows = [PlanWindow]()
        for (key, name, mins) in [("five_hour", "5-hour", 300), ("seven_day", "weekly", 10_080)] {
            guard let w = rate[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(PlanWindow(name: name, windowMinutes: mins, usedPercent: used, resetsAt: reset))
        }
        return PlanUsage(provider: .claude, planName: nil, windows: windows, fetchedAt: Date(timeIntervalSince1970: updated),
                         state: windows.isEmpty ? .waiting : .ok,
                         detail: (root["model"] as? String).map { "Last model: \($0)" })
    }
}

/// The status line helper's logic, kept in the library so tests need no built binary. `main` is three lines.
public enum StatuslineHelper {
    /// Records the plan fields, then prints either the user's previous status line output or a minimal line.
    /// Never throws and never exits non-zero: a failing helper would blank the user's status line.
    public static func run(stdin: Data, environment: [String: String], now: Date = Date()) -> Data {
        // A previous command that ignores its stdin would otherwise kill this process with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let env = environment
        if let data = ClaudePlanFile.extract(fromStatusLine: stdin, now: now) {
            try? FileAtomic.write(data, to: MeterPaths.claudePlanURL(environment: env), permissions: 0o600)
        }
        if let previous = previousCommand(environment: env), let out = runPrevious(previous, stdin: stdin), !out.isEmpty {
            return out
        }
        return Data((minimalLine(stdin) + "\n").utf8)
    }

    static func minimalLine(_ stdin: Data) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any] else { return "Claude" }
        var parts = [((root["model"] as? [String: Any])?["display_name"] as? String) ?? "Claude"]
        if let rl = root["rate_limits"] as? [String: Any] {
            if let p = ((rl["five_hour"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue { parts.append("5h \(Int(p.rounded()))%") }
            if let p = ((rl["seven_day"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue { parts.append("7d \(Int(p.rounded()))%") }
        }
        return parts.joined(separator: " ")
    }

    /// The command Meter saved from before it took over the status line. Never Meter's own helper.
    static func previousCommand(environment: [String: String]) -> String? {
        guard let data = try? Data(contentsOf: MeterPaths.statusLineStateURL(environment: environment)),
              let state = try? JSONDecoder().decode(StatusLineState.self, from: data),
              let cmd = state.previousCommand, !cmd.isEmpty, !StatusLineSettings.isMeterHelper(cmd) else { return nil }
        return cmd
    }

    /// `/bin/sh -c <command>` with the same stdin, output captured, killed after 5 seconds.
    static func runPrevious(_ command: String, stdin: Data) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        let output = Mutex(Data())
        DispatchQueue.global().async { output.withLock { $0 = outPipe.fileHandleForReading.readDataToEndOfFile() }; done.signal() }
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? output.withLock { $0 } : nil
    }
}

enum FileAtomic {
    /// Writes beside the target and renames over it, so a reader never sees half a file. Follows a symlink
    /// to the real file first and keeps its permissions.
    static func write(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).meter-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: existing ?? permissions ?? 0o644], ofItemAtPath: tmp.path)
        if rename(tmp.path, target.path) != 0 {
            let err = errno
            try? fm.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
    }
}
