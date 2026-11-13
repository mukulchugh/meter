import Foundation
import Testing
@testable import MeterCore

private let t0 = utc("2026-11-13T12:00:00Z")

/// A temp HOME with a fake helper and the paths the code under test uses. Never the real ones.
private struct Home {
    let dir = tempDir()
    var settings: URL { dir.appendingPathComponent(".claude/settings.json") }
    var meter: URL { dir.appendingPathComponent("meter-home") }
    var state: URL { meter.appendingPathComponent("claude-statusline.json") }
    var helper: String { dir.appendingPathComponent("Meter.app/Contents/Resources/bin/meter-statusline").path }
    var env: [String: String] { ["HOME": dir.path, "METER_HOME": meter.path] }

    init() throws {
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (helper as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(toFile: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
    }

    func api(helper path: String? = nil) -> StatusLineSettings {
        StatusLineSettings(settingsURL: settings, stateURL: state, helperPath: path ?? helper, now: { t0 })
    }
    func write(_ s: String) throws { try s.write(to: settings, atomically: true, encoding: .utf8) }
    func read() throws -> String { try String(contentsOf: settings, encoding: .utf8) }
    func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: settings.deletingLastPathComponent().path).filter { $0.contains("meter-backup") }
    }
}

private func obj(_ s: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
}

@Suite struct StatusLineSettingsTests {
    private let withPrevious = """
    {
    \t"model": "opus",
      "permissions": {"allow": ["Bash(ls:*)", "Read"], "deny": []},
    \t"statusLine": { "type": "command",   "command": "~/.claude/my line.sh", "padding": 2 },
      "env": {"A": "1"},
      "zzz": [1, 2, {"k": "v}"}]
    }
    """

