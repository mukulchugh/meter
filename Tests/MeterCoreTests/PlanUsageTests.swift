import Foundation
import Synchronization
import Testing
@testable import MeterCore

// MARK: Fake Codex app-server

/// Plays the app-server: answers each request from a script, with some noise first. Never starts `codex`.
final class FakeCodexSession: CodexSession {
    private let cont: AsyncStream<String>.Continuation
    let lines: AsyncStream<String>
    private let sentLog = Mutex<[String]>([])
    private let closed = Mutex(false)
    private let respond: @Sendable (_ method: String, _ id: Int?) -> [String]

    init(respond: @escaping @Sendable (_ method: String, _ id: Int?) -> [String]) {
        (lines, cont) = AsyncStream<String>.makeStream()
        self.respond = respond
    }

    func send(_ line: String) async throws {
        sentLog.withLock { $0.append(line) }
        let obj = CodexPlanSource.decode(line) ?? [:]
        for out in respond(obj["method"] as? String ?? "", obj["id"] as? Int) { cont.yield(out) }
    }

    func close() async { closed.withLock { $0 = true }; cont.finish() }

    var methods: [String] { sentLog.withLock { $0 }.compactMap { CodexPlanSource.decode($0)?["method"] as? String } }
    var isClosed: Bool { closed.withLock { $0 } }
}

struct FakeLauncher: CodexLauncher {
    var session: FakeCodexSession?
    var error: CodexLaunchError?
    func launch() async throws -> any CodexSession {
        if let error { throw error }
        return session!
    }
}

