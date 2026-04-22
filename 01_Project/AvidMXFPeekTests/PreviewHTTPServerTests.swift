import Foundation
import Testing
@testable import AvidMXFPeek

/// Tests for `PreviewHTTPServer` — the loopback HLS static-file server that
/// feeds the v1.2 preview pipeline (`PreviewTranscoder` → HLS segments →
/// AVPlayer). Covers the contract AVPlayer relies on: GET semantics, MIME
/// dispatch, byte-range (`Range: bytes=…` → `206 Partial Content`), and
/// clean multi-connection handling.
struct PreviewHTTPServerTests {

    // MARK: - Fixture helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewHTTPServerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ string: String, to url: URL) throws {
        try string.data(using: .utf8)!.write(to: url)
    }

    /// URLSession with caching disabled so successive GETs always hit the server.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: - Startup / teardown

    @Test func startReturnsLoopbackBaseURL() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try PreviewHTTPServer(rootDir: dir)
        let baseURL = try await server.start()

        #expect(baseURL.host == "127.0.0.1", "server must bind loopback only")
        #expect(baseURL.scheme == "http")
        #expect((baseURL.port ?? 0) > 0, "kernel-assigned port must be non-zero")

        await server.stop()
    }

    @Test func startThrowsOnMissingRoot() {
        let fakeDir = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            _ = try PreviewHTTPServer(rootDir: fakeDir)
        }
    }

    @Test func startIsIdempotent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try PreviewHTTPServer(rootDir: dir)
        let firstURL = try await server.start()
        let secondURL = try await server.start()
        #expect(firstURL == secondURL, "double-start returns cached baseURL")

        await server.stop()
    }

    // MARK: - Response semantics

    @Test func servesPlaylistWithHLSMimeType() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-ENDLIST\n"
        try write(playlist, to: dir.appendingPathComponent("playlist.m3u8"))

        let server = try PreviewHTTPServer(rootDir: dir)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("playlist.m3u8"))
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(String(data: data, encoding: .utf8) == playlist)
    }

    @Test func servesFMP4WithVideoMP4MimeType() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data((0..<2048).map { UInt8($0 % 256) })
        try bytes.write(to: dir.appendingPathComponent("seg_000.m4s"))

        let server = try PreviewHTTPServer(rootDir: dir)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("seg_000.m4s"))
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(data == bytes, "body must be byte-exact")
    }

    @Test func missingFileReturns404() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try PreviewHTTPServer(rootDir: dir)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        let (_, response) = try await session.data(from: baseURL.appendingPathComponent("does-not-exist.m3u8"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 404)
    }

    @Test func pathTraversalReturns403() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write("secret", to: dir.deletingLastPathComponent()
                                .appendingPathComponent("outside-\(UUID().uuidString).txt"))
        let server = try PreviewHTTPServer(rootDir: dir)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        // URLComponents would normalize `..` away — build the request URL raw.
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/..%2Fsecrets.txt"
        let url = components.url!

        let (_, response) = try await session.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 403)
    }

    // MARK: - Range support (load-bearing — see plan §10.2)

    @Test func rangeRequestReturns206WithContentRange() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data((0..<1000).map { UInt8($0 % 256) })
        try bytes.write(to: dir.appendingPathComponent("seg_000.m4s"))

        let server = try PreviewHTTPServer(rootDir: dir)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        var request = URLRequest(url: baseURL.appendingPathComponent("seg_000.m4s"))
        request.setValue("bytes=100-199", forHTTPHeaderField: "Range")

        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 100-199/1000")
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "100")
        #expect(data == bytes.subdata(in: 100..<200), "slice must match source bytes")
    }

    @Test func openEndedRangeClampsToFileEnd() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data((0..<1000).map { UInt8($0 % 256) })
        try bytes.write(to: dir.appendingPathComponent("seg_000.m4s"))

        let server = try PreviewHTTPServer(rootDir: dir)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        var request = URLRequest(url: baseURL.appendingPathComponent("seg_000.m4s"))
        request.setValue("bytes=900-", forHTTPHeaderField: "Range")

        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 900-999/1000")
        #expect(data.count == 100)
    }

    @Test func outOfBoundsRangeReturns416() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data(repeating: 0, count: 100)
        try bytes.write(to: dir.appendingPathComponent("seg_000.m4s"))

        let server = try PreviewHTTPServer(rootDir: dir)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        var request = URLRequest(url: baseURL.appendingPathComponent("seg_000.m4s"))
        request.setValue("bytes=500-600", forHTTPHeaderField: "Range")

        let (_, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 416)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes */100")
    }

    @Test func multiRangeReturns501() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data(repeating: 0, count: 1000)
        try bytes.write(to: dir.appendingPathComponent("seg_000.m4s"))

        let server = try PreviewHTTPServer(rootDir: dir)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        var request = URLRequest(url: baseURL.appendingPathComponent("seg_000.m4s"))
        request.setValue("bytes=0-99,200-299", forHTTPHeaderField: "Range")

        let (_, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 501)
    }

    // MARK: - Concurrency

    @Test func concurrentGETsDoNotDeadlock() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 10 small segments
        for i in 0..<10 {
            let bytes = Data(repeating: UInt8(i), count: 1024)
            try bytes.write(to: dir.appendingPathComponent(String(format: "seg_%03d.m4s", i)))
        }

        let server = try PreviewHTTPServer(rootDir: dir)
        let baseURL = try await server.start()
        defer { Task { await server.stop() } }

        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for i in 0..<10 {
                group.addTask { [session] in
                    let url = baseURL.appendingPathComponent(String(format: "seg_%03d.m4s", i))
                    let (data, response) = try await session.data(from: url)
                    let http = response as! HTTPURLResponse
                    return (http.statusCode, data.count)
                }
            }
            var count = 0
            for try await (status, size) in group {
                #expect(status == 200)
                #expect(size == 1024)
                count += 1
            }
            #expect(count == 10)
        }
    }

    // MARK: - Lifecycle

    @Test func stopAndRestartReassignsPort() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try PreviewHTTPServer(rootDir: dir)
        let url1 = try await server.start()
        await server.stop()

        // After stop, baseURL is nil
        let afterStop = await server.baseURL
        #expect(afterStop == nil)

        let url2 = try await server.start()
        #expect(url2.host == "127.0.0.1")
        // Port may be the same (kernel happens to reuse) or different — both valid.
        // What matters: server is serving again after restart.
        let (_, response) = try await session.data(from: url2.appendingPathComponent("any"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 404, "restarted server serves (404 expected for missing file)")
        _ = url1  // silence unused-variable

        await server.stop()
    }
}