    @Test func enableThenDisableRestoresTheFileByteForByte() throws {
        let h = try Home()
        try h.write(withPrevious)
        let api = h.api()
        try api.enable()
        let enabled = try h.read()
        // Only the statusLine value changed: everything around it is the same bytes, in the same order.
        let before = withPrevious.components(separatedBy: #"{ "type": "command",   "command": "~/.claude/my line.sh", "padding": 2 }"#)
        #expect(before.count == 2)
        #expect(enabled.hasPrefix(before[0]) && enabled.hasSuffix(before[1]))
        let o = try obj(enabled)
        #expect((o["statusLine"] as? [String: Any])?["command"] as? String == h.helper)
        #expect((o["statusLine"] as? [String: Any])?["type"] as? String == "command")
        #expect(o["model"] as? String == "opus" && o["env"] != nil && o["zzz"] != nil)
        #expect(api.status() == .on)
        // The backup is the original, byte for byte.
        let backups = try h.backups()
        #expect(backups.count == 1 && backups[0] == "settings.json.meter-backup-20261113-120000")
        #expect(try String(contentsOf: h.settings.deletingLastPathComponent().appendingPathComponent(backups[0]), encoding: .utf8) == withPrevious)
        // Meter saved the previous entry exactly, so the helper can chain to it.
        #expect(api.state()?.previousCommand == "~/.claude/my line.sh")

        #expect(try api.disable() == .restored)
        #expect(try h.read() == withPrevious)
        #expect(api.status() == .off && api.state() == nil)
    }

    @Test(arguments: [
        "{\n  \"a\": 1,\n  \"b\": [true, null]\n}\n",
        "{\"a\":1}",
        "{}",
        "{\n}\n",
        "  {  }  ",
        "{\n\t\"only\": {\"x\": 1}\n}",
        "{\"a\": 1, \"b\": 2}\n",
    ])
    func withNoStatusLineEnableAndDisableAreExactInverses(original: String) throws {
        let h = try Home()
        try h.write(original)
        let api = h.api()
        try api.enable()
        let enabled = try obj(try h.read())
        #expect((enabled["statusLine"] as? [String: Any])?["command"] as? String == h.helper)
        let others = try obj(original)
        for (k, v) in others { #expect(NSDictionary(dictionary: [k: v]).isEqual(to: [k: enabled[k] as Any])) }
        #expect(try api.disable() == .removed)
        #expect(try h.read() == original)
    }

    @Test func aMissingFileIsCreatedThenRemovedAgain() throws {
        let h = try Home()
        let api = h.api()
        #expect(try api.preview().creatingFile)
        try api.enable()
        #expect(try (obj(try h.read())["statusLine"] as? [String: Any])?["command"] as? String == h.helper)
        #expect(try h.backups().isEmpty)
        try api.disable()
        #expect(!FileManager.default.fileExists(atPath: h.settings.path))
    }

    @Test func invalidJSONIsRefusedAndNothingIsWritten() throws {
        let h = try Home()
        for bad in ["{\"a\": 1,}", "[1,2]", "not json", "{\"a\": "] {
            try h.write(bad)
            let api = h.api()
            #expect(throws: StatusLineError.invalidJSON) { try api.enable() }
            #expect(throws: StatusLineError.invalidJSON) { try api.preview() }
            #expect(try h.read() == bad)
            #expect(try h.backups().isEmpty)
            #expect(api.state() == nil)
        }
    }

    @Test func previewWritesNothingAndSaysWhatWillChange() throws {
        let h = try Home()
        try h.write(withPrevious)
        let c = try h.api().preview()
        #expect(c.current?.contains("my line.sh") == true)
        #expect(c.proposed.contains(h.helper) && c.backupName == "settings.json.meter-backup-20261113-120000")
        #expect(c.summary.contains("Disable puts the original back"))
        #expect(!c.alreadyEnabled)
        #expect(try h.read() == withPrevious && h.api().state() == nil && (try h.backups().isEmpty))
    }

    @Test func enablingTwiceIsANoOpAndNeverSavesTheHelperAsPrevious() throws {
        let h = try Home()
        try h.write(withPrevious)
        let api = h.api()
        try api.enable()
        let once = try h.read()
        let stateOnce = api.state()
        try api.enable()
        #expect(try h.read() == once)
        #expect(api.state() == stateOnce)
        #expect(api.state()?.previousCommand == "~/.claude/my line.sh")
        #expect(try h.backups().count == 1)
        #expect(try api.preview().alreadyEnabled)
        try api.disable()
        #expect(try h.read() == withPrevious)
    }

    @Test func movingTheAppKeepsTheSavedPreviousEntry() throws {
        let h = try Home()
        try h.write(withPrevious)
        try h.api().enable()
        let moved = h.dir.appendingPathComponent("Other/meter-statusline").path
        try FileManager.default.createDirectory(atPath: (moved as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(toFile: moved, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: moved)
        let api = h.api(helper: moved)
        try api.enable()
        #expect(api.state()?.previousCommand == "~/.claude/my line.sh")
        #expect(try (obj(try h.read())["statusLine"] as? [String: Any])?["command"] as? String == moved)
        try api.disable()
        #expect(try h.read() == withPrevious)
    }

    @Test func changesMadeByClaudeCodeBetweenEnableAndDisableSurvive() throws {
        let h = try Home()
        try h.write("{\n  \"a\": 1\n}\n")
        let api = h.api()
        try api.enable()
        // Claude Code (or the user) adds a key and edits another while Meter is enabled.
        var text = try h.read()
        text = text.replacingOccurrences(of: "\"a\": 1", with: "\"a\": 2,\n  \"newKey\": true")
        try h.write(text)
        try api.disable()
        let o = try obj(try h.read())
        #expect(o["a"] as? Int == 2 && o["newKey"] as? Bool == true && o["statusLine"] == nil)
    }

    @Test func aStatusLineChangedBySomeoneElseIsLeftAlone() throws {
        let h = try Home()
        try h.write(withPrevious)
        let api = h.api()
        try api.enable()
        let mine = try h.read().replacingOccurrences(of: h.helper, with: "/usr/local/bin/their-own-line")
        try h.write(mine)
        #expect(api.status() == .changedElsewhere)
        #expect(try api.disable() == .leftAlone)
        #expect(try h.read() == mine)
        #expect(api.state() == nil)
    }

    @Test func aSymlinkedSettingsFileStaysASymlinkAndKeepsItsPermissions() throws {
        let h = try Home()
        let realDir = h.dir.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let real = realDir.appendingPathComponent("claude-settings.json")
        try "{\"a\": 1}\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: h.settings, withDestinationURL: real)
        let api = h.api()
        try api.enable()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: h.settings.path)) == real.path)
        #expect(try (obj(String(contentsOf: real, encoding: .utf8))["statusLine"] as? [String: Any])?["command"] as? String == h.helper)
        #expect((try FileManager.default.attributesOfItem(atPath: real.path))[.posixPermissions] as? Int == 0o600)
        // The backup sits beside the real file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: realDir.path).contains { $0.contains("meter-backup") })
        try api.disable()
        #expect(try String(contentsOf: real, encoding: .utf8) == "{\"a\": 1}\n")
        #expect((try FileManager.default.attributesOfItem(atPath: real.path))[.posixPermissions] as? Int == 0o600)
    }

    @Test func noHelperMeansNothingIsTouched() throws {
        let h = try Home()
        try h.write("{}")
        let api = h.api(helper: h.dir.appendingPathComponent("nope/meter-statusline").path)
        #expect(throws: StatusLineError.helperMissing) { try api.enable() }
        #expect(throws: StatusLineError.helperMissing) { try api.preview() }
        #expect(try h.read() == "{}" && api.state() == nil)
    }

    @Test func pathsWithSpacesAreQuotedForTheShell() throws {
        let h = try Home()
        let spaced = h.dir.appendingPathComponent("My Apps/meter-statusline").path
        try FileManager.default.createDirectory(atPath: (spaced as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(toFile: spaced, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spaced)
        try h.write("{}")
        let api = h.api(helper: spaced)
        try api.enable()
        let cmd = try #require((try obj(try h.read())["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(cmd == "'\(spaced)'" && StatusLineSettings.isMeterHelper(cmd))
        #expect(api.status() == .on)
        try api.disable()
        #expect(try h.read() == "{}")
    }

    @Test func theRealSettingsFileIsNeverNamedByTheDefaults() {
        // Paths come from the environment given, so a temp HOME can never reach the real one.
        let url = MeterPaths.claudeSettingsURL(environment: ["HOME": "/tmp/fake-home"])
        #expect(url.path == "/tmp/fake-home/.claude/settings.json")
        #expect(MeterPaths.claudePlanURL(environment: ["HOME": "/tmp/fake-home"]).path == "/tmp/fake-home/Library/Application Support/Meter/claude-plan.json")
        #expect(MeterPaths.claudePlanURL(environment: ["HOME": "/tmp/h", "METER_HOME": "/tmp/m"]).path == "/tmp/m/claude-plan.json")
    }
}

@Suite struct StatuslineHelperTests {
    private let input = Data(#"{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42.4,"resets_at":1893456000},"seven_day":{"used_percentage":18,"resets_at":1893999000}}}"#.utf8)

    private func savePrevious(_ h: Home, _ command: String?) throws {
        let st = StatusLineState(enabled: true, hadPrevious: command != nil, previousRaw: nil, previousCommand: command,
                                 meterCommand: h.helper, createdFile: false, backupName: nil, enabledAt: 0)
        try FileManager.default.createDirectory(at: h.meter, withIntermediateDirectories: true)
        try JSONEncoder().encode(st).write(to: h.state)
    }

    @Test func stdinBecomesTheAtomicPlanFileInTheTempHome() throws {
        let h = try Home()
        let out = StatuslineHelper.run(stdin: input, environment: h.env, now: t0)
        #expect(String(decoding: out, as: UTF8.self) == "Opus 5h 42% 7d 18%\n")
        let file = h.meter.appendingPathComponent("claude-plan.json")
        let u = ClaudePlanFile.read(at: file, enabled: true, now: t0)
        #expect(u.state == .ok && u.windows.map(\.usedPercent) == [42.4, 18])
        #expect(u.windows[0].resetsAt == Date(timeIntervalSince1970: 1_893_456_000))
        // No temp files left behind, and the file is private.
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.meter.path) == ["claude-plan.json"])
        #expect((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int == 0o600)
        // The real Application Support folder was never involved.
        #expect(!file.path.contains("Application Support/Meter") || file.path.hasPrefix(h.dir.path))
    }

    @Test func aStatusLineWithoutLimitsKeepsTheLastGoodFile() throws {
        let h = try Home()
        _ = StatuslineHelper.run(stdin: input, environment: h.env, now: t0)
        let file = h.meter.appendingPathComponent("claude-plan.json")
        let before = try Data(contentsOf: file)
        let out = StatuslineHelper.run(stdin: Data(#"{"model":{"display_name":"Sonnet"}}"#.utf8), environment: h.env, now: t0.addingTimeInterval(500))
        #expect(String(decoding: out, as: UTF8.self) == "Sonnet\n")
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func thePreviousCommandGetsTheSameStdinAndItsOutputIsShown() throws {
        let h = try Home()
        try savePrevious(h, "cat")
        let out = StatuslineHelper.run(stdin: input, environment: h.env, now: t0)
        #expect(out == input)
        try savePrevious(h, "printf 'my line\\n'; cat >/dev/null")
        #expect(String(decoding: StatuslineHelper.run(stdin: input, environment: h.env, now: t0), as: UTF8.self) == "my line\n")
        // The plan file is still written when chaining.
        #expect(FileManager.default.fileExists(atPath: h.meter.appendingPathComponent("claude-plan.json").path))
    }

    @Test func aFailingOrSlowPreviousCommandNeverBlanksTheStatusLine() throws {
        let h = try Home()
        try savePrevious(h, "exit 3")
        #expect(String(decoding: StatuslineHelper.run(stdin: input, environment: h.env, now: t0), as: UTF8.self) == "Opus 5h 42% 7d 18%\n")
        try savePrevious(h, "echo; true")
        // A previous command that prints nothing useful falls back to the minimal line.
        let blank = String(decoding: StatuslineHelper.run(stdin: input, environment: h.env, now: t0), as: UTF8.self)
        #expect(blank.contains("Opus") || blank == "\n")
    }

    @Test func itNeverChainsToItselfSoThereIsNoForkLoop() throws {
        let h = try Home()
        try savePrevious(h, "/Applications/Meter.app/Contents/Resources/bin/meter-statusline")
        #expect(String(decoding: StatuslineHelper.run(stdin: input, environment: h.env, now: t0), as: UTF8.self) == "Opus 5h 42% 7d 18%\n")
        try savePrevious(h, "'/Users/x/My Apps/meter-statusline'")
        #expect(StatuslineHelper.previousCommand(environment: h.env) == nil)
    }

    @Test func garbageInAndAnUnwritableFolderStillPrintAndNeverThrow() throws {
        let h = try Home()
        #expect(String(decoding: StatuslineHelper.run(stdin: Data("\u{0}not json".utf8), environment: h.env, now: t0), as: UTF8.self) == "Claude\n")
        #expect(StatuslineHelper.run(stdin: Data(), environment: h.env, now: t0).isEmpty == false)
        // METER_HOME is a file, so the folder cannot be created.
        let blocker = h.dir.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let env = ["HOME": h.dir.path, "METER_HOME": blocker.path]
        #expect(String(decoding: StatuslineHelper.run(stdin: input, environment: env, now: t0), as: UTF8.self) == "Opus 5h 42% 7d 18%\n")
        // No HOME at all.
        _ = StatuslineHelper.run(stdin: input, environment: ["METER_HOME": h.meter.path], now: t0)
    }

    @Test func theHelperTargetIsAThreeLineMain() throws {
        let main = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeterStatusline/main.swift")
        let code = try String(contentsOf: main, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(code.count <= 5)
    }
}
