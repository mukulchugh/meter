import Foundation
import MeterCore

// MARK: Form

public enum BudgetScopeKind: String, CaseIterable, Sendable, Identifiable {
    case overall, tag, project
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .overall: "Overall"
        case .tag: "Per tag"
        case .project: "Per project"
        }
    }
}

public enum BudgetField: Hashable, Sendable { case name, amount, scope, thresholds }

/// The budget form's state and its validation. Pure, so it is tested without a window.
public struct BudgetDraft: Equatable, Sendable {
    public static let allowedThresholds = [50, 80, 100]
    public static let maxAmount: Decimal = 10_000_000

    public var id: String?
    public var name = ""
    public var amountText = ""
    public var scopeKind: BudgetScopeKind = .overall
    public var tag: TagKind = .app
    public var projectOrgId = ""
    public var projectId = ""
    public var thresholds: Set<Int> = Set(allowedThresholds)

    public init() {}

    public init(_ b: Budget) {
        id = b.id
        name = b.name
        amountText = Money.string(b.amount)
        thresholds = Set(b.thresholds)
        switch b.scope {
        case .overall, .org: scopeKind = .overall
        case .tag(let t): scopeKind = .tag; tag = t
        case .project(let o, let p): scopeKind = .project; projectOrgId = o; projectId = p
        }
    }

    /// Accepts "$5,000" or "5000.50".
    static func parseAmount(_ text: String) -> Decimal? {
        let cleaned = text.filter { !"$, ".contains($0) }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    public func validate() -> Result<Budget, BudgetFormErrors> {
        var errors = [BudgetField: String]()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { errors[.name] = "Give the budget a name." }
        var amount: Decimal = 0
        if let a = Self.parseAmount(amountText) {
            if a <= 0 { errors[.amount] = "Enter an amount above zero." }
            else if a > Self.maxAmount { errors[.amount] = "That amount is too large." }
            else { amount = a }
        } else {
            errors[.amount] = "Enter a dollar amount, like 5000."
        }
        let scope: BudgetScope
        switch scopeKind {
        case .overall: scope = .overall
        case .tag: scope = .tag(tag)
        case .project:
            if projectId.isEmpty || projectOrgId.isEmpty { errors[.scope] = "Choose a project." }
            scope = .project(orgId: projectOrgId, projectId: projectId)
        }
        if thresholds.isEmpty { errors[.thresholds] = "Pick at least one alert level." }
        if !thresholds.isSubset(of: Self.allowedThresholds) { errors[.thresholds] = "Use 50, 80 or 100." }
        guard errors.isEmpty else { return .failure(BudgetFormErrors(fields: errors)) }
        return .success(Budget(id: id ?? UUID().uuidString, name: trimmed, scope: scope, amount: amount,
                               thresholds: Array(thresholds)))
    }
}

public struct BudgetFormErrors: Error, Equatable, Sendable {
    public var fields: [BudgetField: String]
}

// MARK: Screen content

public struct BudgetRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var budget: Budget
    public var scopeText: String
    public var usedText: String
    public var targetText: String
    public var percentText: String
    public var fraction: Double
    public var thresholdsText: String
    public var crossed: [Int]
    public var projectedText: String
    public var exceeded: Bool
}

public struct LimitRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var orgName: String
    public var kindText: String
    public var thresholdText: String
    public var usedText: String
    public var percentText: String
    public var fraction: Double
    public var projectedText: String
}

public struct PrepaidRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var orgName: String
    public var enteredText: String?
    public var remainingText: String?
    public var daysLeftText: String?
    public var runOutText: String?
    public var partialNote: String?
    public static let label = "estimate from your entered balance"
}

public struct ProjectChoice: Equatable, Identifiable, Hashable, Sendable {
    public var orgId: String
    public var projectId: String
    public var title: String
    public var id: String { "\(orgId)|\(projectId)" }
}

public struct BudgetsContent: Equatable, Sendable {
    public var budgets: [BudgetRow]
    public var limits: [LimitRow]
    public var prepaid: [PrepaidRow]
    public var projectChoices: [ProjectChoice]
    public var openAIOrgs: [Org]

