import Foundation
import Testing
@testable import MeterCore

@Suite struct StoreTests {
    private func line(_ d: String, _ amount: String, model: String? = "m", key: String? = nil, feed: CostFeed = .anthropicAnalytics,
                      source: CostSource = .reported, org: String = "a") -> CostLine {
        CostLine(day: day(d), orgId: org, amount: dec(amount), source: source, feed: feed, model: model, apiKeyId: key)
    }

    private func store() async throws -> MeterStore {
        let s = try MeterStore.inMemory()
        try await s.upsertOrg(Org(id: "a", provider: .anthropic, displayName: "A"))
        return s
    }

    @Test func migrationFromEmptyDatabase() async throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("nested/meter.db")
        do {
            let s = try MeterStore(url: url)
            #expect(await s.schemaVersion == 1)
            try await s.upsertOrg(Org(id: "a", provider: .anthropic, displayName: "A"))
        }
        // Reopening runs no migration again and keeps the data.
        let again = try MeterStore(url: url)
        #expect(await again.schemaVersion == 1)
        #expect(try await again.orgs().map(\.id) == ["a"])
        // WAL mode on a real file.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func allTablesExist() async throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.migrate(Schema.migrations)
        let names = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.text(0) }
        for t in ["orgs", "cost_lines", "entities", "tags", "budgets", "claude_code_days", "limits", "prepaid", "coverage", "settings"] {
            #expect(names.contains(t), "missing table \(t)")
        }
        #expect(db.userVersion == 1)
        let mode = try db.query("PRAGMA foreign_keys") { $0.int(0) }
        #expect(mode == [1])
    }

    @Test func newerDatabaseIsRefused() throws {
        let dir = tempDir()
        let path = dir.appendingPathComponent("m.db").path
        let db = try SQLiteDatabase(path: path)
        try db.migrate(Schema.migrations)
        try db.setUserVersion(99)
        #expect(throws: SQLiteError.self) { try db.migrate(Schema.migrations) }
    }

    @Test func migrationsRunInOrderAndOnlyOnce() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        let m: [[String]] = [["CREATE TABLE t (a INTEGER)"], ["ALTER TABLE t ADD COLUMN b INTEGER"]]
        try db.migrate([m[0]])
        #expect(db.userVersion == 1)
        try db.migrate(m)
        #expect(db.userVersion == 2)
        try db.migrate(m)
        try db.execute("INSERT INTO t (a, b) VALUES (1, 2)")
    }

    @Test func failedMigrationRollsBack() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        #expect(throws: SQLiteError.self) { try db.migrate([["CREATE TABLE t (a INTEGER)", "THIS IS NOT SQL"]]) }
        #expect(db.userVersion == 0)
        let n = try db.query("SELECT count(*) FROM sqlite_master WHERE name = 't'") { $0.int(0) }
        #expect(n == [0])
    }

    @Test func upsertIsIdempotent() async throws {
        let s = try await store()
        let lines = [line("2026-11-01", "1.5"), line("2026-11-01", "2", model: "other"), line("2026-11-02", "3", key: "k1")]
        try await s.upsertCostLines(lines)
        try await s.upsertCostLines(lines)
        try await s.upsertCostLines(lines)
        let got = try await s.costLines()
        #expect(got.count == 3)
        #expect(got.map(\.amount).reduce(0, +) == dec("6.5"))
    }

    @Test func restatedDayOverwritesAmountNotDuplicates() async throws {
        let s = try await store()
        try await s.upsertCostLines([line("2026-11-01", "10")])
        try await s.upsertCostLines([line("2026-11-01", "12.25")])
        let got = try await s.costLines()
        #expect(got.count == 1 && got[0].amount == dec("12.25"))
    }

    @Test func replaceDropsRowsTheRestatementRemoved() async throws {
        let s = try await store()
        try await s.upsertCostLines([line("2026-11-01", "10", model: "a"), line("2026-11-01", "5", model: "b"), line("2026-11-05", "7", model: "a")])
        try await s.replaceCostLines(orgId: "a", feed: .anthropicAnalytics, from: day("2026-11-01"), to: day("2026-11-03"),
                                     with: [line("2026-11-01", "11", model: "a")])
        let got = try await s.costLines()
        #expect(got.count == 2)
        #expect(got.first { $0.day == day("2026-11-01") }?.amount == 11)
        #expect(got.first { $0.day == day("2026-11-05") }?.amount == 7)
    }

    @Test func differentSourceOrFeedAreDifferentRows() async throws {
        let s = try await store()
        try await s.upsertCostLines([line("2026-11-01", "1"), line("2026-11-01", "2", source: .estimated), line("2026-11-01", "3", feed: .anthropicLegacy)])
        #expect(try await s.costLines().count == 3)
    }

    @Test func amountsRoundTripExactly() async throws {
        let s = try await store()
        try await s.upsertCostLines([line("2026-11-01", "0.000001234567")])
        #expect(try await s.costLines()[0].amount == dec("0.000001234567"))
    }

    @Test func removingAnOrgCascades() async throws {
        let s = try await store()
        try await s.upsertCostLines([line("2026-11-01", "1")])
        try await s.upsertEntities([Entity(orgId: "a", kind: .user, id: "u", name: "U")])
        try await s.saveCoverage(Coverage(orgId: "a", source: .anthropicAnalytics))
        try await s.removeOrg(id: "a")
        #expect(try await s.costLines().isEmpty)
        #expect(try await s.entities().isEmpty)
        #expect(try await s.coverage().isEmpty)
    }

    @Test func everyTableRoundTrips() async throws {
        let s = try await store()
        try await s.upsertEntities([Entity(orgId: "a", kind: .apiKey, id: "k", name: "prod", email: nil, parentId: "w", ownerId: "u",
                                           lastUsedAt: Date(timeIntervalSince1970: 100), archived: true)])
        try await s.setTag(Tag(orgId: "a", target: .apiKey, targetId: "k", kind: .app))
        try await s.setTag(Tag(orgId: "a", target: .project, targetId: "w", kind: .team))
        try await s.setTag(Tag(orgId: "a", target: .project, targetId: "w", kind: .untagged))
        for b in [Budget(id: "b1", name: "All", scope: .overall, amount: 1000),
                  Budget(id: "b2", name: "App", scope: .tag(.app), amount: dec("250.5"), thresholds: [80, 100]),
                  Budget(id: "b3", name: "Proj", scope: .project(orgId: "a", projectId: "w"), amount: 10),
                  Budget(id: "b4", name: "Org", scope: .org("a"), amount: 10)] { try await s.upsertBudget(b) }
        try await s.upsertClaudeCodeDays([ClaudeCodeDay(orgId: "a", day: day("2026-11-10"), actorType: .user, actorKey: "x@y.z", sessions: 2,
                                                         linesAdded: 3, linesRemoved: 4, commits: 5, pullRequests: 6, estimatedCost: dec("1.25"))])
        try await s.replaceLimits(orgId: "a", with: [Limit(id: "org:hard", orgId: "a", kind: .hardLimit, thresholdCents: 500)])
        try await s.setPrepaid(PrepaidBalance(orgId: "a", amount: dec("100.10"), enteredAt: Date(timeIntervalSince1970: 5000)))
        let cov = Coverage(orgId: "a", source: .claudeCode, lastAttempt: Date(timeIntervalSince1970: 1), lastSuccess: Date(timeIntervalSince1970: 2),
                           watermark: Date(timeIntervalSince1970: 3), coveredFrom: day("2026-01-01"), coveredThrough: day("2026-11-10"), lastError: "boom", errorKind: "network",
                           lastFetchEmpty: true, unavailable: true, note: "n")
        try await s.saveCoverage(cov)
        try await s.setSetting("poll", "15")

        let e = try await s.entities()[0]
        #expect(e.parentId == "w" && e.ownerId == "u" && e.archived && e.lastUsedAt == Date(timeIntervalSince1970: 100))
        #expect(try await s.tags() == [Tag(orgId: "a", target: .apiKey, targetId: "k", kind: .app)])
        let budgets = try await s.budgets()
        #expect(budgets.count == 4)
        #expect(budgets.first { $0.id == "b2" }?.thresholds == [80, 100])
        #expect(budgets.first { $0.id == "b2" }?.scope == .tag(.app))
        #expect(budgets.first { $0.id == "b3" }?.scope == .project(orgId: "a", projectId: "w"))
        #expect(budgets.first { $0.id == "b1" }?.thresholds == [50, 80, 100])
        #expect(try await s.claudeCodeDays()[0].estimatedCost == dec("1.25"))
        #expect(try await s.limits()[0].thresholdCents == 500)
        #expect(try await s.prepaidEntries()[0].amount == dec("100.10"))
        #expect(try await s.coverage()[0] == cov)
        #expect(try await s.setting("poll") == "15")
        #expect(try await s.setting("missing") == nil)
    }

    @Test func secretsNeverReachTheDatabaseFile() async throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("meter.db")
        let secrets = InMemorySecrets()
        let org = Org(id: "org-1", provider: .anthropic, displayName: "Acme")
        try secrets.write("sk-ant-admin01-SUPERSECRET", for: org.keychainRef)
        let s = try MeterStore(url: url)
        try await s.upsertOrg(org)
        let stored = try await s.orgs()[0]
        #expect(stored.keychainRef == KeychainRef(service: "dev.meter.app", account: "org-1"))
        #expect(stored.keychainRef.raw == "dev.meter.app/org-1")
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("SUPERSECRET".utf8)) == nil)
        #expect(try secrets.read(stored.keychainRef) == "sk-ant-admin01-SUPERSECRET")
    }

    @Test func meterHomeOverridesPath() {
        #expect(MeterPaths.databaseURL(environment: ["METER_HOME": "/tmp/xyz"]).path == "/tmp/xyz/meter.db")
        let def = MeterPaths.databaseURL(environment: [:]).path
        #expect(def.hasSuffix("/Library/Application Support/Meter/meter.db"))
    }

    @Test func openDefaultHonoursMeterHome() async throws {
        let dir = tempDir()
        let s = try MeterStore.openDefault(environment: ["METER_HOME": dir.path])
        #expect(await s.path == dir.appendingPathComponent("meter.db").path)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meter.db").path))
    }

    @Test func inMemorySecretsRoundTrip() throws {
        let s = InMemorySecrets()
        let ref = KeychainRef.forOrg(id: "x")
        #expect(try s.read(ref) == nil)
        try s.write("one", for: ref)
        try s.write("two", for: ref)
        #expect(try s.read(ref) == "two")
        try s.delete(ref)
        #expect(try s.read(ref) == nil)
        #expect(KeychainRef(raw: "dev.meter.app/org/with/slash")?.account == "org/with/slash")
    }
}
