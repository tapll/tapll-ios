import Foundation

struct TransportResponse: Sendable {
    var status: Int
    var body: Data
    var retryAfter: TimeInterval?
}

protocol Transport: Sendable {
    func send(_ body: Data, writeKey: String) async throws -> TransportResponse
}

struct URLSessionTransport: Transport {
    let endpoint: URL
    let session: URLSession
    let userAgent: String

    init(endpoint: URL, session: URLSession? = nil, userAgent: String = SDKInfo.userAgent()) {
        self.endpoint = endpoint
        self.userAgent = userAgent
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    func send(_ body: Data, writeKey: String) async throws -> TransportResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(writeKey, forHTTPHeaderField: "x-tapll-key")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return TransportResponse(status: http?.statusCode ?? 0, body: data, retryAfter: retry)
    }
}
