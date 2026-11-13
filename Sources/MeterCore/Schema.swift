import Foundation

/// Schema migrations. `user_version` records how many have run. Append only; never edit a shipped one.
enum Schema {
    static let migrations: [[String]] = [
        // 1: initial schema. Secrets are never stored; orgs hold only a keychain reference string.
        [
            """
            CREATE TABLE orgs (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                display_name TEXT NOT NULL,
                keychain_ref TEXT NOT NULL
            )
            """,
            // Dimension columns hold '' for "none" so the UNIQUE index treats them as equal (SQLite
            // treats NULLs as distinct). Amounts are exact decimal text.
            """
            CREATE TABLE cost_lines (
                org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
                day TEXT NOT NULL,
                feed TEXT NOT NULL,
                source TEXT NOT NULL,
                model TEXT NOT NULL DEFAULT '',
                api_key_id TEXT NOT NULL DEFAULT '',
                project_id TEXT NOT NULL DEFAULT '',
                actor TEXT NOT NULL DEFAULT '',
                service_tier TEXT NOT NULL DEFAULT '',
                line_item TEXT NOT NULL DEFAULT '',
                amount TEXT NOT NULL,
                currency TEXT NOT NULL,
                UNIQUE (org_id, day, feed, source, model, api_key_id, project_id, actor, service_tier, line_item)
            )
            """,
            "CREATE INDEX cost_lines_day ON cost_lines(day)",
            """
            CREATE TABLE entities (
                org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                name TEXT NOT NULL,
                email TEXT,
                parent_id TEXT,
                owner_id TEXT,
                last_used REAL,
                archived INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (org_id, kind, id)
            )
            """,
            """
            CREATE TABLE tags (
                org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
                target_kind TEXT NOT NULL,
                target_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                PRIMARY KEY (org_id, target_kind, target_id)
            )
            """,
            """
            CREATE TABLE budgets (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                scope_kind TEXT NOT NULL,
                scope_org TEXT NOT NULL DEFAULT '',
                scope_value TEXT NOT NULL DEFAULT '',
                amount TEXT NOT NULL,
                thresholds TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE claude_code_days (
                org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
                day TEXT NOT NULL,
                actor_type TEXT NOT NULL,
                actor_key TEXT NOT NULL,
                sessions INTEGER NOT NULL,
                lines_added INTEGER NOT NULL,
                lines_removed INTEGER NOT NULL,
                commits INTEGER NOT NULL,
                pull_requests INTEGER NOT NULL,
                estimated_cost TEXT NOT NULL,
                PRIMARY KEY (org_id, day, actor_type, actor_key)
            )
            """,
            """
            CREATE TABLE limits (
                org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
                id TEXT NOT NULL,
                project_id TEXT NOT NULL DEFAULT '',
                kind TEXT NOT NULL,
                threshold_cents INTEGER NOT NULL,
                currency TEXT NOT NULL,
                interval TEXT NOT NULL,
                PRIMARY KEY (org_id, id)
            )
            """,
            """
            CREATE TABLE prepaid (
                org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
                entered_at REAL NOT NULL,
                amount TEXT NOT NULL,
                PRIMARY KEY (org_id, entered_at)
            )
            """,
            """
            CREATE TABLE coverage (
                org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                last_attempt REAL,
                last_success REAL,
                watermark REAL,
                covered_from TEXT,
                covered_through TEXT,
                last_error TEXT,
                error_kind TEXT,
                last_fetch_empty INTEGER NOT NULL DEFAULT 0,
                unavailable INTEGER NOT NULL DEFAULT 0,
                note TEXT,
                PRIMARY KEY (org_id, source)
            )
            """,
            "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        ],
    ]
}
