import Foundation

/// What Meter remembers about the Claude Code status line it replaced. Lives in Meter's own folder, so
/// `meter-statusline` can chain to the previous command and "Disable" can put it back exactly.
public struct StatusLineState: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var hadPrevious: Bool
    /// The exact original text of the `statusLine` value (not re-serialised), so a restore is byte-identical.
    public var previousRaw: String?
    public var previousCommand: String?
    public var meterCommand: String
    /// Meter created `settings.json` because there was none.
    public var createdFile: Bool
    public var backupName: String?
    public var enabledAt: Double
}

public enum StatusLineError: Error, Equatable, Sendable {
    /// `settings.json` is not valid JSON, or not an object. Meter will not touch it.
    case invalidJSON
    case helperMissing
    case notEnabled
    case writeFailed(String)

    public var message: String {
        switch self {
        case .invalidJSON: "Claude Code's settings.json is not valid JSON, so Meter left it alone. Fix it, then try again."
        case .helperMissing: "The status line helper is only included in the packaged Meter app."
        case .notEnabled: "The Claude Code hook is not on."
        case .writeFailed(let m): "Could not update settings.json: \(m)"
        }
    }
}

public enum ClaudeHookStatus: Equatable, Sendable {
    case off
    case on
    /// Meter's record says on, but settings.json no longer points at the helper (someone changed it).
    case changedElsewhere
}

/// What Enable will do, shown before anything is written.
public struct StatusLineChange: Equatable, Sendable {
    public var settingsPath: String
    public var creatingFile: Bool
    /// The current `statusLine` value as written, nil when there is none.
    public var current: String?
    public var proposed: String
    public var backupName: String?
    public var alreadyEnabled: Bool

    public var summary: String {
        var lines = ["File: \(settingsPath)"]
        if creatingFile { lines.append("The file does not exist yet. Meter will create it with only the statusLine entry.") }
        else if let backupName { lines.append("A backup is saved first as \(backupName) in the same folder.") }
        if let current { lines.append("Current statusLine: \(current)") } else { lines.append("There is no statusLine today.") }
        lines.append("New statusLine: \(proposed)")
        if current != nil { lines.append("Your current status line keeps running: Meter's helper passes the same input to it and shows its output.") }
        lines.append("Every other setting stays as it is. Disable puts the original back.")
        return lines.joined(separator: "\n")
    }
}

/// Edits only the `statusLine` entry of Claude Code's `settings.json`, by splicing text, so every other
/// byte (key order, spacing, comments-in-values) stays exactly as it was.
public struct StatusLineSettings: Sendable {
    public var settingsURL: URL
    public var stateURL: URL
    public var helperPath: String
    private let now: @Sendable () -> Date

    public init(settingsURL: URL, stateURL: URL, helperPath: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settingsURL = settingsURL
        self.stateURL = stateURL
        self.helperPath = helperPath
        self.now = now
    }

    public static let helperName = "meter-statusline"

    public static func isMeterHelper(_ command: String) -> Bool {
        let t = command.trimmingCharacters(in: CharacterSet(charactersIn: "'\" \t\n"))
        return (t as NSString).lastPathComponent == helperName
    }

    /// The command as written into settings.json: the absolute path, single-quoted only when it needs it.
    var desiredCommand: String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@:")
        if helperPath.unicodeScalars.allSatisfy({ safe.contains($0) }) { return helperPath }
        return "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var desiredValue: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        let cmd = (try? enc.encode(desiredCommand)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return "{\"type\": \"command\", \"command\": \(cmd)}"
    }

    // MARK: State

