import Foundation
import Network

/// Loopback-only HTTP/1.1 server that serves files out of a root directory.
///
/// Feeds the v1.2 preview player: `PreviewTranscoder` writes HLS fMP4
/// segments into a cache directory; this server exposes that directory
/// to `AVPlayer` over `http://127.0.0.1:<port>/…`. No firewall / Local
/// Network prompt because loopback traffic doesn't transit either.
///
/// Scope: static files only, GET + HEAD semantics collapsed to GET,
/// single-range `bytes=` support (required — AVPlayer uses Range for
/// HLS duration probing, see docs/plans/2026-04-22-player-hls.md §10.2).
/// Multipart ranges return 501, the handful of status codes we need
/// return minimal headers.
///
/// The server is one-per-app-instance, owned by the `PlaybackCoordinator`
/// (Wave P6). Start lazily on first clip selection, stop on app quit.
actor PreviewHTTPServer {

    enum ServerError: Error, CustomStringConvertible {
        case invalidRootDirectory(path: String)
        case listenerFailedToStart(underlying: Error)

        var description: String {
            switch self {
            case .invalidRootDirectory(let p): return "Not a directory: \(p)"
            case .listenerFailedToStart(let e): return "Listener failed: \(e)"
            }
        }
    }

    /// Root directory whose contents are exposed over HTTP. Must exist and be a directory.
    nonisolated let rootDir: URL

    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private(set) var baseURL: URL?

    init(rootDir: URL) throws {
        let resolved = rootDir.standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw ServerError.invalidRootDirectory(path: resolved.path)
        }
        self.rootDir = resolved
    }

    /// Start the listener and return the loopback base URL once `.ready`.
    /// Idempotent: calling `start()` again after a successful start returns the cached URL.
    func start() async throws -> URL {
        if let url = baseURL { return url }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw ServerError.listenerFailedToStart(underlying: error)
        }
        self.listener = listener

        let capturedRoot = rootDir  // nonisolated let; safe to capture
        return try await withCheckedThrowingContinuation { continuation in
            self.startContinuation = continuation

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let rawPort = listener.port?.rawValue,
                       let url = URL(string: "http://127.0.0.1:\(rawPort)/") {
                        Task { await self.handleReady(url) }
                    }
                case .failed(let error):
                    Task { await self.handleFailed(error) }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { conn in
                Self.serve(connection: conn, rootDir: capturedRoot)
            }

            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Cancel the listener; `baseURL` becomes nil. Subsequent `start()` reopens.
    func stop() {
        listener?.cancel()
        listener = nil
        baseURL = nil
    }

    // MARK: - State transitions (actor-isolated)

    private func handleReady(_ url: URL) {
        baseURL = url
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(returning: url)
    }

    private func handleFailed(_ error: Error) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(throwing: ServerError.listenerFailedToStart(underlying: error))
    }

    // MARK: - Connection handling (nonisolated; only reads `rootDir`)

    /// Serves one connection: parse headers, map path to file, reply.
    private nonisolated static func serve(connection: NWConnection, rootDir: URL) {
        connection.start(queue: .global(qos: .userInitiated))
        readRequest(on: connection) { result in
            switch result {
            case .success(let request):
                handle(request, connection: connection, rootDir: rootDir)
            case .failure:
                write(status: 400, reason: "Bad Request", on: connection)
            }
        }
    }

    /// Accumulate bytes until we've seen `\r\n\r\n`; parse as HTTP/1.1 request.
    /// Hard-capped at 16 KB of request headers — oversized requests get 400.
    private nonisolated static func readRequest(
        on connection: NWConnection,
        accumulated: Data = Data(),
        completion: @Sendable @escaping (Result<Request, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            if error != nil {
                completion(.failure(ParseError.ioError))
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerBytes = buffer.subdata(in: 0..<terminator.lowerBound)
                guard let headerText = String(data: headerBytes, encoding: .utf8) else {
                    completion(.failure(ParseError.malformed))
                    return
                }
                completion(.success(Request.parse(headerText)))
                return
            }
            if isComplete || buffer.count > 16 * 1024 {
                completion(.failure(ParseError.malformed))
                return
            }
            readRequest(on: connection, accumulated: buffer, completion: completion)
        }
    }

    private enum ParseError: Error { case malformed, ioError }

    private struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]  // header names lowercased

        static func parse(_ text: String) -> Request {
            var lines = text.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { return Request(method: "", path: "", headers: [:]) }
            let requestLine = lines.removeFirst()
            let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            let method = parts.count > 0 ? String(parts[0]) : ""
            let path = parts.count > 1 ? String(parts[1]) : ""
            var headers: [String: String] = [:]
            for line in lines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
            return Request(method: method, path: path, headers: headers)
        }
    }

    private nonisolated static func handle(_ request: Request, connection: NWConnection, rootDir: URL) {
        guard request.method == "GET" else {
            write(status: 405, reason: "Method Not Allowed", on: connection)
            return
        }

        // Strip query string, percent-decode, defend against traversal
        var path = request.path
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if path.hasPrefix("/") { path.removeFirst() }
        path = path.removingPercentEncoding ?? path
        if path.contains("..") || path.hasPrefix("/") {
            write(status: 403, reason: "Forbidden", on: connection)
            return
        }

        let fileURL = rootDir.appendingPathComponent(path).standardizedFileURL
        guard fileURL.path.hasPrefix(rootDir.path + "/") || fileURL.path == rootDir.path else {
            write(status: 403, reason: "Forbidden", on: connection)
            return
        }

        guard let body = try? Data(contentsOf: fileURL) else {
            write(status: 404, reason: "Not Found", on: connection)
            return
        }

        let contentType = mimeType(for: fileURL.pathExtension)
        let total = body.count

        // Range request? (`Range: bytes=START-END`)
        if let rawRange = request.headers["range"], rawRange.hasPrefix("bytes=") {
            let spec = rawRange.dropFirst("bytes=".count)
            if spec.contains(",") {
                // Multipart byteranges not supported — RFC allows 501
                write(status: 501, reason: "Not Implemented", on: connection)
                return
            }
            let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let start = Int(parts[0]), start >= 0, start < total else {
                writeRangeNotSatisfiable(total: total, on: connection)
                return
            }
            let end: Int
            if parts.count == 2, !parts[1].isEmpty, let parsedEnd = Int(parts[1]) {
                end = min(parsedEnd, total - 1)
            } else {
                end = total - 1
            }
            guard start <= end else {
                writeRangeNotSatisfiable(total: total, on: connection)
                return
            }
            let slice = body.subdata(in: start..<(end + 1))
            send(
                status: 206, reason: "Partial Content",
                contentType: contentType,
                body: slice,
                extraHeaders: ["Content-Range": "bytes \(start)-\(end)/\(total)"],
                on: connection
            )
            return
        }

        // Full-file response
        send(status: 200, reason: "OK", contentType: contentType, body: body, on: connection)
    }

    // MARK: - Response writers

    private nonisolated static func send(
        status: Int,
        reason: String,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:],
        on connection: NWConnection
    ) {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-cache\r\n"
        for (name, value) in extraHeaders {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n\r\n"

        var reply = Data(header.utf8)
        reply.append(body)
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
    }

    private nonisolated static func write(status: Int, reason: String, on connection: NWConnection) {
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private nonisolated static func writeRangeNotSatisfiable(total: Int, on connection: NWConnection) {
        let header = """
            HTTP/1.1 416 Range Not Satisfiable\r\n\
            Content-Length: 0\r\n\
            Content-Range: bytes */\(total)\r\n\
            Connection: close\r\n\r\n
            """
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private nonisolated static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "m4s", "mp4": return "video/mp4"
        case "ts":         return "video/mp2t"
        default:           return "application/octet-stream"
        }
    }
}
