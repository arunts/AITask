import Foundation

/// MCP "Streamable HTTP" transport: every JSON-RPC message is a POST; the reply is either a JSON
/// body or a short-lived SSE stream that ends once the matching response arrives.
nonisolated final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession

    private let lock = NSLock()
    private var sessionID: String?
    private var onMessage: (@Sendable (JSONValue) -> Void)?

    init(config: MCPServerConfig) throws {
        guard let url = URL(string: config.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MCPError.launchFailed("Enter a valid http(s) URL.")
        }
        self.url = url
        self.headers = config.parsedHeaders
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: configuration)
    }

    func start(
        onMessage: @escaping @Sendable (JSONValue) -> Void,
        onClose: @escaping @Sendable (String) -> Void
    ) async throws {
        lock.withLock { self.onMessage = onMessage }
    }

    func send(_ message: JSONValue) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(MCP.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let sessionID = lock.withLock({ sessionID }) {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = message.encoded()

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.invalidResponse("Not an HTTP response.")
        }
        if let newSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            lock.withLock { sessionID = newSessionID }
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 4096 { break }
            }
            throw MCPError.http(http.statusCode, String(decoding: body, as: UTF8.self))
        }
        if http.statusCode == 202 || http.statusCode == 204 { return }

        let handler = lock.withLock { onMessage }
        let expectedID = message["id"]
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        if contentType.contains("text/event-stream") {
            var dataLines: [String] = []
            func dispatch() -> Bool {
                guard !dataLines.isEmpty else { return false }
                let payload = dataLines.joined(separator: "\n")
                dataLines.removeAll()
                guard let json = try? JSONValue.parse(payload) else { return false }
                handler?(json)
                return JSONRPC.isResponse(json, to: expectedID)
            }
            for try await line in bytes.lines {
                if line.isEmpty {
                    if dispatch() { return }
                } else if line.hasPrefix("data:") {
                    var text = String(line.dropFirst(5))
                    if text.hasPrefix(" ") { text.removeFirst() }
                    dataLines.append(text)
                }
            }
            _ = dispatch()
        } else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            guard !body.isEmpty else { return }
            let json = try JSONValue.parse(body)
            if let batch = json.array {
                batch.forEach { handler?($0) }
            } else {
                handler?(json)
            }
        }
    }

    func close() async {
        guard let sessionID = lock.withLock({ sessionID }) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        _ = try? await session.data(for: request)
    }
}