    public func state() -> StatusLineState? {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(StatusLineState.self, from: $0) }
    }

    public func status() -> ClaudeHookStatus {
        guard let st = state(), st.enabled else { return .off }
        guard let data = try? Data(contentsOf: settingsURL.resolvingSymlinksInPath()),
              let top = try? JSONScan.topLevel(Array(data)),
              let m = top.members.last(where: { $0.key == "statusLine" }),
              let cmd = Self.command(inRaw: String(decoding: data[m.valueStart..<m.valueEnd], as: UTF8.self)),
              Self.isMeterHelper(cmd) else { return .changedElsewhere }
        return .on
    }

    static func command(inRaw raw: String) -> String? {
        guard let d = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) as? [String: Any] else { return nil }
        return o["command"] as? String
    }

    // MARK: Enable

    private func load() throws -> (bytes: [UInt8], existed: Bool) {
        let real = settingsURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: real.path) else { return (Array("{\n}\n".utf8), false) }
        guard let d = try? Data(contentsOf: real) else { throw StatusLineError.writeFailed("could not read the file") }
        guard (try? JSONSerialization.jsonObject(with: d)) is [String: Any] else { throw StatusLineError.invalidJSON }
        return (Array(d), true)
    }

    private func backupName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(settingsURL.lastPathComponent).meter-backup-\(f.string(from: now()))"
    }

    public func preview() throws -> StatusLineChange {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else { throw StatusLineError.helperMissing }
        let (bytes, existed) = try load()
        let top = try JSONScan.topLevel(bytes)
        let m = top.members.last { $0.key == "statusLine" }
        let current = m.map { String(decoding: bytes[$0.valueStart..<$0.valueEnd], as: UTF8.self) }
        let already = current.flatMap(Self.command(inRaw:)).map { $0 == desiredCommand && Self.isMeterHelper($0) } ?? false
        return StatusLineChange(settingsPath: settingsURL.path, creatingFile: !existed, current: current, proposed: desiredValue,
                                backupName: existed ? backupName() : nil, alreadyEnabled: already)
    }

    public func enable() throws {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else { throw StatusLineError.helperMissing }
        let (bytes, existed) = try load()
        let top = try JSONScan.topLevel(bytes)
        let m = top.members.last { $0.key == "statusLine" }
        let currentRaw = m.map { String(decoding: bytes[$0.valueStart..<$0.valueEnd], as: UTF8.self) }
        let currentCommand = currentRaw.flatMap(Self.command(inRaw:))
        let isOurs = currentCommand.map(Self.isMeterHelper) ?? false

        if isOurs, currentCommand == desiredCommand {
            // Already on: never save the helper as the "previous" command, never rewrite the file.
            if state()?.enabled != true { try writeState(hadPrevious: false, raw: nil, command: nil, created: false, backup: nil) }
            return
        }

        let newBytes: [UInt8]
        let prior = state()
        if let m {
            newBytes = JSONScan.replacing(bytes, from: m.valueStart, to: m.valueEnd, with: desiredValue)
        } else {
            newBytes = JSONScan.inserting(bytes, top: top, member: "\"statusLine\": \(desiredValue)")
        }
        try Self.verify(newBytes, command: desiredCommand)

        var backup: String?
        if existed {
            backup = backupName()
            let dir = settingsURL.resolvingSymlinksInPath().deletingLastPathComponent()
            do { try Data(bytes).write(to: dir.appendingPathComponent(backup!)) } catch { throw StatusLineError.writeFailed("could not save the backup") }
        }
        if isOurs {
            // Same helper, new location: keep what was saved before.
            try writeState(keeping: prior, command: desiredCommand)
        } else {
            try writeState(hadPrevious: m != nil, raw: currentRaw, command: currentCommand, created: !existed, backup: backup)
        }
        do { try FileAtomic.write(Data(newBytes), to: settingsURL) } catch {
            try? FileManager.default.removeItem(at: stateURL)
            throw StatusLineError.writeFailed("\(error)")
        }
    }

    // MARK: Disable

    public enum DisableOutcome: Equatable, Sendable { case restored, removed, leftAlone, nothingToDo }

    /// Puts the saved `statusLine` back exactly, or removes the key when there was none. If someone has
    /// changed `statusLine` since (it is no longer Meter's helper), it is left alone.
    @discardableResult
    public func disable() throws -> DisableOutcome {
        guard let st = state(), st.enabled else { return .nothingToDo }
        let real = settingsURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: real.path), let d = try? Data(contentsOf: real) else {
            try? FileManager.default.removeItem(at: stateURL)
            return .nothingToDo
        }
        let bytes = Array(d)
        guard let top = try? JSONScan.topLevel(bytes) else { throw StatusLineError.invalidJSON }
        guard let m = top.members.last(where: { $0.key == "statusLine" }) else {
            try? FileManager.default.removeItem(at: stateURL)
            return .nothingToDo
        }
        let raw = String(decoding: bytes[m.valueStart..<m.valueEnd], as: UTF8.self)
        guard let cmd = Self.command(inRaw: raw), Self.isMeterHelper(cmd) else {
            try? FileManager.default.removeItem(at: stateURL)
            return .leftAlone
        }
        let outcome: DisableOutcome
        var newBytes: [UInt8]
        if st.hadPrevious, let previous = st.previousRaw {
            newBytes = JSONScan.replacing(bytes, from: m.valueStart, to: m.valueEnd, with: previous)
            outcome = .restored
        } else {
            newBytes = JSONScan.removing(bytes, top: top, member: m)
            outcome = .removed
        }
        guard (try? JSONSerialization.jsonObject(with: Data(newBytes))) is [String: Any] else { throw StatusLineError.invalidJSON }
        do {
            if outcome == .removed, st.createdFile,
               let o = try? JSONSerialization.jsonObject(with: Data(newBytes)) as? [String: Any], o.isEmpty {
                try FileManager.default.removeItem(at: real)
            } else {
                try FileAtomic.write(Data(newBytes), to: settingsURL)
            }
        } catch { throw StatusLineError.writeFailed("\(error)") }
        try? FileManager.default.removeItem(at: stateURL)
        return outcome
    }

    // MARK: Helpers

    private static func verify(_ bytes: [UInt8], command: String) throws {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
              let sl = o["statusLine"] as? [String: Any], sl["command"] as? String == command, sl["type"] as? String == "command" else {
            throw StatusLineError.invalidJSON
        }
    }

    private func writeState(hadPrevious: Bool, raw: String?, command: String?, created: Bool, backup: String?) throws {
        let st = StatusLineState(enabled: true, hadPrevious: hadPrevious, previousRaw: raw, previousCommand: command,
                                 meterCommand: desiredCommand, createdFile: created, backupName: backup,
                                 enabledAt: now().timeIntervalSince1970)
        try save(st)
    }

    private func writeState(keeping prior: StatusLineState?, command: String) throws {
        var st = prior ?? StatusLineState(enabled: true, hadPrevious: false, previousRaw: nil, previousCommand: nil,
                                          meterCommand: command, createdFile: false, backupName: nil, enabledAt: now().timeIntervalSince1970)
        st.enabled = true
        st.meterCommand = command
        try save(st)
    }

    private func save(_ st: StatusLineState) throws {
        do { try FileAtomic.write(try JSONEncoder().encode(st), to: stateURL, permissions: 0o600) } catch {
            throw StatusLineError.writeFailed("could not save Meter's own settings")
        }
    }
}

