import Foundation
import Synchronization
import Testing
@testable import MeterCore

/// Scripted command runner: records every call, never starts a process.
final class FakeRunner: CommandRunner {
    struct Call: Equatable { let exe: String; let args: [String] }
    private let log = Mutex<[Call]>([])
    private let handler: @Sendable (String, [String]) throws -> CommandResult

    init(_ handler: @escaping @Sendable (String, [String]) throws -> CommandResult) { self.handler = handler }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        log.withLock { $0.append(Call(exe: executable, args: arguments)) }
        return try handler(executable, arguments)
    }

    var calls: [Call] { log.withLock { $0 } }
}

private let token = "oat-SECRET-token-0123456789"

private func antCLI(runner: FakeRunner, installed: Bool = true, configDir: URL? = nil) -> AntCLI {
    var env = ["HOME": "/nonexistent-home"]
    if let configDir { env["ANTHROPIC_CONFIG_DIR"] = configDir.path }
    let locator = ToolLocator(name: "ant", home: "/nonexistent-home", isExecutable: { installed && $0 == "/opt/homebrew/bin/ant" }, runner: runner)
    return AntCLI(runner: runner, locator: locator, environment: env)
}

@Suite struct AntCLITests {
    @Test func locatorChecksKnownFoldersThenTheLoginShell() async {
        let seen = Mutex<[String]>([])
        let runner = FakeRunner { _, _ in CommandResult(status: 1) }
        let locator = ToolLocator(name: "ant", home: "/Users/x", isExecutable: { p in seen.withLock { $0.append(p) }; return p == "/Users/x/.local/bin/ant" }, runner: runner)
        #expect(await locator.find() == "/Users/x/.local/bin/ant")
        #expect(seen.withLock { $0 } == ["/opt/homebrew/bin/ant", "/usr/local/bin/ant", "/Users/x/.local/bin/ant"])
        #expect(runner.calls.isEmpty)
    }

    @Test func locatorFallsBackToTheLoginShellAndTakesTheLastPathLine() async {
        let runner = FakeRunner { exe, args in
            #expect(exe == "/bin/zsh"); #expect(args == ["-lc", "command -v ant"])
            return CommandResult(status: 0, stdout: "Welcome back\n/opt/custom/ant\n")
        }
        let locator = ToolLocator(name: "ant", home: "/Users/x", isExecutable: { $0 == "/opt/custom/ant" }, runner: runner)
        #expect(await locator.find() == "/opt/custom/ant")
        // A shell function or alias answer is not a path: not installed.
        let alias = FakeRunner { _, _ in CommandResult(status: 0, stdout: "alias ant=thing\n") }
        let l2 = ToolLocator(name: "ant", home: "/Users/x", isExecutable: { _ in false }, runner: alias)
        #expect(await l2.find() == nil)
    }

    @Test func missingAntIsReportedAsNotInstalled() async {
        let cli = antCLI(runner: FakeRunner { _, _ in CommandResult(status: 1) }, installed: false)
        await #expect(throws: AntError.notInstalled) { try await cli.accessToken(profile: "meter-abc") }
        await #expect(throws: AntError.notInstalled) { try await cli.login(profile: "meter-abc") }
    }

    @Test func accessTokenUsesPrintCredentialsForTheProfileAndTrimsOutput() async throws {
        let runner = FakeRunner { _, _ in CommandResult(status: 0, stdout: "\(token)\n") }
        let t = try await antCLI(runner: runner).accessToken(profile: "meter-abc")
        #expect(t == token)
        #expect(runner.calls == [.init(exe: "/opt/homebrew/bin/ant", args: ["auth", "print-credentials", "--profile", "meter-abc", "--access-token"])])
    }

    @Test func failuresAndJunkOutputMeanSignInAgain() async {
        // ant exits 0 with whatever token it has when a refresh fails, and prints errors to stderr; an empty
        // answer, a non-zero exit, or text that is not one token must never be used as a bearer token.
        for result in [CommandResult(status: 1, stdout: "", stderr: "not logged in"),
                       CommandResult(status: 0, stdout: "\n"),
                       CommandResult(status: 0, stdout: "warning: token expired and refresh failed\n"),
                       CommandResult(status: 1, stdout: "\(token)\n")] {
            let cli = antCLI(runner: FakeRunner { _, _ in result })
            await #expect(throws: AntError.notSignedIn) { try await cli.accessToken(profile: "p") }
        }
    }

