import Foundation
import Synchronization
@testable import MeterCore

enum Fixture {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let d = try? Data(contentsOf: url) else { fatalError("missing fixture \(name)") }
        return d
    }
    static func response(_ name: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: data(name))
    }
}

func json(_ s: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(status: status, headers: headers, body: Data(s.utf8))
}

extension HTTPRequest {
    func query(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    func queryAll(_ name: String) -> [String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
    }
    var path: String { url.path }
}

/// Serves canned responses and records every request. Never touches the network.
final class FakeTransport: HTTPTransport {
    private let log = Mutex<[HTTPRequest]>([])
    private let handler: Mutex<@Sendable (HTTPRequest) throws -> HTTPResponse>

    init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        self.handler = Mutex(handler)
    }

    func setHandler(_ h: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) { handler.withLock { $0 = h } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        let h = handler.withLock { $0 }
        return try h(request)
    }

    var requests: [HTTPRequest] { log.withLock { $0 } }
    func requests(path: String) -> [HTTPRequest] { requests.filter { $0.path == path } }
    func reset() { log.withLock { $0.removeAll() } }
}

struct OfflineError: Error {}

final class TestClock: @unchecked Sendable {
    private let t: Mutex<Date>
    init(_ d: Date) { t = Mutex(d) }
    var now: Date { t.withLock { $0 } }
    func advance(_ s: TimeInterval) { t.withLock { $0 = $0.addingTimeInterval(s) } }
}

func utc(_ s: String) -> Date { ISODate.parse(s)! }
func day(_ s: String) -> UTCDay { UTCDay(string: s)! }
func dec(_ s: String) -> Decimal { Money.decimal(from: s)! }

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("meter-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Builds a snapshot without a database, for the pure query tests.
struct World {
    var orgs: [Org] = []
    var lines: [CostLine] = []
    var entities: [Entity] = []
    var tags: [Tag] = []
    var budgets: [Budget] = []
    var claudeCode: [ClaudeCodeDay] = []
    var limits: [Limit] = []
    var prepaid: [PrepaidBalance] = []
    var coverage: [Coverage] = []

    var snapshot: MeterSnapshot {
        MeterSnapshot(orgs: orgs, lines: lines, entities: entities, tags: tags, budgets: budgets, claudeCode: claudeCode,
                      limits: limits, prepaid: prepaid, coverage: coverage)
    }

    /// Adds an org with dollar coverage through `through`.
    mutating func addOrg(_ id: String, _ provider: Provider, name: String? = nil, through: String) {
        orgs.append(Org(id: id, provider: provider, displayName: name ?? id))
        let source: SyncSource = provider == .anthropic ? .anthropicAnalytics : .openaiCosts
        coverage.append(Coverage(orgId: id, source: source, lastSuccess: utc("2026-11-13T11:00:00Z"), coveredThrough: day(through)))
    }

    mutating func add(_ org: String, _ d: String, _ amount: String, feed: CostFeed? = nil, source: CostSource = .reported,
                      model: String? = nil, key: String? = nil, project: String? = nil, actor: String? = nil) {
        let f = feed ?? (orgs.first { $0.id == org }?.provider == .openai ? .openaiCosts : .anthropicAnalytics)
        lines.append(CostLine(day: day(d), orgId: org, amount: dec(amount), source: source, feed: f, model: model,
                              apiKeyId: key, projectId: project, actor: actor))
    }

    /// One flat daily amount for each day in the range.
    mutating func addDaily(_ org: String, from: String, to: String, _ amount: String, model: String? = nil) {
        for d in UTCDay.range(from: day(from), through: day(to)) { add(org, d.string, amount, model: model) }
    }
}
