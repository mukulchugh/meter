import Foundation

/// Keeps the plan usage rows fresh: Codex through the app-server every 5 minutes while Meter is visible and
/// every 30 otherwise, Claude Code by reading the file its status line helper writes. Writes only the
/// `plan_usage` table. Nothing here touches spend.
public actor PlanUsageEngine {
    public static let foregroundInterval: TimeInterval = 300
    public static let backgroundInterval: TimeInterval = 1800

    private let store: MeterStore
    private let codex: CodexPlanSource?
    private let claudePlanURL: URL?
    private let claudeHook: (@Sendable () -> ClaudeHookStatus)?
    private let now: @Sendable () -> Date
    private var foreground = false
    private var lastCodex: Date?
    private var loop: Task<Void, Never>?

    /// Every source is optional and defaults to none, so a test or preview never reaches a real tool or file.
    public init(store: MeterStore, codex: CodexPlanSource? = nil, claudePlanURL: URL? = nil,
                claudeHook: (@Sendable () -> ClaudeHookStatus)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.codex = codex
        self.claudePlanURL = claudePlanURL
        self.claudeHook = claudeHook
        self.now = now
    }

    public func setForeground(_ on: Bool) { foreground = on }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The cheap Claude file read always runs; Codex only when its interval has passed.
    public func refreshDue() async {
        await refreshClaude()
        let interval = foreground ? Self.foregroundInterval : Self.backgroundInterval
        if lastCodex.map({ now().timeIntervalSince($0) >= interval }) ?? true { await refreshCodex() }
    }

    public func refreshAll() async {
        await refreshClaude()
        await refreshCodex()
    }

    public func refreshClaude() async {
        guard let url = claudePlanURL else { return }
        let enabled = (claudeHook?() ?? .off) == .on
        try? await store.savePlanUsage(ClaudePlanFile.read(at: url, enabled: enabled, now: now()))
    }

    public func refreshCodex() async {
        guard let codex else { return }
        lastCodex = now()
        try? await store.savePlanUsage(await codex.read())
    }
}