/// A minimal JSON scanner: finds the byte ranges of a top-level object's members so they can be edited
/// without re-serialising the file.
enum JSONScan {
    struct Member { var key: String; var keyStart: Int; var valueStart: Int; var valueEnd: Int }
    struct Top { var open: Int; var close: Int; var members: [Member] }

    static func topLevel(_ b: [UInt8]) throws -> Top {
        var i = 0
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        func ws() { while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 } }
        func fail() -> StatusLineError { .invalidJSON }
        ws()
        guard i < b.count, b[i] == UInt8(ascii: "{") else { throw fail() }
        let open = i
        i += 1
        var members = [Member]()
        ws()
        if i < b.count, b[i] == UInt8(ascii: "}") {
            return Top(open: open, close: i, members: [])
        }
        while true {
            ws()
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail() }
            let keyStart = i
            let end = try skipString(b, i)
            let keyData = Data(b[keyStart..<end])
            guard let key = (try? JSONSerialization.jsonObject(with: keyData, options: [.fragmentsAllowed])) as? String else { throw fail() }
            i = end
            ws()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail() }
            i += 1
            ws()
            let vs = i
            i = try skipValue(b, i)
            members.append(Member(key: key, keyStart: keyStart, valueStart: vs, valueEnd: i))
            ws()
            guard i < b.count else { throw fail() }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "}") { break }
            throw fail()
        }
        return Top(open: open, close: i, members: members)
    }

    /// Index just past the string starting at `i`.
    private static func skipString(_ b: [UInt8], _ start: Int) throws -> Int {
        var i = start + 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        throw StatusLineError.invalidJSON
    }

    private static func skipValue(_ b: [UInt8], _ start: Int) throws -> Int {
        guard start < b.count else { throw StatusLineError.invalidJSON }
        var i = start
        switch b[i] {
        case UInt8(ascii: "\""): return try skipString(b, i)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "\""): i = try skipString(b, i); continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            throw StatusLineError.invalidJSON
        default:
            while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
            guard i > start else { throw StatusLineError.invalidJSON }
            return i
        }
    }

    static func replacing(_ b: [UInt8], from: Int, to: Int, with text: String) -> [UInt8] {
        Array(b[..<from]) + Array(text.utf8) + Array(b[to...])
    }

    /// Adds a member as the last one, in the file's own whitespace style. `removing` exactly undoes it.
    static func inserting(_ b: [UInt8], top: Top, member: String) -> [UInt8] {
        if let last = top.members.last, let first = top.members.first {
            let sep = String(decoding: b[(top.open + 1)..<first.keyStart], as: UTF8.self)
            return replacing(b, from: last.valueEnd, to: last.valueEnd, with: "," + sep + member)
        }
        // Empty object: the member goes right after "{", the original inner whitespace stays after it.
        return replacing(b, from: top.open + 1, to: top.open + 1, with: "\n  " + member)
    }

    static func removing(_ b: [UInt8], top: Top, member m: Member) -> [UInt8] {
        guard let idx = top.members.firstIndex(where: { $0.keyStart == m.keyStart }) else { return b }
        if idx > 0 {
            return Array(b[..<top.members[idx - 1].valueEnd]) + Array(b[m.valueEnd...])
        }
        if top.members.count == 1 {
            return Array(b[..<(top.open + 1)]) + Array(b[m.valueEnd...])
        }
        return Array(b[..<m.keyStart]) + Array(b[top.members[1].keyStart...])
    }
}
