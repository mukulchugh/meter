import Foundation

/// The local SQLite store. An actor, so the UI can call it from anywhere; reads come back as value types
/// (`MeterSnapshot`) that the query functions run over.
public actor MeterStore {
    private let db: SQLiteDatabase
    public let path: String

    /// Opens (creating if needed) the database at an explicit file URL, or `:memory:`. Tests must pass a
    /// temporary path; only `openDefault` resolves the real location.
    public init(url: URL) throws {
        try self.init(path: url.path)
    }

    public init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        self.path = path
        db = try SQLiteDatabase(path: path)
        try db.migrate(Schema.migrations)
    }

    public static func inMemory() throws -> MeterStore { try MeterStore(path: ":memory:") }

    /// `$METER_HOME/meter.db`, or the Application Support location when unset.
    public static func openDefault(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> MeterStore {
        try MeterStore(url: MeterPaths.databaseURL(environment: environment))
    }

    public var schemaVersion: Int { db.userVersion }

    // MARK: Orgs

    public func upsertOrg(_ org: Org) throws {
        try db.execute("""
            INSERT INTO orgs (id, provider, display_name, keychain_ref) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET provider = excluded.provider, display_name = excluded.display_name,
                keychain_ref = excluded.keychain_ref
            """, [.text(org.id), .text(org.provider.rawValue), .text(org.displayName), .text(org.keychainRef.raw)])
    }

    public func orgs() throws -> [Org] {
        try db.query("SELECT id, provider, display_name, keychain_ref FROM orgs ORDER BY display_name, id") { r in
            Org(id: r.text(0), provider: Provider(rawValue: r.text(1)) ?? .anthropic, displayName: r.text(2),
                keychainRef: KeychainRef(raw: r.text(3)) ?? .forOrg(id: r.text(0)))
        }
    }

    /// Removes an org and everything stored for it (cascade). The secret is the caller's to delete.
    public func removeOrg(id: String) throws {
        try db.execute("DELETE FROM orgs WHERE id = ?", [.text(id)])
    }

    // MARK: Cost lines

    private static let upsertLineSQL = """
        INSERT INTO cost_lines (org_id, day, feed, source, model, api_key_id, project_id, actor, service_tier, line_item, amount, currency)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(org_id, day, feed, source, model, api_key_id, project_id, actor, service_tier, line_item)
        DO UPDATE SET amount = excluded.amount, currency = excluded.currency
        """

    private func insert(_ l: CostLine) throws {
        try db.execute(Self.upsertLineSQL, [
            .text(l.orgId), .text(l.day.string), .text(l.feed.rawValue), .text(l.source.rawValue),
            .text(l.model ?? ""), .text(l.apiKeyId ?? ""), .text(l.projectId ?? ""), .text(l.actor ?? ""),
            .text(l.serviceTier ?? ""), .text(l.lineItem ?? ""), .text(Money.string(l.amount)), .text(l.currency),
        ])
    }

    /// Inserts or overwrites by (org, day, feed, source, all dimensions). Refetching is idempotent.
    public func upsertCostLines(_ lines: [CostLine]) throws {
        try db.transaction { for l in lines { try insert(l) } }
    }

    /// Replaces everything one feed holds for an org over a day range, in one transaction. Used by sync so
    /// a restated day that dropped a row does not leave the old row behind.
    public func replaceCostLines(orgId: String, feed: CostFeed, from: UTCDay, to: UTCDay, with lines: [CostLine]) throws {
        try db.transaction {
            try deleteCostLinesUnlocked(orgId: orgId, feed: feed, from: from, to: to)
            for l in lines where l.orgId == orgId && l.feed == feed && l.day >= from && l.day <= to { try insert(l) }
        }
    }

    public func deleteCostLines(orgId: String, feed: CostFeed, from: UTCDay, to: UTCDay) throws {
        try db.transaction { try deleteCostLinesUnlocked(orgId: orgId, feed: feed, from: from, to: to) }
    }

    private func deleteCostLinesUnlocked(orgId: String, feed: CostFeed, from: UTCDay, to: UTCDay) throws {
        try db.execute("DELETE FROM cost_lines WHERE org_id = ? AND feed = ? AND day >= ? AND day <= ?",
                       [.text(orgId), .text(feed.rawValue), .text(from.string), .text(to.string)])
    }

    public func costLines(from: UTCDay? = nil, to: UTCDay? = nil) throws -> [CostLine] {
        try db.query("""
            SELECT org_id, day, feed, source, model, api_key_id, project_id, actor, service_tier, line_item, amount, currency
            FROM cost_lines WHERE day >= ? AND day <= ? ORDER BY day, org_id
            """, [.text((from ?? UTCDay(year: 1970, month: 1, day: 1)).string), .text((to ?? UTCDay(year: 9999, month: 12, day: 31)).string)]) { r in
            guard let day = UTCDay(string: r.text(1)), let feed = CostFeed(rawValue: r.text(2)),
                  let source = CostSource(rawValue: r.text(3)) else {
                throw SQLiteError(code: 0, message: "corrupt cost line")
            }
            return CostLine(day: day, orgId: r.text(0), amount: r.decimal(10), currency: r.text(11), source: source,
                            feed: feed, model: r.dim(4), apiKeyId: r.dim(5), projectId: r.dim(6), actor: r.dim(7),
                            serviceTier: r.dim(8), lineItem: r.dim(9))
        }
    }

    // MARK: Entities and tags

    public func upsertEntities(_ entities: [Entity]) throws {
        try db.transaction {
            for e in entities {
                try db.execute("""
                    INSERT INTO entities (org_id, kind, id, name, email, parent_id, owner_id, last_used, archived)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(org_id, kind, id) DO UPDATE SET name = excluded.name, email = excluded.email,
                        parent_id = excluded.parent_id, owner_id = excluded.owner_id, last_used = excluded.last_used,
                        archived = excluded.archived
                    """, [.text(e.orgId), .text(e.kind.rawValue), .text(e.id), .text(e.name), .text(e.email),
                          .text(e.parentId), .text(e.ownerId), .date(e.lastUsedAt), .int(e.archived ? 1 : 0)])
            }
        }
    }

    public func entities() throws -> [Entity] {
        try db.query("SELECT org_id, kind, id, name, email, parent_id, owner_id, last_used, archived FROM entities") { r in
            Entity(orgId: r.text(0), kind: EntityKind(rawValue: r.text(1)) ?? .user, id: r.text(2), name: r.text(3),
                   email: r.optText(4), parentId: r.optText(5), ownerId: r.optText(6), lastUsedAt: r.date(7), archived: r.int(8) != 0)
        }
    }

    /// Sets a tag. Setting `.untagged` removes the row.
    public func setTag(_ tag: Tag) throws {
        if tag.kind == .untagged {
            try db.execute("DELETE FROM tags WHERE org_id = ? AND target_kind = ? AND target_id = ?",
                           [.text(tag.orgId), .text(tag.target.rawValue), .text(tag.targetId)])
        } else {
            try db.execute("""
                INSERT INTO tags (org_id, target_kind, target_id, tag) VALUES (?, ?, ?, ?)
                ON CONFLICT(org_id, target_kind, target_id) DO UPDATE SET tag = excluded.tag
                """, [.text(tag.orgId), .text(tag.target.rawValue), .text(tag.targetId), .text(tag.kind.rawValue)])
        }
    }

    public func tags() throws -> [Tag] {
        try db.query("SELECT org_id, target_kind, target_id, tag FROM tags") { r in
            Tag(orgId: r.text(0), target: TagTarget(rawValue: r.text(1)) ?? .project, targetId: r.text(2),
                kind: TagKind(rawValue: r.text(3)) ?? .untagged)
        }
    }

    // MARK: Budgets

    public func upsertBudget(_ b: Budget) throws {
        let (kind, org, value): (String, String, String)
        switch b.scope {
        case .overall: (kind, org, value) = ("overall", "", "")
        case .org(let id): (kind, org, value) = ("org", id, "")
        case .tag(let t): (kind, org, value) = ("tag", "", t.rawValue)
        case .project(let o, let p): (kind, org, value) = ("project", o, p)
        }
        try db.execute("""
            INSERT INTO budgets (id, name, scope_kind, scope_org, scope_value, amount, thresholds) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, scope_kind = excluded.scope_kind,
                scope_org = excluded.scope_org, scope_value = excluded.scope_value, amount = excluded.amount,
                thresholds = excluded.thresholds
            """, [.text(b.id), .text(b.name), .text(kind), .text(org), .text(value), .text(Money.string(b.amount)),
                  .text(b.thresholds.map(String.init).joined(separator: ","))])
    }

    public func deleteBudget(id: String) throws { try db.execute("DELETE FROM budgets WHERE id = ?", [.text(id)]) }

    public func budgets() throws -> [Budget] {
        try db.query("SELECT id, name, scope_kind, scope_org, scope_value, amount, thresholds FROM budgets ORDER BY name, id") { r in
            let scope: BudgetScope
            switch r.text(2) {
            case "org": scope = .org(r.text(3))
            case "tag": scope = .tag(TagKind(rawValue: r.text(4)) ?? .untagged)
            case "project": scope = .project(orgId: r.text(3), projectId: r.text(4))
            default: scope = .overall
            }
            return Budget(id: r.text(0), name: r.text(1), scope: scope, amount: r.decimal(5),
                          thresholds: r.text(6).split(separator: ",").compactMap { Int($0) })
        }
    }

    // MARK: Claude Code

    public func upsertClaudeCodeDays(_ days: [ClaudeCodeDay]) throws {
        try db.transaction {
            for d in days {
                try db.execute("""
                    INSERT INTO claude_code_days (org_id, day, actor_type, actor_key, sessions, lines_added, lines_removed, commits, pull_requests, estimated_cost)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(org_id, day, actor_type, actor_key) DO UPDATE SET sessions = excluded.sessions,
                        lines_added = excluded.lines_added, lines_removed = excluded.lines_removed,
                        commits = excluded.commits, pull_requests = excluded.pull_requests,
                        estimated_cost = excluded.estimated_cost
                    """, [.text(d.orgId), .text(d.day.string), .text(d.actorType.rawValue), .text(d.actorKey),
                          .int(d.sessions), .int(d.linesAdded), .int(d.linesRemoved), .int(d.commits),
                          .int(d.pullRequests), .text(Money.string(d.estimatedCost))])
            }
        }
    }

    /// Replaces a whole day for an org, so people who vanished from a restated day disappear too.
    public func replaceClaudeCodeDay(orgId: String, day: UTCDay, with days: [ClaudeCodeDay]) throws {
        try db.transaction {
            try db.execute("DELETE FROM claude_code_days WHERE org_id = ? AND day = ?", [.text(orgId), .text(day.string)])
            try upsertClaudeCodeDays(days)
        }
    }

    public func claudeCodeDays() throws -> [ClaudeCodeDay] {
        try db.query("""
            SELECT org_id, day, actor_type, actor_key, sessions, lines_added, lines_removed, commits, pull_requests, estimated_cost
            FROM claude_code_days ORDER BY day
            """) { r in
            ClaudeCodeDay(orgId: r.text(0), day: UTCDay(string: r.text(1)) ?? UTCDay(daysSinceEpoch: 0),
                          actorType: ClaudeCodeDay.ActorType(rawValue: r.text(2)) ?? .user, actorKey: r.text(3),
                          sessions: r.int(4), linesAdded: r.int(5), linesRemoved: r.int(6), commits: r.int(7),
                          pullRequests: r.int(8), estimatedCost: r.decimal(9))
        }
    }

    // MARK: Limits, prepaid

    public func replaceLimits(orgId: String, with limits: [Limit]) throws {
        try db.transaction {
            try db.execute("DELETE FROM limits WHERE org_id = ?", [.text(orgId)])
            for l in limits {
                try db.execute("""
                    INSERT OR REPLACE INTO limits (org_id, id, project_id, kind, threshold_cents, currency, interval)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.text(l.orgId), .text(l.id), .text(l.projectId ?? ""), .text(l.kind.rawValue),
                          .int(l.thresholdCents), .text(l.currency), .text(l.interval)])
            }
        }
    }

    public func limits() throws -> [Limit] {
        try db.query("SELECT org_id, id, project_id, kind, threshold_cents, currency, interval FROM limits ORDER BY org_id, id") { r in
            Limit(id: r.text(1), orgId: r.text(0), projectId: r.dim(2), kind: Limit.Kind(rawValue: r.text(3)) ?? .alert,
                  thresholdCents: r.int(4), currency: r.text(5), interval: r.text(6))
        }
    }

    /// Records a top-up balance. The latest entry per org is the one in force.
    public func setPrepaid(_ p: PrepaidBalance) throws {
        try db.execute("INSERT OR REPLACE INTO prepaid (org_id, entered_at, amount) VALUES (?, ?, ?)",
                       [.text(p.orgId), .real(p.enteredAt.timeIntervalSince1970), .text(Money.string(p.amount))])
    }

    public func prepaidEntries() throws -> [PrepaidBalance] {
        try db.query("SELECT org_id, entered_at, amount FROM prepaid ORDER BY entered_at") { r in
            PrepaidBalance(orgId: r.text(0), amount: r.decimal(2), enteredAt: r.date(1) ?? Date(timeIntervalSince1970: 0))
        }
    }

    // MARK: Coverage

    public func saveCoverage(_ c: Coverage) throws {
        try db.execute("""
            INSERT OR REPLACE INTO coverage (org_id, source, last_attempt, last_success, watermark, covered_from, covered_through,
                last_error, error_kind, last_fetch_empty, unavailable, note) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(c.orgId), .text(c.source.rawValue), .date(c.lastAttempt), .date(c.lastSuccess), .date(c.watermark),
                  .text(c.coveredFrom?.string), .text(c.coveredThrough?.string), .text(c.lastError), .text(c.errorKind),
                  .int(c.lastFetchEmpty ? 1 : 0), .int(c.unavailable ? 1 : 0), .text(c.note)])
    }

    public func coverage() throws -> [Coverage] {
        try db.query("""
            SELECT org_id, source, last_attempt, last_success, watermark, covered_from, covered_through, last_error, error_kind,
                   last_fetch_empty, unavailable, note FROM coverage
            """) { r in
            Coverage(orgId: r.text(0), source: SyncSource(rawValue: r.text(1)) ?? .anthropicAnalytics,
                     lastAttempt: r.date(2), lastSuccess: r.date(3), watermark: r.date(4),
                     coveredFrom: r.optText(5).flatMap { UTCDay(string: $0) },
                     coveredThrough: r.optText(6).flatMap { UTCDay(string: $0)}, lastError: r.optText(7),
                     errorKind: r.optText(8), lastFetchEmpty: r.int(9) != 0, unavailable: r.int(10) != 0, note: r.optText(11))
        }
    }

    public func coverage(orgId: String, source: SyncSource) throws -> Coverage {
        try coverage().first { $0.orgId == orgId && $0.source == source } ?? Coverage(orgId: orgId, source: source)
    }

    // MARK: Settings

    public func setSetting(_ key: String, _ value: String) throws {
        try db.execute("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [.text(key), .text(value)])
    }

    public func setting(_ key: String) throws -> String? {
        try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { $0.text(0) }.first
    }

    // MARK: Snapshot

    /// Everything the query functions need, as one immutable value.
    public func snapshot() throws -> MeterSnapshot {
        MeterSnapshot(orgs: try orgs(), lines: try costLines(), entities: try entities(), tags: try tags(),
                      budgets: try budgets(), claudeCode: try claudeCodeDays(), limits: try limits(),
                      prepaid: try prepaidEntries(), coverage: try coverage())
    }
}
