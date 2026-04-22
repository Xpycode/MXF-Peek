import Foundation
import Testing
@testable import AvidMXFPeek

/// Tests for `PreviewCache` — hash stability, state-file round-trip, LRU
/// eviction, disk-space preflight. The cache is the durability layer under
/// the v1.2 preview pipeline; test coverage matters because a buggy cache
/// can silently serve stale content to AVPlayer.
struct PreviewCacheTests {

    // MARK: - Fixture helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stem(_ name: String, size: Int64 = 1_000_000, video: Int = 0, audio: Int = 0) -> MXFHeaderInfo {
        MXFHeaderInfo(
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
            fileSize: size,
            materialPackageUID: "MATERIAL-A",
            filePackageUID: nil,
            editRateNum: 25,
            editRateDen: 1,
            durationFrames: 250,
            videoTrackCount: video,
            audioTrackCount: audio,
            clipName: nil, projectName: nil, tapeName: nil,
            parseError: nil, parseDurationMs: nil
        )
    }

    private func clip(materialKey: String = "MATERIAL-A", files: [MXFHeaderInfo]) -> Clip {
        Clip(materialKey: materialKey, files: files, isUngroupable: false)
    }

    private func fillWithBytes(_ dir: URL, count: Int) throws {
        // Drop a single dummy segment to simulate transcode output.
        try Data(count: count).write(to: dir.appendingPathComponent("seg_000.m4s"))
    }

    // MARK: - Hashing

    @Test func hashIsStableAcrossIdenticalInputs() {
        let c1 = clip(files: [stem("A01.mxf", size: 100), stem("V01.mxf", size: 200, video: 1)])
        let c2 = clip(files: [stem("V01.mxf", size: 200, video: 1), stem("A01.mxf", size: 100)])
        #expect(PreviewCache.hashKey(for: c1) == PreviewCache.hashKey(for: c2),
                "hash must be order-independent on clip.files")
        #expect(PreviewCache.hashKey(for: c1).count == 16)
    }

    @Test func hashChangesWhenFileSizeChanges() {
        let c1 = clip(files: [stem("A01.mxf", size: 100)])
        let c2 = clip(files: [stem("A01.mxf", size: 200)])
        #expect(PreviewCache.hashKey(for: c1) != PreviewCache.hashKey(for: c2))
    }

    @Test func hashChangesWhenFilePathChanges() {
        let c1 = clip(files: [stem("A01.mxf", size: 100)])
        let c2 = clip(files: [stem("A02.mxf", size: 100)])
        #expect(PreviewCache.hashKey(for: c1) != PreviewCache.hashKey(for: c2))
    }

    @Test func hashChangesWhenMaterialKeyChanges() {
        let c1 = clip(materialKey: "FOO", files: [stem("A01.mxf", size: 100)])
        let c2 = clip(materialKey: "BAR", files: [stem("A01.mxf", size: 100)])
        #expect(PreviewCache.hashKey(for: c1) != PreviewCache.hashKey(for: c2))
    }

    // MARK: - prepareOutputDir / pathIfCached

    @Test func prepareOutputDirCreatesDirectoryAndRunningState() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try PreviewCache(rootDir: root)
        let c = clip(files: [stem("A01.mxf")])
        let dir = try await cache.prepareOutputDir(for: c)

        #expect(FileManager.default.fileExists(atPath: dir.path))
        let state = try #require(await cache.state(for: c))
        #expect(state.status == .running)
    }

    @Test func prepareOutputDirWipesPriorContents() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try PreviewCache(rootDir: root)
        let c = clip(files: [stem("A01.mxf")])

        let dir1 = try await cache.prepareOutputDir(for: c)
        try fillWithBytes(dir1, count: 100)
        #expect(FileManager.default.fileExists(atPath: dir1.appendingPathComponent("seg_000.m4s").path))

        // Second prepareOutputDir must wipe the old seg.
        let dir2 = try await cache.prepareOutputDir(for: c)
        #expect(dir1 == dir2)
        #expect(FileManager.default.fileExists(atPath: dir2.appendingPathComponent("seg_000.m4s").path) == false)
    }

    @Test func prepareOutputDirThrowsWhenDiskFull() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Unrealistically huge preflight → fails on any real disk.
        let cache = try PreviewCache(rootDir: root, minFreeBytesForWrite: Int64.max)
        let c = clip(files: [stem("A01.mxf")])

        await #expect(throws: PreviewCache.CacheError.self) {
            _ = try await cache.prepareOutputDir(for: c)
        }
    }

    @Test func pathIfCachedReturnsNilForMissingEntry() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try PreviewCache(rootDir: root)
        let c = clip(files: [stem("A01.mxf")])
        let result = await cache.pathIfCached(for: c)
        #expect(result == nil)
    }

    @Test func pathIfCachedReturnsNilForRunningEntry() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try PreviewCache(rootDir: root)
        let c = clip(files: [stem("A01.mxf")])
        _ = try await cache.prepareOutputDir(for: c)
        let result = await cache.pathIfCached(for: c)
        #expect(result == nil, "running entries must not report as cached")
    }

    @Test func pathIfCachedReturnsNilForFailedEntry() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try PreviewCache(rootDir: root)
        let c = clip(files: [stem("A01.mxf")])
        _ = try await cache.prepareOutputDir(for: c)
        try await cache.markFailed(for: c, reason: "ffmpeg died")
        let result = await cache.pathIfCached(for: c)
        #expect(result == nil)

        let state = try #require(await cache.state(for: c))
        #expect(state.status == .failed)
        #expect(state.reason == "ffmpeg died")
    }

    @Test func pathIfCachedReturnsURLForCompleteEntry() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try PreviewCache(rootDir: root)
        let c = clip(files: [stem("A01.mxf")])
        let prepared = try await cache.prepareOutputDir(for: c)
        try await cache.markComplete(for: c)
        let cached = await cache.pathIfCached(for: c)
        #expect(cached == prepared)
    }

    // MARK: - Eviction

    @Test func evictToFitNoopWhenUnderBudget() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try PreviewCache(rootDir: root)
        let c = clip(files: [stem("A01.mxf")])
        let dir = try await cache.prepareOutputDir(for: c)
        try fillWithBytes(dir, count: 100)
        try await cache.markComplete(for: c)

        let removed = await cache.evictToFit(budgetBytes: 10_000_000)
        #expect(removed == 0)
        let cached = await cache.pathIfCached(for: c)
        #expect(cached != nil, "under-budget clips must not be evicted")
    }

    @Test func evictToFitRemovesOldestCompleteEntriesFirst() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try PreviewCache(rootDir: root)
        let old = clip(materialKey: "OLD", files: [stem("A01.mxf")])
        let middle = clip(materialKey: "MID", files: [stem("A01.mxf")])
        let newest = clip(materialKey: "NEW", files: [stem("A01.mxf")])

        // Create complete entries with explicit timestamps — avoids parallel-
        // test scheduling flakiness where `Task.sleep` between markComplete
        // calls may not produce distinct timestamps under load.
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for (offset, c) in [(0, old), (100, middle), (200, newest)] {
            let dir = try await cache.prepareOutputDir(for: c)
            try fillWithBytes(dir, count: 500_000)
            try await cache.markComplete(for: c)
            try writeStateDirectly(
                dir: dir,
                status: .complete,
                accessedAt: base.addingTimeInterval(TimeInterval(offset))
            )
        }

        // Total ≈ 1.5 MB + state files; budget 800 KB → eviction to 80% = 640 KB.
        // Should evict oldest first, then next, until under 640 KB.
        let removed = await cache.evictToFit(budgetBytes: 800_000)
        #expect(removed >= 1, "at least oldest must be evicted")

        let oldCached = await cache.pathIfCached(for: old)
        let newestCached = await cache.pathIfCached(for: newest)
        #expect(oldCached == nil, "oldest complete entry evicted")
        #expect(newestCached != nil, "newest entry retained")
    }

    /// Test helper: write a transcode-state file with explicit timestamps,
    /// bypassing PreviewCache's Date()-based markers.
    private func writeStateDirectly(
        dir: URL,
        status: PreviewCache.TranscodeState.Status,
        accessedAt: Date,
        startedAt: Date? = nil
    ) throws {
        let state = PreviewCache.TranscodeState(
            status: status,
            pid: nil,
            startedAt: startedAt ?? accessedAt,
            accessedAt: accessedAt,
            reason: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: dir.appendingPathComponent(".transcode-state"), options: .atomic)
    }

    @Test func evictToFitDoesNotTouchRunningEntries() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = try PreviewCache(rootDir: root)
        let running = clip(materialKey: "RUNNING", files: [stem("A01.mxf")])
        let complete = clip(materialKey: "COMPLETE", files: [stem("A02.mxf")])

        let runningDir = try await cache.prepareOutputDir(for: running)
        try fillWithBytes(runningDir, count: 1_000_000)
        // Deliberately do NOT markComplete — stays .running.

        try await Task.sleep(nanoseconds: 20_000_000)

        let completeDir = try await cache.prepareOutputDir(for: complete)
        try fillWithBytes(completeDir, count: 1_000_000)
        try await cache.markComplete(for: complete)

        // Budget under total — must evict complete (which is NEWER) rather than running (OLDER).
        _ = await cache.evictToFit(budgetBytes: 100_000)

        let runningState = await cache.state(for: running)
        #expect(runningState?.status == .running, "running entry must survive eviction")
        #expect(FileManager.default.fileExists(atPath: runningDir.path))

        let completeCached = await cache.pathIfCached(for: complete)
        #expect(completeCached == nil, "complete entry was evicted despite being newer")
    }
}
