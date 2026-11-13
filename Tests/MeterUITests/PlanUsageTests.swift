import Foundation
import MeterCore
import Synchronization
import Testing
@testable import MeterUI

private let utcZone = TimeZone(identifier: "UTC")!

private func window(_ name: String, _ mins: Int?, _ pct: Double, resets: String?) -> PlanWindow {
    PlanWindow(name: name, windowMinutes: mins, usedPercent: pct, resetsAt: resets.map(utc))
}

@Suite struct PlanUsageContentTests {
    private let now = utc("2026-11-13T12:00:00Z")

    private func claude(state: PlanUsageState = .ok, fetched: Date? = nil, windows: [PlanWindow]? = nil, name: String? = "Claude Max") -> PlanUsage {
        PlanUsage(provider: .claude, planName: name,
                  windows: windows ?? [window("5-hour", 300, 42.4, resets: "2026-11-13T15:10:00Z"), window("weekly", 10_080, 18, resets: "2026-11-16T09:00:00Z")],
                  fetchedAt: fetched ?? now.addingTimeInterval(-120), state: state)
    }

    @Test func popoverLineReadsLikeThePlanNotSpend() {
        let c = PlanUsageContent(plans: [claude()], now: now, timeZone: utcZone)
        let row = c.rows.first { $0.provider == .claude }!
        #expect(row.summary == "Claude Max: 5h 42%, resets 3:10 PM; weekly 18%, resets Mon 9:00 AM")
        #expect(c.popoverRows.map(\.provider) == [.claude])
        #expect(PlanLabel.basis == "Your plan, not API spend")
        #expect(row.updatedText == "Updated 2 min ago")
    }

    @Test func noRowEverShowsADollarAmount() {
        let plans = [claude(), PlanUsage(provider: .chatgpt, planName: "ChatGPT Pro", windows: [window("weekly", 10_080, 61, resets: "2026-11-15T00:00:00Z")], fetchedAt: now, state: .ok)]
        let c = PlanUsageContent(plans: plans, now: now, timeZone: utcZone)
        for r in c.rows {
            let text = ([r.summary, r.stateLabel, r.stateDetail, r.updatedText ?? ""] + r.windows.flatMap { [$0.percentText, $0.resetText ?? ""] }).joined(separator: " ")
            #expect(!text.contains("$"), "\(r.provider) text mentions money")
        }
    }

    @Test func everyStateHasItsOwnPlainWords() {
        let labels = Set([PlanUsageState.ok, .notInstalled, .notLoggedIn, .noPlanLimits, .notEnabled, .waiting, .error, .stale, .limitReached, .resetPending]
            .map { PlanUsageContent.stateInfo($0, provider: .claude).label })
        #expect(labels.count == 10)
        #expect(PlanUsageContent.stateInfo(.limitReached, provider: .chatgpt).detail.contains("not a spending cap"))
        #expect(PlanUsageContent.stateInfo(.notLoggedIn, provider: .chatgpt).label == "Disconnected")
    }

    @Test func staleKeepsTheLastValuesAndSaysHowOld() {
        let row = PlanUsageContent(plans: [claude(fetched: now.addingTimeInterval(-3 * 3600))], now: now, timeZone: utcZone).rows[0]
        #expect(row.state == .stale && row.stateLabel == "Stale")
        #expect(row.summary.contains("5h 42%") && row.summary.contains("stale, 3h ago"))
        #expect(row.windows.count == 2)
    }

    @Test func limitReachedAndResetPendingAreShown() {
        let limit = claude(windows: [window("5-hour", 300, 100, resets: "2026-11-13T15:00:00Z")])
        #expect(PlanUsageContent(plans: [limit], now: now, timeZone: utcZone).rows[0].summary.hasSuffix("(limit reached)"))
        let pending = claude(windows: [window("5-hour", 300, 100, resets: "2026-11-13T11:00:00Z")])
        let r = PlanUsageContent(plans: [pending], now: now, timeZone: utcZone).rows[0]
        #expect(r.state == .resetPending && r.summary.hasSuffix("(reset pending)") && r.windows[0].resetText == "now")
    }

    @Test func toolsThatAreNotSetUpStayOutOfThePopoverButAreInTheWindow() {
        let c = PlanUsageContent(plans: [], now: now, timeZone: utcZone)
        #expect(c.rows.map(\.provider) == [.claude, .chatgpt])
        #expect(c.rows.map(\.state) == [.notEnabled, .notInstalled])
        #expect(c.popoverRows.isEmpty)
        let codex = PlanUsage(provider: .chatgpt, fetchedAt: now, state: .notLoggedIn)
        let c2 = PlanUsageContent(plans: [codex], now: now, timeZone: utcZone)
        #expect(c2.popoverRows.map(\.summary) == ["Codex: disconnected"])
        let apiKey = PlanUsageContent(plans: [PlanUsage(provider: .chatgpt, fetchedAt: now, state: .noPlanLimits)], now: now, timeZone: utcZone)
        #expect(apiKey.rows[1].stateLabel == "No plan limits")
    }