private func reply(_ id: Int?, _ result: String) -> [String] {
    ["codex app-server starting...", #"{"method":"account/updated","params":{"authMode":"chatgpt"}}"#,
     #"{"id":\#(id ?? -1),"result":\#(result)}"#]
}

private let proLimits = """
{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1893456000},"secondary":null,"planType":"pro"},
 "rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1893400000},
   "secondary":{"usedPercent":18.5,"windowDurationMins":10080,"resetsAt":1893900000},"planType":"pro"},
   "codex_other":{"limitId":"codex_other","primary":{"usedPercent":99,"windowDurationMins":60,"resetsAt":1}}}}
"""

private func scripted(account: String, limits: String = proLimits) -> FakeCodexSession {
    FakeCodexSession { method, id in
        switch method {
        case "initialize": reply(id, #"{"userAgent":"codex/1"}"#)
        case "account/read": reply(id, account)
        case "account/rateLimits/read": reply(id, limits)
        default: []
        }
    }
}

private let t0 = utc("2026-11-13T12:00:00Z")

@Suite struct CodexPlanSourceTests {
    private func read(_ s: FakeCodexSession, timeout: TimeInterval = 5) async -> PlanUsage {
        await CodexPlanSource(launcher: FakeLauncher(session: s), timeout: timeout, now: { t0 }).read()
    }

    @Test func handshakeThenAccountThenRateLimitsInOrder() async {
        let s = scripted(account: #"{"account":{"type":"chatgpt","email":"a@b.c","planType":"pro"},"requiresOpenaiAuth":true}"#)
        let u = await read(s)
        #expect(s.methods == ["initialize", "initialized", "account/read", "account/rateLimits/read"])
        #expect(s.isClosed)
        #expect(u.provider == .chatgpt && u.state == .ok && u.fetchedAt == t0)
        #expect(u.planName == "ChatGPT Pro")
    }

    @Test func windowsAreNamedFromTheirLengthAndTheCodexBucketWins() async {
        let u = await read(scripted(account: #"{"account":{"type":"chatgpt","planType":"plus"},"requiresOpenaiAuth":true}"#))
        #expect(u.windows.map(\.name) == ["5-hour", "weekly"])
        #expect(u.windows.map(\.usedPercent) == [42, 18.5])
        #expect(u.windows[0].resetsAt == Date(timeIntervalSince1970: 1_893_400_000))
        #expect(u.windows.map(\.windowMinutes) == [300, 10_080])
    }

    @Test func aSingleBucketWithOnlyAPrimaryWindowIsNamedByItsDuration() async {
        let limits = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":15,"resetsAt":1730947200},"secondary":null},"rateLimitsByLimitId":null}"#
        let u = await read(scripted(account: #"{"account":{"type":"chatgpt","planType":"plus"}}"#, limits: limits))
        #expect(u.windows.map(\.name) == ["15-minute"])
        #expect(u.planName == "ChatGPT Plus")
        #expect(PlanWindow.name(forMinutes: nil) == "limit")
        #expect(PlanWindow.name(forMinutes: 1440) == "1-day")
    }

    @Test func notSignedInNeverAsksForLimits() async {
        let s = scripted(account: #"{"account":null,"requiresOpenaiAuth":true}"#)
        let u = await read(s)
        #expect(u.state == .notLoggedIn && u.windows.isEmpty)
        #expect(!s.methods.contains("account/rateLimits/read"))
    }

    @Test func anApiKeyLoginHasNoPlanLimits() async {
        let s = scripted(account: #"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#)
        let u = await read(s)
        #expect(u.state == .noPlanLimits)
        #expect(!s.methods.contains("account/rateLimits/read"))
        // Other account kinds (Bedrock, ...) have none either.
        let b = await read(scripted(account: #"{"account":{"type":"amazonBedrock","credentialSource":"awsManaged"},"requiresOpenaiAuth":false}"#))
        #expect(b.state == .noPlanLimits)
    }

    @Test func notInstalledAndLaunchFailures() async {
        let missing = await CodexPlanSource(launcher: FakeLauncher(error: .notInstalled), now: { t0 }).read()
        #expect(missing.state == .notInstalled)
        let broken = await CodexPlanSource(launcher: FakeLauncher(error: .failed("x")), now: { t0 }).read()
        #expect(broken.state == .error)
    }

    @Test func aServerErrorOrASilentServerIsAnErrorNotAHang() async {
        let errs = FakeCodexSession { method, id in
            method == "initialize" ? reply(id, "{}") : [#"{"id":\#(id ?? 0),"error":{"code":-32600,"message":"Not initialized"}}"#]
        }
        #expect(await read(errs).state == .error)
        let silent = FakeCodexSession { _, _ in [] }
        let started = Date()
        let u = await read(silent, timeout: 0.3)
        #expect(u.state == .error && u.detail?.contains("in time") == true)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(silent.isClosed)
    }

    @Test func repliesToOtherIdsAndNonJSONAreSkipped() async {
        let s = FakeCodexSession { method, id in
            switch method {
            case "initialize": reply(id, "{}")
            case "account/read": [#"{"id":99,"result":{"account":null}}"#, "not json at all"] + reply(id, #"{"account":{"type":"chatgpt","planType":"pro"}}"#)
            case "account/rateLimits/read": reply(id, proLimits)
            default: []
            }
        }
        #expect(await read(s).state == .ok)
    }
}

// MARK: Claude file, staleness, never summed with spend

@Suite struct ClaudePlanTests {
    private let statusLine = Data(#"{"model":{"id":"x","display_name":"Opus"},"cwd":"/p","rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1893456000},"seven_day":{"used_percentage":18,"resets_at":1893999000}}}"#.utf8)

    @Test func extractKeepsOnlyThePlanFields() throws {
        let data = try #require(ClaudePlanFile.extract(fromStatusLine: statusLine, now: t0))
        let o = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(o.keys) == ["version", "updated_at", "rate_limits", "model"])
        #expect(o["model"] as? String == "Opus")
        #expect(ClaudePlanFile.extract(fromStatusLine: Data(#"{"model":{"display_name":"Opus"}}"#.utf8), now: t0) == nil)
        #expect(ClaudePlanFile.extract(fromStatusLine: Data("garbage".utf8), now: t0) == nil)
        #expect(ClaudePlanFile.extract(fromStatusLine: Data(#"{"rate_limits":{}}"#.utf8), now: t0) == nil)
    }

    @Test func readStatesFollowTheHookAndTheFile() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("claude-plan.json")
        #expect(ClaudePlanFile.read(at: url, enabled: false, now: t0).state == .notEnabled)
        #expect(ClaudePlanFile.read(at: url, enabled: true, now: t0).state == .waiting)
        try ClaudePlanFile.extract(fromStatusLine: statusLine, now: t0)!.write(to: url)
        let u = ClaudePlanFile.read(at: url, enabled: true, now: t0.addingTimeInterval(60))
        #expect(u.state == .ok && u.provider == .claude && u.fetchedAt.timeIntervalSince1970 == t0.timeIntervalSince1970)
        #expect(u.windows.map(\.name) == ["5-hour", "weekly"] && u.windows.map(\.usedPercent) == [42.5, 18])
        try Data("{oops".utf8).write(to: url)
        #expect(ClaudePlanFile.read(at: url, enabled: true, now: t0).state == .error)
    }

    @Test func aReadingOlderThanAnHourIsStaleButKeepsItsValues() {
        let u = PlanUsage(provider: .claude, windows: [PlanWindow(name: "5-hour", windowMinutes: 300, usedPercent: 30, resetsAt: t0.addingTimeInterval(86_400))],
                          fetchedAt: t0, state: .ok)
        #expect(u.effectiveState(now: t0.addingTimeInterval(3599)) == .ok)
        #expect(u.effectiveState(now: t0.addingTimeInterval(3601)) == .stale)
        #expect(u.windows.first?.usedPercent == 30)
    }

    @Test func limitReachedAndResetPendingAreDistinctFromOk() {
        let w = { (pct: Double, reset: TimeInterval) in PlanWindow(name: "5-hour", windowMinutes: 300, usedPercent: pct, resetsAt: t0.addingTimeInterval(reset)) }
        #expect(PlanUsage(provider: .claude, windows: [w(100, 600)], fetchedAt: t0, state: .ok).effectiveState(now: t0) == .limitReached)
        #expect(PlanUsage(provider: .claude, windows: [w(100, -5)], fetchedAt: t0, state: .ok).effectiveState(now: t0) == .resetPending)
        #expect(PlanUsage(provider: .claude, windows: [w(50, 600)], fetchedAt: t0, state: .ok).effectiveState(now: t0) == .ok)
        // Stored non-ok states pass through.
        #expect(PlanUsage(provider: .chatgpt, fetchedAt: t0, state: .notLoggedIn).effectiveState(now: t0) == .notLoggedIn)
    }
}

@Suite struct PlanSeparationTests {
    @Test func planRowsRoundTripThroughTheirOwnTable() async throws {
        let store = try MeterStore.inMemory()
        let u = PlanUsage(provider: .claude, planName: "Max", windows: [PlanWindow(name: "5-hour", windowMinutes: 300, usedPercent: 42, resetsAt: t0)],
                          fetchedAt: t0, state: .ok, detail: "d")
        try await store.savePlanUsage(u)
        try await store.savePlanUsage(PlanUsage(provider: .chatgpt, fetchedAt: t0, state: .notLoggedIn))
        var again = u
        again.windows[0].usedPercent = 50
        try await store.savePlanUsage(again)
        let rows = try await store.planUsage()
        #expect(rows.count == 2)
        #expect(rows.first { $0.provider == .claude } == again)
    }

    @Test func planUsageNeverChangesAnySpendTotalOrTheCSV() async throws {
        let store = try MeterStore.inMemory()
        try await store.upsertOrg(Org(id: "a", provider: .anthropic, displayName: "A"))
        try await store.upsertCostLines([CostLine(day: day("2026-11-12"), orgId: "a", amount: dec("123.45"), feed: .anthropicAnalytics, model: "m")])
        let now = utc("2026-11-13T12:00:00Z")
        func figures(_ s: MeterSnapshot) -> [String] {
            [Fmt0.reading(s.monthToDate(now: now)), Fmt0.reading(s.today(now: now)), Fmt0.reading(s.total(from: day("2026-01-01"), to: day("2026-12-31"))),
             Export.csv(s, from: day("2026-11-01"), to: day("2026-11-30")), Export.weeklySummary(s, now: now)]
        }
        let before = figures(try await store.snapshot())
        try await store.savePlanUsage(PlanUsage(provider: .claude, planName: "Max", windows: [PlanWindow(name: "5-hour", usedPercent: 99, resetsAt: now)], fetchedAt: now, state: .ok))
        try await store.savePlanUsage(PlanUsage(provider: .chatgpt, windows: [PlanWindow(name: "weekly", usedPercent: 77)], fetchedAt: now, state: .ok))
        #expect(figures(try await store.snapshot()) == before)
        #expect(!before.joined().contains("99"))
    }

    @Test func noSpendSourceFileMentionsPlanUsage() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeterCore", isDirectory: true)
        for name in ["Queries.swift", "Snapshot.swift", "Export.swift", "Coverage.swift", "Money.swift", "SyncEngine.swift"] {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("PlanUsage") && !text.contains("plan_usage"), "\(name) must not read plan usage")
        }
        // The snapshot type has no plan field either.
        #expect(Mirror(reflecting: MeterSnapshot()).children.allSatisfy { !($0.label ?? "").lowercased().contains("plan") })
    }

    @Test func theEngineFillsBothRowsFromFakesAndNothingElse() async throws {
        let store = try MeterStore.inMemory()
        let dir = tempDir()
        let file = dir.appendingPathComponent("claude-plan.json")
        let s = scripted(account: #"{"account":{"type":"chatgpt","planType":"pro"}}"#)
        let engine = PlanUsageEngine(store: store, codex: CodexPlanSource(launcher: FakeLauncher(session: s), now: { t0 }),
                                     claudePlanURL: file, claudeHook: { .on }, now: { t0 })
        await engine.refreshAll()
        let rows = try await store.planUsage()
        #expect(rows.first { $0.provider == .chatgpt }?.state == .ok)
        #expect(rows.first { $0.provider == .claude }?.state == .waiting)
        // With no sources wired (the default), nothing is read or written.
        let empty = try MeterStore.inMemory()
        await PlanUsageEngine(store: empty).refreshAll()
        #expect(try await empty.planUsage().isEmpty)
    }

    @Test func codexRefreshIsEveryFiveMinutesWhenVisibleAndThirtyOtherwise() async throws {
        let store = try MeterStore.inMemory()
        let clock = TestClock(t0)
        let launcher = CountingLauncher()
        let engine = PlanUsageEngine(store: store, codex: CodexPlanSource(launcher: launcher, now: { clock.now }), now: { clock.now })
        await engine.refreshDue()
        #expect(launcher.launches == 1)
        clock.advance(299); await engine.refreshDue()
        #expect(launcher.launches == 1)
        await engine.setForeground(true)
        clock.advance(2); await engine.refreshDue()
        #expect(launcher.launches == 2)
        await engine.setForeground(false)
        clock.advance(1799); await engine.refreshDue()
        #expect(launcher.launches == 2)
        clock.advance(2); await engine.refreshDue()
        #expect(launcher.launches == 3)
    }
}

private final class CountingLauncher: CodexLauncher {
    private let count = Mutex(0)
    var launches: Int { count.withLock { $0 } }
    func launch() async throws -> any CodexSession {
        count.withLock { $0 += 1 }
        throw CodexLaunchError.notInstalled
    }
}

/// MeterCore's tests do not link MeterUI's `Fmt`; this is just a stable text for a reading.
private enum Fmt0 {
    static func reading(_ r: Reading) -> String { "\(r.state)-\(r.amount.map { "\($0)" } ?? "nil")" }
}
