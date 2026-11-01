import Foundation
import Network

/// A loopback-only HTTP adapter adds the source's Referer to nested HLS requests.
/// It runs on the iPhone, stops with the player, and has no laptop/cloud dependency.
actor HLSBridge {
    private let queue = DispatchQueue(label: "tv.guizado.hls.loopback")
    private let token = UUID().uuidString
    private let descriptor: StreamDescriptor
    private var listener: NWListener?
    private var pendingStart: CheckedContinuation<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var port: UInt16?
    private let session: URLSession

    init(_ descriptor: StreamDescriptor) {
        self.descriptor = descriptor
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }
    func start() async throws -> URL {
        if port != nil { return try localURL(descriptor.url) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        return try await withCheckedThrowingContinuation { continuation in
            pendingStart = continuation
            server.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            server.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state) } }
            server.start(queue: queue)
        }
    }
    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let number = listener?.port?.rawValue else { return }
            port = number
            do { pendingStart?.resume(returning: try localURL(descriptor.url)) }
            catch { pendingStart?.resume(throwing: error) }
            pendingStart = nil
        case .failed(let error): pendingStart?.resume(throwing: error); pendingStart = nil
        case .cancelled: pendingStart?.resume(throwing: CancellationError()); pendingStart = nil
        default: break
        }
    }
    private func localURL(_ remote: URL) throws -> URL {
        guard let port, Self.publicURL(remote) else { throw AppFailure.invalidURL }
        var parts = URLComponents(); parts.scheme = "http"; parts.host = "127.0.0.1"; parts.port = Int(port)
        let ext = remote.pathExtension.isEmpty ? "m3u8" : remote.pathExtension
        parts.path = "/\(token)/media.\(ext)"
        parts.queryItems = [URLQueryItem(name: "url", value: remote.absoluteString)]
        guard let url = parts.url else { throw AppFailure.invalidURL }; return url
    }
    nonisolated static func publicURL(_ url: URL) -> Bool {
        guard ["https", "http"].contains(url.scheme ?? ""), let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.contains(":") || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") || host == "0.0.0.0" { return false }
        let pieces = host.split(separator: ".")
        if pieces.count == 4, pieces[0] == "172", let second = Int(pieces[1]), (16...31).contains(second) { return false }
        return true
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 12 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; connection.start(queue: queue)
        Task { await handle(connection, id: id) }
    }
    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { bytes, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: complete ? AppFailure.invalidData : AppFailure.unavailable("Solicitud incompleta")) }
            }
        }
    }
    private func handle(_ connection: NWConnection, id: UUID) async {
        defer { connections.removeValue(forKey: id); connection.cancel() }
        do {
            var raw = Data()
            while raw.range(of: Data("\r\n\r\n".utf8)) == nil {
                raw.append(try await receive(connection)); if raw.count > 16_384 { throw AppFailure.tooLarge }
            }
            let requestText = String(decoding: raw, as: UTF8.self)
            let lines = requestText.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ").map(String.init)
            guard first.count == 3, ["GET", "HEAD"].contains(first[0]),
                  let parts = URLComponents(string: "http://127.0.0.1" + first[1]), parts.path.hasPrefix("/\(token)/"),
                  let address = parts.queryItems?.first(where: { $0.name == "url" })?.value,
                  let remote = URL(string: address), Self.publicURL(remote) else { throw AppFailure.invalidURL }
            var request = URLRequest(url: remote); request.httpMethod = first[0]
            request.setValue(CatalogService.userAgent, forHTTPHeaderField: "User-Agent")
            if !descriptor.referer.isEmpty { request.setValue(descriptor.referer, forHTTPHeaderField: "Referer") }
            for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
                request.setValue(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range")
            }
            let (bytes, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), bytes.count <= 32_000_000 else { throw AppFailure.unavailable("La señal no respondió") }
            var body = bytes
            var mime = response.mimeType ?? "application/octet-stream"
            let isPlaylist = bytes.starts(with: Data("#EXTM3U".utf8)) || mime.contains("mpegurl")
            if isPlaylist, first[0] != "HEAD" {
                let base = response.url ?? remote
                body = Data(try rewrite(String(decoding: bytes, as: UTF8.self), relativeTo: base).utf8)
                mime = "application/vnd.apple.mpegurl"
            }
            let length = first[0] == "HEAD" ? (response.value(forHTTPHeaderField: "Content-Length") ?? "0") : String(body.count)
            var headers = "HTTP/1.1 \(response.statusCode) OK\r\nContent-Type: \(mime)\r\nContent-Length: \(length)\r\nConnection: close\r\n"
            if !isPlaylist, let range = response.value(forHTTPHeaderField: "Content-Range") { headers += "Content-Range: \(range)\r\nAccept-Ranges: bytes\r\n" }
            headers += "\r\n"
            var packet = Data(headers.utf8); if first[0] != "HEAD" { packet.append(body) }
            try await send(packet, on: connection)
        } catch { try? await send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), on: connection) }
    }
    private func rewrite(_ playlist: String, relativeTo base: URL) throws -> String {
        let uri = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        return try playlist.components(separatedBy: .newlines).map { original in
            let line = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { return original }
            if !line.hasPrefix("#"), let remote = URL(string: line, relativeTo: base)?.absoluteURL, Self.publicURL(remote) { return try localURL(remote).absoluteString }
            var rewritten = original
            for match in uri.matches(in: original, range: NSRange(original.startIndex..., in: original)).reversed() {
                guard let range = Range(match.range(at: 1), in: rewritten), let remote = URL(string: String(rewritten[range]), relativeTo: base)?.absoluteURL, Self.publicURL(remote) else { continue }
                rewritten.replaceSubrange(range, with: try localURL(remote).absoluteString)
            }
            return rewritten
        }.joined(separator: "\n")
    }
    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func stop() {
        listener?.cancel(); listener = nil; port = nil
        pendingStart?.resume(throwing: CancellationError()); pendingStart = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        session.invalidateAndCancel()
    }
}