    @Test func aSlowAntIsATimeoutNotAHang() async {
        let cli = antCLI(runner: FakeRunner { _, _ in throw CommandError.timedOut })
        await #expect(throws: AntError.timedOut) { try await cli.accessToken(profile: "p") }
    }

    @Test func loginAsksForTheAdminScopeAndPutsTheUsersActiveProfileBack() async throws {
        let dir = tempDir()
        try "work\n".write(to: dir.appendingPathComponent("active_config"), atomically: true, encoding: .utf8)
        let runner = FakeRunner { _, _ in CommandResult(status: 0, stderr: "Logged in") }
        try await antCLI(runner: runner, configDir: dir).login(profile: "meter-abc")
        #expect(runner.calls.map(\.args) == [["auth", "login", "--profile", "meter-abc", "--scope", "org:admin"], ["profile", "activate", "work"]])
    }

    @Test func withNoPreviousProfileTheDefaultIsRestored() async throws {
        let runner = FakeRunner { _, _ in CommandResult(status: 0) }
        try await antCLI(runner: runner, configDir: tempDir()).login(profile: "meter-abc")
        #expect(runner.calls.last?.args == ["profile", "activate", "default"])
    }

    @Test func aCancelledLoginThrowsCancelledAndStillRestoresTheActiveProfile() async throws {
        let runner = FakeRunner { _, args in
            if args.first == "auth" { throw CancellationError() }
            return CommandResult(status: 0)
        }
        let cli = antCLI(runner: runner, configDir: tempDir())
        let task = Task { try await cli.login(profile: "meter-abc") }
        task.cancel()
        await #expect(throws: AntError.cancelled) { try await task.value }
        #expect(runner.calls.last?.args == ["profile", "activate", "default"])
    }

    @Test func loginTimeoutAndRefusalsAreMappedToPlainStates() async {
        let slow = antCLI(runner: FakeRunner { _, args in
            if args.first == "auth" { throw CommandError.timedOut }
            return CommandResult(status: 0)
        }, configDir: tempDir())
        await #expect(throws: AntError.timedOut) { try await slow.login(profile: "p") }

        let failed = antCLI(runner: FakeRunner { _, args in
            args.first == "auth" ? CommandResult(status: 1, stderr: "denied") : CommandResult(status: 0)
        }, configDir: tempDir())
        await #expect(throws: AntError.loginFailed("Sign-in did not finish. Try again.")) { try await failed.login(profile: "p") }

        let notAdmin = antCLI(runner: FakeRunner { _, _ in
            CommandResult(status: 0, stderr: "⚠  org:admin was requested but not granted (granted: user:profile)")
        }, configDir: tempDir())
        await #expect(throws: AntError.loginFailed("Your account needs the admin role in the Console organization.")) {
            try await notAdmin.login(profile: "p")
        }
    }

    @Test func logoutRunsForThatProfileOnly() async {
        let runner = FakeRunner { _, _ in CommandResult(status: 0) }
        await antCLI(runner: runner).logout(profile: "meter-abc")
        #expect(runner.calls.map(\.args) == [["auth", "logout", "--profile", "meter-abc"]])
    }

    @Test func profileNamesAreMeterPlusShortId() {
        let n = AntCommand.newProfileName()
        #expect(n.hasPrefix("meter-") && n.count == 14)
        #expect(n != AntCommand.newProfileName())
    }
}

// MARK: Sync with an ant org

final class FakeAnt: AntAuth {
    private let state = Mutex<(tokenCalls: Int, logouts: [String], error: AntError?)>((0, [], nil))
    let token: String
    init(token: String = "oat-SECRET-token-0123456789", error: AntError? = nil) {
        self.token = token
        state.withLock { $0.error = error }
    }
    var tokenCalls: Int { state.withLock { $0.tokenCalls } }
    var logouts: [String] { state.withLock { $0.logouts } }
    func locate() async -> String? { "/fake/ant" }
    func accessToken(profile: String) async throws -> String {
        let e = state.withLock { s -> AntError? in s.tokenCalls += 1; return s.error }
        if let e { throw e }
        return token
    }
    func login(profile: String) async throws {}
    func logout(profile: String) async { state.withLock { $0.logouts.append(profile) } }
}

