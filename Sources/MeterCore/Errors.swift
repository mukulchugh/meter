import Foundation

public enum AuthProblem: Sendable, Equatable {
    /// 401 or 403 and the key does not carry the admin prefix.
    case notAdminKey
    /// 401 with an admin-looking key: expired or revoked.
    case invalidKey
    /// Anthropic 403 with an admin-looking key (RESEARCH.md section 0, item 2).
    case adminAPIUnavailable
    /// OpenAI 403 with an admin-looking key.
    case forbidden
    /// No secret stored for this org.
    case noKey
}

public enum ProviderError: Error, Equatable, Sendable {
    case auth(AuthProblem, Provider)
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case network(String)
    case badRequest(String)
    case notFound(String)
    case unexpectedResponse(String)

    /// Plain-language text for the UI and the coverage row.
    public var message: String {
        switch self {
        case .auth(let problem, let provider):
            let prefix = provider == .anthropic ? "sk-ant-admin01-" : "sk-admin-"
            switch problem {
            case .notAdminKey:
                return "This key isn't an admin key. Meter needs a \(provider.displayName) admin key (it starts with \(prefix))."
            case .invalidKey:
                return "\(provider.displayName) rejected the key. It may have expired or been revoked."
            case .adminAPIUnavailable:
                return "The Admin API isn't available for individual accounts. Use a Console organization where you are an admin."
            case .forbidden:
                return "This key can't read organization data. It must be an admin key created by an organization owner."
            case .noKey:
                return "No key is stored for this organization. Add one in Connections."
            }
        case .rateLimited(let after):
            if let after { return "Rate limited by the provider. Retrying in \(Int(after.rounded(.up))) seconds." }
            return "Rate limited by the provider. Retrying shortly."
        case .server(let status): return "The provider had a server problem (HTTP \(status))."
        case .network(let m): return "Couldn't reach the provider: \(m)"
        case .badRequest(let m): return "The provider rejected the request: \(m)"
        case .notFound(let m): return "Not found: \(m)"
        case .unexpectedResponse(let m): return "Unexpected response from the provider: \(m)"
        }
    }

    public var kind: String {
        switch self {
        case .auth: "auth"
        case .rateLimited: "rateLimited"
        case .server: "server"
        case .network: "network"
        case .badRequest: "badRequest"
        case .notFound: "notFound"
        case .unexpectedResponse: "unexpectedResponse"
        }
    }

    var isAuth: Bool { if case .auth = self { return true }; return false }
}

extension ProviderError {
    /// Maps an HTTP response to an error, or nil for 2xx. `looksAdmin` is whether the key has the
    /// documented admin prefix.
    static func map(status: Int, headers: [String: String], body: Data, provider: Provider, looksAdmin: Bool) -> ProviderError? {
        if (200..<300).contains(status) { return nil }
        let detail = errorMessage(from: body)
        switch status {
        case 401:
            return .auth(looksAdmin ? .invalidKey : .notAdminKey, provider)
        case 403:
            if !looksAdmin { return .auth(.notAdminKey, provider) }
            return .auth(provider == .anthropic ? .adminAPIUnavailable : .forbidden, provider)
        case 404:
            return .notFound(detail ?? "HTTP 404")
        case 400, 422:
            return .badRequest(detail ?? "HTTP \(status)")
        case 429:
            return .rateLimited(retryAfter: headers["retry-after"].flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        case 500...599:
            return .server(status: status)
        default:
            return .unexpectedResponse("HTTP \(status)")
        }
    }

    static func errorMessage(from body: Data) -> String? {
        guard let json = try? JSON.parse(body) else { return nil }
        // Anthropic: {"error":{"message":..}}  OpenAI: {"error":{"message":..}}
        return json["error"]["message"].string ?? json["message"].string
    }
}