    @Test func claudeWithoutAKnownPlanNameIsJustClaudePlan() {
        let row = PlanUsageContent(plans: [claude(name: nil)], now: now, timeZone: utcZone).rows[0]
        #expect(row.summary.hasPrefix("Claude plan: 5h 42%"))
    }
}

// MARK: Connect with Anthropic through the model

private struct EmptyClient: ProviderClient {
    var provider: Provider = .anthropic
    var maxCostWindowDays: Int { 31 }
    func fetchCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch { CostFetch(lines: [], watermark: nil) }
    func fetchEntities() async throws -> [Entity] { [] }
}

private final class StubAnt: AntAuth {
    private let state = Mutex<(logins: [String], logouts: [String], located: String?, loginError: AntError?)>(([], [], "/fake/ant", nil))
    let token = "oat-UI-SECRET-0123456789"
    init(located: String? = "/fake/ant", loginError: AntError? = nil) { state.withLock { $0.located = located; $0.loginError = loginError } }
    var logins: [String] { state.withLock { $0.logins } }
    var logouts: [String] { state.withLock { $0.logouts } }
    func locate() async -> String? { state.withLock { $0.located } }
    func accessToken(profile: String) async throws -> String { token }
    func login(profile: String) async throws {
        let e = state.withLock { s -> AntError? in s.logins.append(profile); return s.loginError }
        if let e { throw e }
    }
    func logout(profile: String) async { state.withLock { $0.logouts.append(profile) } }
}

@MainActor
private struct AntRig {
    let model: AppModel
    let store: MeterStore
    let secrets: InMemorySecrets
    let ant: StubAnt
    let seen: Seen

    final class Seen: @unchecked Sendable {
        private let m = Mutex<[(provider: Provider, credential: OrgCredential, secret: String)]>([])
        func add(_ o: Org, _ s: String) { m.withLock { $0.append((o.provider, o.credential, s)) } }
        var all: [(provider: Provider, credential: OrgCredential, secret: String)] { m.withLock { $0 } }
    }

    init(ant: StubAnt, settings: StatusLineSettings? = nil, plan: PlanUsageEngine? = nil) async throws {
        let store = try MeterStore.inMemory()
        let secrets = InMemorySecrets()
        let seen = Seen()
        let engine = SyncEngine(store: store, secrets: secrets, ant: ant, clientFactory: { org, secret in seen.add(org, secret); return EmptyClient() }, now: { t0 })
        model = AppModel(store: store, secrets: secrets, engine: engine, clock: { t0 }, ant: ant, planEngine: plan, claudeSettings: settings)
        self.store = store; self.secrets = secrets; self.ant = ant; self.seen = seen
        await model.load()
    }
}

@Suite @MainActor struct ConnectWithAnthropicTests {
    @Test func successSavesAProfileNameAndNoSecretThenRefreshesWithTheToken() async throws {
        let ant = StubAnt()
        let rig = try await AntRig(ant: ant)
        let result = await rig.model.connectWithAnthropic(displayName: "Acme")
        #expect(result.succeeded, "\(result.message)")
        let org = try #require(try await rig.store.orgs().first)
        #expect(org.displayName == "Acme" && org.provider == .anthropic)
        guard case .antProfile(let p) = org.credential else { Issue.record("not an ant org"); return }
        #expect(p.hasPrefix("meter-") && ant.logins == [p])
        // No Keychain write, and the first refresh used the token ant handed over.
        #expect(try rig.secrets.read(org.keychainRef) == nil)
        #expect(rig.seen.all.first?.secret == ant.token && rig.seen.all.first?.credential == org.credential)
        #expect(rig.model.snapshot.orgs.map(\.id) == [org.id])
    }

    @Test func aMissingAntShowsTheInstallCommandAndSavesNothing() async throws {
        let rig = try await AntRig(ant: StubAnt(located: nil, loginError: .notInstalled))
        #expect(await rig.model.antLocation() == nil)
        let r = await rig.model.connectWithAnthropic(displayName: "")
        #expect(!r.succeeded && r.message.contains("brew install anthropics/tap/ant"))
        #expect(try await rig.store.orgs().isEmpty)
    }

    @Test func cancelledTimedOutAndRefusedLoginsAreErrorsWithNoOrg() async throws {
        for (error, text) in [(AntError.cancelled, "cancelled"), (.timedOut, "timed out"),
                              (.loginFailed("Your account needs the admin role in the Console organization."), "admin role")] {
            let rig = try await AntRig(ant: StubAnt(loginError: error))
            let r = await rig.model.connectWithAnthropic(displayName: "x")
            #expect(!r.succeeded && r.state == .error && r.message.localizedCaseInsensitiveContains(text))
            #expect(try await rig.store.orgs().isEmpty)
        }
    }

    @Test func cancellingTheTaskMidLoginEndsWithCancelled() async throws {
        let rig = try await AntRig(ant: StubAnt(loginError: .cancelled))
        let task = Task { await rig.model.connectWithAnthropic(displayName: "") }
        task.cancel()
        #expect(await task.value.message == "Sign-in cancelled.")
    }

