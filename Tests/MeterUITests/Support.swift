import Foundation
import MeterCore
import Synchronization
@testable import MeterUI

let t0: Date = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!

func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
func day(_ s: String) -> UTCDay { UTCDay(string: s)! }
func dec(_ s: String) -> Decimal { Money.decimal(from: s)! }

final class FakeNotifier: Notifying {
    private let state = Mutex<(requests: Int, posted: [AlertEvent], grant: Bool)>((0, [], true))
    var requests: Int { state.withLock { $0.requests } }
    var posted: [AlertEvent] { state.withLock { $0.posted } }
    func requestAuthorization() async -> Bool { state.withLock { $0.requests += 1; return $0.grant } }
    func post(_ event: AlertEvent) async { state.withLock { $0.posted.append(event) } }
}

@MainActor
final class FakeLoginItem: LoginItemControlling {
    var enabled = false
    var calls = [Bool]()
    var isEnabled: Bool { enabled }
    func setEnabled(_ on: Bool) throws { calls.append(on); enabled = on }
}

/// A provider that always rejects the key.
struct RejectingClient: ProviderClient {
    var provider: Provider
    var maxCostWindowDays: Int { 31 }
    func fetchCosts(from: UTCDay, to: UTCDay) async throws -> CostFetch { throw ProviderError.auth(.invalidKey, provider) }
    func fetchEntities() async throws -> [Entity] { throw ProviderError.auth(.invalidKey, provider) }
}

struct Rig {
    let model: AppModel
    let store: MeterStore
    let secrets: InMemorySecrets
    let notifier: FakeNotifier
    let login: FakeLoginItem
}

/// A model over an in-memory store, with the fake provider and a fixed clock. Never touches the
/// Keychain, the real database, or the network.
@MainActor
func makeRig(demo: Bool, now: Date = t0, factory: ProviderClientFactory? = nil, store: MeterStore? = nil) async throws -> Rig {
    let store = try store ?? MeterStore.inMemory()
    let secrets = InMemorySecrets()
    let engine = SyncEngine(store: store, secrets: secrets, clientFactory: factory ?? DemoData.factory(now: now), now: { now })
    let notifier = FakeNotifier()
    let login = FakeLoginItem()
    let model = AppModel(store: store, secrets: secrets, engine: engine, notifier: notifier, loginItem: login,
                         clock: { now }, isDemo: demo, seedDemo: demo)
    await model.load()
    return Rig(model: model, store: store, secrets: secrets, notifier: notifier, login: login)
}

/// A hand-built snapshot for exact assertions.
struct Built {
    var orgs = [Org]()
    var lines = [CostLine]()
    var coverage = [Coverage]()
    var entities = [Entity]()
    var tags = [Tag]()
    var budgets = [Budget]()

    var snapshot: MeterSnapshot {
        MeterSnapshot(orgs: orgs, lines: lines, entities: entities, tags: tags, budgets: budgets, coverage: coverage)
    }

    mutating func org(_ id: String, _ p: Provider, name: String? = nil, through: String = "2026-11-13",
                      success: String = "2026-11-13T09:00:00Z", watermark: String? = nil,
                      error: String? = nil, errorKind: String? = nil) {
        orgs.append(Org(id: id, provider: p, displayName: name ?? id))
        coverage.append(Coverage(orgId: id, source: p == .anthropic ? .anthropicAnalytics : .openaiCosts,
                                 lastSuccess: utc(success), watermark: watermark.map(utc),
                                 coveredFrom: day("2026-01-01"), coveredThrough: day(through),
                                 lastError: error, errorKind: errorKind))
    }

    mutating func add(_ org: String, _ d: String, _ amount: String, model: String? = nil, key: String? = nil, project: String? = nil) {
        let p = orgs.first { $0.id == org }?.provider
        lines.append(CostLine(day: day(d), orgId: org, amount: dec(amount), feed: p == .openai ? .openaiCosts : .anthropicAnalytics,
                              model: model, apiKeyId: key, projectId: project))
    }

    mutating func daily(_ org: String, from: String, to: String, _ amount: String) {
        for d in UTCDay.range(from: day(from), through: day(to)) { add(org, d.string, amount) }
    }
}
