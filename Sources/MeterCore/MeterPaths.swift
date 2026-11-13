import Foundation

public enum MeterPaths {
    /// `METER_HOME` if set (tests, sandboxes), else `~/Library/Application Support/Meter`.
    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["METER_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Meter", isDirectory: true)
    }

    public static func databaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        home(environment: environment).appendingPathComponent("meter.db")
    }
}