    @Test func removingAnAntOrgSignsOutItsProfileOnly() async throws {
        let ant = StubAnt()
        let rig = try await AntRig(ant: ant)
        _ = await rig.model.connectWithAnthropic(displayName: "A")
        let org = try #require(try await rig.store.orgs().first)
        await rig.model.removeOrganization(id: org.id)
        #expect(ant.logouts == [org.credential.antProfile!])
        #expect(try await rig.store.orgs().isEmpty)
        // A key org never calls ant.
        let keyOrg = Org(id: "k", provider: .anthropic, displayName: "K")
        try await rig.store.upsertOrg(keyOrg)
        await rig.model.reload()
        await rig.model.removeOrganization(id: "k")
        #expect(ant.logouts.count == 1)
    }

    @Test func signInAgainReusesTheSameProfileAndOrg() async throws {
        let ant = StubAnt()
        let rig = try await AntRig(ant: ant)
        _ = await rig.model.connectWithAnthropic(displayName: "A")
        let org = try #require(try await rig.store.orgs().first)
        let r = await rig.model.connectWithAnthropic(displayName: "", existing: org)
        #expect(r.succeeded)
        #expect(ant.logins.count == 2 && Set(ant.logins).count == 1)
        #expect(try await rig.store.orgs().count == 1)
    }

    @Test func withoutAntWiredInNothingStarts() async throws {
        let store = try MeterStore.inMemory()
        let engine = SyncEngine(store: store, secrets: InMemorySecrets(), now: { t0 })
        let model = AppModel(store: store, secrets: InMemorySecrets(), engine: engine, clock: { t0 })
        await model.load()
        let r = await model.connectWithAnthropic(displayName: "")
        #expect(!r.succeeded)
        #expect(await model.antLocation() == nil)
        #expect(model.claudeHookStatus == .off && model.planUsage.isEmpty)
    }

    @Test func staleSignInWordsReplaceKeyWordsForAntOrgs() async throws {
        let org = Org(id: "a", provider: .anthropic, displayName: "A", credential: .antProfile("meter-1"))
        let keyOrg = Org(id: "b", provider: .anthropic, displayName: "B")
        func text(_ o: Org) -> String {
            var b = Built()
            b.orgs = [o]
            b.coverage = [Coverage(orgId: o.id, source: .anthropicAnalytics, lastSuccess: t0, lastError: "x", errorKind: "auth")]
            let snap = b.snapshot
            return Freshness.text(for: snap.coverageSummary(now: t0).orgs[0], snapshot: snap, now: t0)
        }
        #expect(text(org) == "sign-in needed")
        #expect(text(keyOrg) == "key invalid")
    }
}

// MARK: Claude Code hook through the model

@Suite @MainActor struct ClaudeHookModelTests {
    private func setup() throws -> (dir: URL, settings: StatusLineSettings, file: URL) {
        let dir = tempDirectory()
        let helper = dir.appendingPathComponent("bin/meter-statusline")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let file = dir.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let s = StatusLineSettings(settingsURL: file, stateURL: dir.appendingPathComponent("meter/claude-statusline.json"), helperPath: helper.path, now: { t0 })
        return (dir, s, file)
    }

    @Test func nothingChangesUntilEnableIsClickedThenDisableRestores() async throws {
        let (dir, settings, file) = try setup()
        let original = "{\n  \"theme\": \"dark\",\n  \"statusLine\": {\"type\": \"command\", \"command\": \"echo hi\"}\n}\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let plan = PlanUsageEngine(store: try MeterStore.inMemory(), claudePlanURL: dir.appendingPathComponent("meter/claude-plan.json"),
                                   claudeHook: { settings.status() }, now: { t0 })
        let rig = try await AntRig(ant: StubAnt(), settings: settings, plan: plan)
        // Loading the model, previewing and reloading never write.
        await rig.model.reload()
        guard case .success(let change) = rig.model.previewClaudeHook() else { Issue.record("preview failed"); return }
        #expect(change.current?.contains("echo hi") == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        #expect(rig.model.claudeHookStatus == .off)

        #expect(await rig.model.enableClaudeHook() == nil)
        #expect(rig.model.claudeHookStatus == .on)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("meter-statusline"))
        #expect(await rig.model.disableClaudeHook() == nil)
        #expect(rig.model.claudeHookStatus == .off)
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test func invalidSettingsAreRefusedWithAPlainMessage() async throws {
        let (_, settings, file) = try setup()
        try "{ nope".write(to: file, atomically: true, encoding: .utf8)
        let rig = try await AntRig(ant: StubAnt(), settings: settings)
        let msg = await rig.model.enableClaudeHook()
        #expect(msg?.contains("not valid JSON") == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ nope")
        #expect(rig.model.claudeHookStatus == .off)
    }

    @Test func theSidebarHasAPlanUsageScreen() {
        #expect(SidebarItem.planUsage.title == "Plan usage")
        #expect(SidebarItem.allCases.contains(.planUsage))
    }
}

private func tempDirectory() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("meter-ui-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
