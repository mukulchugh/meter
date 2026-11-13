import Foundation

public enum Export {
    static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static let csvHeader = [
        "day_utc", "provider", "org_id", "org_name", "basis", "feed", "counts_toward_total", "tag", "model",
        "api_key_id", "api_key_name", "project_id", "project_name", "actor_id", "actor_name", "actor_email",
        "service_tier", "line_item", "amount_usd", "currency",
    ]

    /// Cost lines for `[from, to]`, every dimension, with names and tags resolved. Every row says what it
    /// is: `basis` is reported or estimated, and `counts_toward_total` is false for a supplemental feed
    /// (a second view of the same dollars), so finance can filter on it and never double count.
    public static func csv(_ snapshot: MeterSnapshot, from: UTCDay, to: UTCDay) -> String {
        var rows = [csvHeader.joined(separator: ",")]
        func sortKey(_ l: CostLine) -> String {
            [l.day.string, l.orgId, l.feed.rawValue, l.model ?? "", l.apiKeyId ?? "", l.projectId ?? "", l.actor ?? "", l.lineItem ?? ""]
                .joined(separator: "\u{1F}")
        }
        let lines = snapshot.lines.filter { $0.day >= from && $0.day <= to }.sorted { sortKey($0) < sortKey($1) }
        for l in lines {
            let org = snapshot.org(l.orgId)
            let key = l.apiKeyId.flatMap { snapshot.entity(orgId: l.orgId, kind: .apiKey, id: $0) }
            let project = l.projectId.flatMap { snapshot.entity(orgId: l.orgId, kind: .project, id: $0) }
            let actor = l.actor.flatMap { snapshot.entity(orgId: l.orgId, kind: .user, id: $0) }
            let counts = l.source == .reported && !l.feed.isSupplemental
            let fields: [String] = [
                l.day.string, org?.provider.rawValue ?? "", l.orgId, org?.displayName ?? "", l.source.rawValue,
                l.feed.rawValue, counts ? "true" : "false", snapshot.tag(for: l).rawValue, l.model ?? "",
                l.apiKeyId ?? "", key?.name ?? "", l.projectId ?? "", project?.name ?? "", l.actor ?? "",
                actor?.name ?? "", actor?.email ?? "", l.serviceTier ?? "", l.lineItem ?? "",
                Money.string(l.amount), l.currency,
            ]
            rows.append(fields.map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func usd(_ d: Decimal?) -> String {
        guard let d else { return "no data" }
        let r = Money.rounded(d)
        let s = NSDecimalNumber(decimal: r).description(withLocale: Locale(identifier: "en_US_POSIX"))
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let frac = parts.count > 1 ? String(parts[1]) : ""
        return "$" + parts[0] + "." + (frac + "00").prefix(2)
    }

    static func readingText(_ r: Reading) -> String {
        switch r.state {
        case .missing: "no data"
        case .partial: "\(usd(r.amount)) (partial, some data missing)"
        case .noActivity: "$0.00 (no activity)"
        case .value: usd(r.amount)
        }
    }

    /// The weekly markdown summary: the 7 complete days before `now`, against the 7 before those.
    /// Provider-reported cost only; Claude Code estimates are listed apart.
    public static func weeklySummary(_ snapshot: MeterSnapshot, now: Date) -> String {
        let today = UTCDay(now)
        let to = today.adding(-1), from = today.adding(-7)
        let prevTo = from.adding(-1), prevFrom = from.adding(-7)
        var out = ["# Meter weekly summary", "", "Week: \(from) to \(to) (UTC). Basis: \(Reading.basisLabel).", ""]

        let week = snapshot.total(from: from, to: to)
        let prev = snapshot.total(from: prevFrom, to: prevTo)
        out += ["## Total", "", "- This week: \(readingText(week))", "- Previous week: \(readingText(prev))"]
        if let a = week.amount, let b = prev.amount, b > 0, week.state != .partial, prev.state != .partial {
            let pct = NSDecimalNumber(decimal: (a - b) / b * 100).doubleValue
            out.append("- Change: " + String(format: "%+.0f%%", pct))
        }
        out.append("")

        out += ["## By organization", ""]
        for t in snapshot.totalsByOrg(from: from, to: to) {
            out.append("- \(t.org.displayName) (\(t.org.provider.displayName)): \(readingText(t.reading))")
        }
        out += ["", "## App vs Team", ""]
        for t in snapshot.totalsByTag(from: from, to: to) { out.append("- \(t.tag.rawValue.capitalized): \(readingText(t.reading))") }

        for (title, dim) in [("Top models", DriverDimension.model), ("Top keys", .apiKey), ("Top projects and workspaces", .project), ("Top people", .person)] {
            out += ["", "## \(title)", ""]
            let drivers = snapshot.topDrivers(dim, limit: 5, from: from, to: to)
            if drivers.isEmpty { out.append("- no data") }
            for d in drivers {
                let org = d.orgId.flatMap { snapshot.org($0)?.displayName }.map { " [\($0)]" } ?? ""
                out.append("- \(d.name)\(org): \(usd(d.amount))")
            }
        }

        let spikes = snapshot.spikes(now: now, lookbackDays: 7)
        out += ["", "## Spikes", ""]
        if spikes.isEmpty { out.append("- none") }
        for s in spikes { out.append("- \(s.day): \(usd(s.amount)), \(String(format: "%.1f", s.ratio))x the 14-day average of \(usd(s.baselineAverage))") }

        out += ["", "## Budgets (alerts only, they do not stop spend)", ""]
        let statuses = snapshot.budgetStatuses(now: now)
        if statuses.isEmpty { out.append("- none set") }
        for b in statuses {
            let pct = b.tracking.percent.map { String(format: "%.0f%%", $0) } ?? "n/a"
            out.append("- \(b.budget.name): \(usd(b.tracking.used)) of \(usd(b.budget.amount)) (\(pct) used)")
        }

        let cc = snapshot.claudeCodeActivity(from: from, to: to)
        out += ["", "## Claude Code (estimated, not part of the totals above)", ""]
        if cc.isEmpty { out.append("- no data") }
        for p in cc.prefix(10) {
            out.append("- \(p.id): \(p.sessions) sessions, +\(p.linesAdded)/-\(p.linesRemoved) lines, \(p.commits) commits, \(p.pullRequests) PRs, estimated \(usd(p.estimatedCost))")
        }

        let cov = snapshot.coverageSummary(now: now)
        out += ["", "## Coverage", ""]
        if cov.orgs.isEmpty { out.append("- no organizations connected") }
        for o in cov.orgs {
            let through = o.coveredThrough.map { "data through \($0)" } ?? "no data yet"
            out.append("- \(o.org.displayName): \(o.state.rawValue), \(through)")
        }
        return out.joined(separator: "\n") + "\n"
    }
}
