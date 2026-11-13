import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]

    public init(url: URL, method: String = "GET", headers: [String: String] = [:]) {
        self.url = url
        self.method = method
        self.headers = headers
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

/// The seam tests replace. Implementations throw for transport failures (offline, timeout).
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url, timeoutInterval: 30)
        r.httpMethod = request.method
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unexpectedResponse("not an HTTP response") }
        var headers = [String: String]()
        for (k, v) in http.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// Shared request plumbing for the two clients.
struct APIClientCore: Sendable {
    let transport: any HTTPTransport
    let baseURL: URL
    let provider: Provider
    let baseHeaders: [String: String]
    let looksAdmin: Bool

    func get(_ path: String, query: [(String, String)] = [], extraHeaders: [String: String] = [:]) async throws -> JSON {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        // URLComponents leaves "+" alone in values, and servers read it as a space. Page cursors are base64
        // and can contain "+", so encode it explicitly.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { throw ProviderError.unexpectedResponse("bad URL for \(path)") }
        var headers = baseHeaders
        for (k, v) in extraHeaders { headers[k] = v }
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(url: url, headers: headers))
        } catch let e as ProviderError {
            throw e
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        if let err = ProviderError.map(status: response.status, headers: response.headers, body: response.body,
                                       provider: provider, looksAdmin: looksAdmin) {
            throw err
        }
        do { return try JSON.parse(response.body) } catch {
            throw ProviderError.unexpectedResponse("invalid JSON from \(path)")
        }
    }

    /// Follows `has_more` with a cursor until done. Stops on a repeated cursor or after `maxPages`.
    func pages(maxPages: Int = 2_000, _ fetch: (String?) async throws -> (json: JSON, next: String?)) async throws -> [JSON] {
        var out = [JSON]()
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<maxPages {
            let (json, next) = try await fetch(cursor)
            out.append(json)
            guard json["has_more"].bool == true, let next, !next.isEmpty else { return out }
            guard seen.insert(next).inserted else {
                throw ProviderError.unexpectedResponse("pagination cursor repeated")
            }
            cursor = next
        }
        throw ProviderError.unexpectedResponse("too many pages")
    }
}
