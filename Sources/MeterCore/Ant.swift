import Foundation

/// Why the Anthropic CLI could not give Meter a token or finish a login.
public enum AntError: Error, Equatable, Sendable {
    case notInstalled
    /// No usable credentials for the profile (never signed in, signed out, or the refresh token died).
    case notSignedIn
    case timedOut
    case cancelled
    /// The login ended without credentials. The text is plain language, never a token.
    case loginFailed(String)
}

/// What Meter needs from the Anthropic `ant` CLI (RESEARCH.md section 13). The CLI owns the credentials
/// and the refresh; Meter only asks for a fresh access token and keeps it in memory for one request.
public protocol AntAuth: Sendable {
    /// Absolute path to `ant`, or nil when it is not installed.
    func locate() async -> String?
    /// `ant auth print-credentials --profile <p> --access-token`, which refreshes an expiring token itself.
    func accessToken(profile: String) async throws -> String
    /// Browser sign-in with the `org:admin` scope. The CLI opens the browser. Cancelling the Task ends the CLI.
    func login(profile: String) async throws
    /// Revokes and removes the profile's stored credentials. Best effort.
    func logout(profile: String) async
}

public enum AntCommand {
    public static let installHint = "brew install anthropics/tap/ant"
    public static let tokenTimeout: TimeInterval = 15
    /// `ant auth login` waits 5 minutes for the browser by default; allow a little more.
    public static let loginTimeout: TimeInterval = 330

    /// `meter-<8 hex>`: one profile per connected organization, never the user's own.
    public static func newProfileName() -> String {
        "meter-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }
}

/// The real thing, over a `CommandRunner`. Tests give it a fake runner; nothing here is `ant`-specific
/// beyond argument lists taken from the CLI's own docs and source.
public struct AntCLI: AntAuth {
    private let locator: ToolLocator
    private let runner: any CommandRunner
    private let configDir: URL

    /// `configDir` is where `ant` keeps `active_config`: `$ANTHROPIC_CONFIG_DIR`, else `~/.config/anthropic`.
    public init(runner: any CommandRunner = ProcessCommandRunner(), locator: ToolLocator? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        let home = environment["HOME"] ?? NSHomeDirectory()
        self.locator = locator ?? ToolLocator(name: "ant", home: home, runner: runner)
        if let c = environment["ANTHROPIC_CONFIG_DIR"], !c.isEmpty {
            configDir = URL(fileURLWithPath: c, isDirectory: true)
        } else {
            configDir = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config/anthropic", isDirectory: true)
        }
    }

    public func locate() async -> String? { await locator.find() }

    public func accessToken(profile: String) async throws -> String {
        guard let ant = await locate() else { throw AntError.notInstalled }
        let r: CommandResult
        do {
            r = try await runner.run(ant, ["auth", "print-credentials", "--profile", profile, "--access-token"],
                                     timeout: AntCommand.tokenTimeout)
        } catch CommandError.timedOut { throw AntError.timedOut } catch is CancellationError { throw AntError.cancelled } catch {
            throw AntError.notSignedIn
        }
        // The CLI exits 0 with a stale token when a refresh fails, and prints errors on stderr. Only a
        // single token-shaped line on stdout counts.
        let token = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, token.count >= 16, !token.contains(where: \.isWhitespace) else { throw AntError.notSignedIn }
        return token
    }

    public func login(profile: String) async throws {
        guard let ant = await locate() else { throw AntError.notInstalled }
        // `--profile` makes the new profile the user's active one. Remember theirs and put it back.
        let previous = (try? String(contentsOf: configDir.appendingPathComponent("active_config"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let r: CommandResult
        do {
            r = try await runner.run(ant, ["auth", "login", "--profile", profile, "--scope", "org:admin"],
                                     timeout: AntCommand.loginTimeout)
        } catch CommandError.timedOut { throw AntError.timedOut } catch is CancellationError {
            await restoreActive(ant, previous: previous, profile: profile)
            throw AntError.cancelled
        } catch {
            throw AntError.loginFailed("Could not start the Anthropic CLI.")
        }
        await restoreActive(ant, previous: previous, profile: profile)
        guard r.status == 0 else {
            if r.stderr.localizedCaseInsensitiveContains("timed out") || r.stderr.localizedCaseInsensitiveContains("timeout") {
                throw AntError.timedOut
            }
            throw AntError.loginFailed("Sign-in did not finish. Try again.")
        }
        if r.stderr.contains("org:admin") && r.stderr.contains("not granted") {
            throw AntError.loginFailed("Your account needs the admin role in the Console organization.")
        }
    }

    /// Whatever happened, do not leave the admin profile as the user's default.
    private func restoreActive(_ ant: String, previous: String?, profile: String) async {
        let restore = (previous?.isEmpty == false) ? previous! : "default"
        guard restore != profile else { return }
        // Detached: after a cancelled login this Task is cancelled, and a cancelled Task would kill the command.
        await Task.detached { [runner] in
            _ = try? await runner.run(ant, ["profile", "activate", restore], timeout: AntCommand.tokenTimeout)
        }.value
    }

    public func logout(profile: String) async {
        guard let ant = await locate() else { return }
        _ = try? await runner.run(ant, ["auth", "logout", "--profile", profile], timeout: AntCommand.tokenTimeout)
    }
}
