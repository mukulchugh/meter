import Foundation

public enum MeterPaths {
    /// `METER_HOME` if set (tests, sandboxes), else `$HOME/Library/Application Support/Meter` when `HOME` is
    /// in the environment, else the system Application Support folder. Honouring `HOME` keeps a temporary
    /// HOME (tests, the status line helper) from reaching the real folder.
    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["METER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let h = environment["HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true).appendingPathComponent("Library/Application Support/Meter", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Meter", isDirectory: true)
    }

    public static func databaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        home(environment: environment).appendingPathComponent("meter.db")
    }

    /// Written by `meter-statusline`, read by Meter.
    public static func claudePlanURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        home(environment: environment).appendingPathComponent("claude-plan.json")
    }

    /// Meter's own record of the Claude Code status line change (what was there before).
    public static func statusLineStateURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        home(environment: environment).appendingPathComponent("claude-statusline.json")
    }

    /// `$HOME/.claude/settings.json`: Claude Code's user settings.
    public static func claudeSettingsURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let h = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: h, isDirectory: true).appendingPathComponent(".claude/settings.json")
    }
}