@Sendable private func okAPI(_ r: HTTPRequest) -> HTTPResponse {
    switch r.path {
    case "/v1/organizations/analytics/cost":
        return json(#"{"data":[],"has_more":false,"next_page":null,"data_refreshed_at":"2026-11-13T09:00:00Z"}"#)
    case "/v1/organizations/cost_report": return json(#"{"data":[],"has_more":false,"next_page":null}"#)
    case "/v1/organizations/usage_report/claude_code": return json(#"{"data":[],"has_more":false}"#)
    default: return json(#"{"data":[],"has_more":false}"#)
    }
}

@Suite struct AntSyncTests {
    private let now = utc("2026-11-13T12:00:00Z")
    private let org = Org(id: "org-ant", provider: .anthropic, displayName: "Acme", credential: .antProfile("meter-abc12345"))

    private func rig(ant: FakeAnt, store: MeterStore? = nil, handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse = okAPI)
        async throws -> (engine: SyncEngine, transport: FakeTransport, secrets: InMemorySecrets, store: MeterStore) {
        let store = try store ?? MeterStore.inMemory()
        let secrets = InMemorySecrets()
        let transport = FakeTransport(handler)
        let now = now
        let engine = SyncEngine(store: store, secrets: secrets, ant: ant, clientFactory: defaultClientFactory(transport: transport), now: { now })
        try await store.upsertOrg(org)
        return (engine, transport, secrets, store)
    }

    @Test func requestsCarryABearerTokenAndNoApiKeyHeader() async throws {
        let ant = FakeAnt()
        let r = try await rig(ant: ant)
        let report = await r.engine.refresh(org: org)
        #expect(report.outcomes.values.allSatisfy { if case .updated = $0 { true } else { false } })
        #expect(!r.transport.requests.isEmpty)
        for req in r.transport.requests {
            #expect(req.headers["authorization"] == "Bearer \(ant.token)")
            #expect(req.headers["x-api-key"] == nil)
            #expect(req.headers["anthropic-version"] != nil)
        }
        // The analytics beta header still rides along on the analytics endpoint.
        #expect(r.transport.requests(path: "/v1/organizations/analytics/cost").first?.headers["anthropic-beta"] != nil)
        #expect(ant.tokenCalls == 1)
        // Nothing went to the Keychain stand-in.
        #expect(try r.secrets.read(org.keychainRef) == nil)
    }

    @Test func theTokenIsNeverPersisted() async throws {
        let dir = tempDir()
        let ant = FakeAnt()
        let store = try MeterStore(url: dir.appendingPathComponent("meter.db"))
        let r = try await rig(ant: ant, store: store)
        _ = await r.engine.refresh(org: org)
        // A failing pass writes coverage errors; make one too.
        let failing = try await rig(ant: FakeAnt(token: ant.token), store: store) { _ in HTTPResponse(status: 401) }
        _ = await failing.engine.refresh(org: org)
        let needle = Data(ant.token.utf8)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent == "meter.db" })
        for f in files {
            let bytes = try Data(contentsOf: f)
            #expect(bytes.range(of: needle) == nil, "\(f.lastPathComponent) contains the access token")
        }
        let snap = try await store.snapshot()
        #expect(snap.coverage.allSatisfy { ($0.lastError ?? "").contains(ant.token) == false })
        #expect(try await store.orgs().first?.credential == .antProfile("meter-abc12345"))
    }

    @Test func aMissingAntFailsWithTheInstallCommandAndSendsNothing() async throws {
        let r = try await rig(ant: FakeAnt(error: .notInstalled))
        let report = await r.engine.refresh(org: org)
        let err = ProviderError.auth(.antMissing, .anthropic)
        #expect(report.outcomes.values.allSatisfy { $0 == .failed(err) })
        #expect(err.message.contains("brew install anthropics/tap/ant"))
        #expect(r.transport.requests.isEmpty)
    }

    @Test func notSignedInAndNoAntAtAllReadAsSignInAgain() async throws {
        let r = try await rig(ant: FakeAnt(error: .notSignedIn))
        let report = await r.engine.refresh(org: org)
        #expect(report.outcomes[.anthropicAnalytics] == .failed(.auth(.notSignedIn, .anthropic)))
        #expect(ProviderError.auth(.notSignedIn, .anthropic).message.contains("Sign in again"))
        // An engine built without any ant behaves the same, and never starts anything.
        let bare = SyncEngine(store: r.store, secrets: InMemorySecrets(), now: { now })
        #expect(await bare.refresh(org: org).outcomes[.anthropicAnalytics] == .failed(.auth(.notSignedIn, .anthropic)))
    }

    @Test func authErrorsUseSignInWordsNotKeyWords() async throws {
        let r401 = try await rig(ant: FakeAnt()) { _ in HTTPResponse(status: 401) }
        #expect(await r401.engine.refresh(org: org).outcomes[.anthropicAnalytics] == .failed(.auth(.signInExpired, .anthropic)))
        let r403 = try await rig(ant: FakeAnt()) { _ in HTTPResponse(status: 403) }
        let out = await r403.engine.refresh(org: org).outcomes[.anthropicAnalytics]
        #expect(out == .failed(.auth(.needsAdminRole, .anthropic)))
        #expect(ProviderError.auth(.needsAdminRole, .anthropic).message.contains("needs the admin role in the Console organization"))
        // A key org keeps its old wording.
        #expect(ProviderError.map(status: 401, headers: [:], body: Data(), provider: .anthropic, looksAdmin: true) == .auth(.invalidKey, .anthropic))
    }

    @Test func theBackgroundTickDoesNotStartAntWhenNothingIsDue() async throws {
        let ant = FakeAnt()
        let r = try await rig(ant: ant)
        _ = await r.engine.refresh(org: org)
        #expect(ant.tokenCalls == 1)
        await r.engine.syncDue()
        await r.engine.syncDue()
        #expect(ant.tokenCalls == 1)
    }

    @Test func keyOrgsNeverTouchAnt() async throws {
        let ant = FakeAnt()
        let store = try MeterStore.inMemory()
        let secrets = InMemorySecrets()
        let keyOrg = Org(id: "k", provider: .anthropic, displayName: "Key org")
        try await store.upsertOrg(keyOrg)
        try secrets.write("sk-ant-admin01-test", for: keyOrg.keychainRef)
        let transport = FakeTransport(okAPI)
        let engine = SyncEngine(store: store, secrets: secrets, ant: ant, clientFactory: defaultClientFactory(transport: transport), now: { now })
        _ = await engine.refresh(org: keyOrg)
        #expect(ant.tokenCalls == 0)
        #expect(transport.requests.allSatisfy { $0.headers["x-api-key"] == "sk-ant-admin01-test" && $0.headers["authorization"] == nil })
    }

    @Test func credentialRawFormRoundTrips() {
        #expect(OrgCredential(raw: "key") == .apiKey)
        #expect(OrgCredential(raw: "ant:meter-1") == .antProfile("meter-1"))
        #expect(OrgCredential(raw: "ant:") == .apiKey)
        #expect(OrgCredential.antProfile("p").raw == "ant:p")
    }
}

/// The real process runner, on harmless system commands only (never `ant` or `codex`).
@Suite struct ProcessCommandRunnerTests {
    @Test func capturesBothStreamsAndTheStatusWithStdinClosed() async throws {
        let r = try await ProcessCommandRunner().run("/bin/sh", ["-c", "echo out; echo err 1>&2; cat; exit 3"], timeout: 5)
        #expect(r == CommandResult(status: 3, stdout: "out\n", stderr: "err\n"))
    }

    @Test func aHungCommandIsKilledAtTheTimeout() async {
        let started = Date()
        await #expect(throws: CommandError.timedOut) { try await ProcessCommandRunner().run("/bin/sleep", ["30"], timeout: 0.3) }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func cancellingTheTaskKillsTheCommand() async {
        let task = Task { try await ProcessCommandRunner().run("/bin/sleep", ["30"], timeout: 60) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let started = Date()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aMissingExecutableIsALaunchFailure() async {
        await #expect(throws: CommandError.self) { try await ProcessCommandRunner().run("/nonexistent/tool", [], timeout: 2) }
    }

    @Test func largeOutputDoesNotDeadlockThePipes() async throws {
        let r = try await ProcessCommandRunner().run("/bin/sh", ["-c", "yes x | head -c 300000"], timeout: 10)
        #expect(r.stdout.count == 300_000 && r.status == 0)
    }
}