    public init(snapshot: MeterSnapshot, now: Date) {
        budgets = snapshot.budgetStatuses(now: now).map { s in
            let scope: String
            switch s.budget.scope {
            case .overall: scope = "All spend"
            case .org(let id): scope = snapshot.org(id)?.displayName ?? id
            case .tag(let t): scope = "\(t.title) spend"
            case .project(let o, let p):
                scope = "Project: " + (snapshot.entity(orgId: o, kind: .project, id: p)?.name ?? p)
            }
            let projected = s.projectedCrossing.map { "Projected to reach 100% on \(Fmt.shortDay($0))" }
                ?? (s.tracking.exceeded ? "Already over" : "Not projected to reach 100% this month")
            return BudgetRow(id: s.budget.id, budget: s.budget, scopeText: scope, usedText: Fmt.usd(s.tracking.used),
                             targetText: Fmt.usd(s.budget.amount), percentText: s.tracking.percent.map(Fmt.percent) ?? Fmt.noData,
                             fraction: min(max((s.tracking.percent ?? 0) / 100, 0), 1),
                             thresholdsText: s.budget.thresholds.map(String.init).joined(separator: " / ") + "%",
                             crossed: s.thresholdsCrossed, projectedText: projected, exceeded: s.tracking.exceeded)
        }
        limits = snapshot.limitStatuses(now: now).map { s in
            let l = s.limit
            let title = l.projectId.map { snapshot.entity(orgId: l.orgId, kind: .project, id: $0)?.name ?? $0 } ?? "Organization"
            let projected = s.projectedCrossing.map { "Projected to reach it on \(Fmt.shortDay($0))" }
                ?? (s.tracking.exceeded ? "Already reached" : "Not projected this month")
            return LimitRow(id: l.id, title: title, orgName: snapshot.org(l.orgId)?.displayName ?? l.orgId,
                            kindText: l.kind == .hardLimit ? "Hard limit, enforced by OpenAI" : "Alert",
                            thresholdText: Fmt.usd(l.thresholdUSD), usedText: Fmt.usd(s.tracking.used),
                            percentText: s.tracking.percent.map(Fmt.percent) ?? Fmt.noData,
                            fraction: min(max((s.tracking.percent ?? 0) / 100, 0), 1), projectedText: projected)
        }
        let oai = snapshot.orgs.filter { $0.provider == .openai }
        openAIOrgs = oai
        prepaid = oai.map { o in
            guard let p = snapshot.prepaidStatus(orgId: o.id, now: now) else {
                return PrepaidRow(id: o.id, orgName: o.displayName)
            }
            return PrepaidRow(
                id: o.id, orgName: o.displayName, enteredText: "\(Fmt.usd(p.enteredAmount)) entered \(Fmt.shortDay(UTCDay(p.enteredAt)))",
                remainingText: Fmt.usd(p.remaining),
                daysLeftText: p.isDepleted ? "Depleted" : p.daysLeft.map { "About \(Int($0.rounded(.down))) days left" } ?? "Needs more spend history",
                runOutText: p.projectedRunOut.map { "Runs out about \(Fmt.shortDay($0))" },
                partialNote: p.spendIsPartial ? "Some spend since the entry is not covered yet." : nil)
        }
        projectChoices = snapshot.entities.filter { $0.kind == .project && !$0.archived }.compactMap { e in
            snapshot.org(e.orgId).map { ProjectChoice(orgId: e.orgId, projectId: e.id, title: "\(e.name) (\($0.displayName))") }
        }.sorted { $0.title < $1.title }
    }
}

// MARK: Alerts

public struct AlertEvent: Equatable, Sendable {
    /// Dedupe key: once per budget per threshold per month, once per spike day.
    public var key: String
    public var title: String
    public var body: String
}

public enum AlertPlanner {
    static func monthKey(_ d: UTCDay) -> String { String(format: "%04d-%02d", d.year, d.month) }

    public static func settingKey(for event: AlertEvent) -> String { "alert.fired.\(event.key)" }

    /// Every alert that applies now. The caller drops the ones already recorded in the store settings.
    public static func candidates(snapshot: MeterSnapshot, now: Date) -> [AlertEvent] {
        let today = UTCDay(now)
        var out = [AlertEvent]()
        for s in snapshot.budgetStatuses(now: now) {
            for t in s.thresholdsCrossed {
                out.append(AlertEvent(
                    key: "budget.\(s.budget.id).\(t).\(monthKey(today))",
                    title: "\(s.budget.name) reached \(t)%",
                    body: "\(Fmt.usd(s.tracking.used)) of \(Fmt.usd(s.budget.amount)) this month. Alert only, does not stop spend."))
            }
        }
        for sp in snapshot.spikes(now: now, lookbackDays: 2) {
            out.append(AlertEvent(
                key: "spike.\(sp.day.string)", title: "Spend spike on \(Fmt.shortDay(sp.day))",
                body: "\(Fmt.usd(sp.amount)) is \(String(format: "%.1f", sp.ratio))x the 14-day average."))
        }
        return out
    }
}
