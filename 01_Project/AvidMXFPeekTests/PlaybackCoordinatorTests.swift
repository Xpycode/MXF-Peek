import Foundation
import Testing
@testable import AvidMXFPeek

// AVPlayer wiring is verified by manual QA (Wave P7). These tests cover the
// selection → cache → transcode pipeline up to the point of handing AVPlayer
// a URL. Tests that trigger the AVPlayer path (.playing) are out of scope here.

@MainActor
struct PlaybackCoordinatorTests {

    // MARK: - Fixture helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackCoordinatorTests-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stem(
        _ name: String,
        material: String = "MATERIAL-A",
        video: Int = 0,
        audio: Int = 0
    ) -> MXFHeaderInfo {
        MXFHeaderInfo(
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
            fileSize: 1_000_000,
            materialPackageUID: material,
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

    private func makeClip(
        id: String = "MATERIAL-A",
        videoStem: String = "V01.mxf",
        audioStems: [String] = ["A01.mxf", "A02.mxf"]
    ) -> Clip {
        var files: [MXFHeaderInfo] = [stem(videoStem, material: id, video: 1)]
        for a in audioStems { files.append(stem(a, material: id, audio: 1)) }
        return Clip(materialKey: id, files: files, isUngroupable: false)
    }

    /// Write stub HLS artefacts so the coordinator's file-existence gates pass.
    private func writeStubPlaylist(to outputDir: URL) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: outputDir.appendingPathComponent("playlist.m3u8"))
        try Data("stub".utf8).write(to: outputDir.appendingPathComponent("seg_000.m4s"))
    }

    // MARK: - Coordinator factory

    /// Build a coordinator wired to a real PreviewCache (temp dir) and a fake
    /// PreviewHTTPServer that immediately resolves to a loopback URL.
    /// The `transcode` closure is caller-supplied.
    private func makeCoordinator(
        scanModel: ScanModel,
        playbackState: PlaybackState,
        cacheRoot: URL,
        transcode: @escaping PlaybackCoordinator.TranscoderCall
    ) throws -> PlaybackCoordinator {
        let cache = try PreviewCache(rootDir: cacheRoot)
        let serverRoot = cacheRoot.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: serverRoot, withIntermediateDirectories: true)
        let server = try PreviewHTTPServer(rootDir: serverRoot)
        return PlaybackCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cache: cache,
            server: server,
            transcode: transcode
        )
    }

    // MARK: - Tests

    @Test func selectionIdToNilResetsState() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = try makeCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cacheRoot: root,
            transcode: { _, _, _, _ in AsyncStream { $0.finish() } }
        )

        coordinator.start()
        // Set a clip first to move away from idle.
        let clip = makeClip()
        scanModel.clips = [clip]
        scanModel.selectedClipID = clip.id
        // Immediately clear — tests the nil path before any transcode completes.
        scanModel.selectedClipID = nil

        try await Task.sleep(for: .milliseconds(80))

        if case .idle = playbackState.phase { } else {
            Issue.record("Expected .idle after nil selection, got \(playbackState.phase)")
        }
        #expect(playbackState.currentClipID == nil)
    }

    @Test func selectionOfUnknownClipIdFailsCleanly() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = try makeCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cacheRoot: root,
            transcode: { _, _, _, _ in AsyncStream { $0.finish() } }
        )

        coordinator.start()
        // clips is empty — any ID is unknown.
        scanModel.selectedClipID = "nonexistent-id"

        try await Task.sleep(for: .milliseconds(80))

        guard case .failed(let reason) = playbackState.phase else {
            Issue.record("Expected .failed, got \(playbackState.phase)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func cacheHitSkipsTranscode() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let clip = makeClip()
        scanModel.clips = [clip]

        // Pre-populate cache with a complete entry.
        let cache = try PreviewCache(rootDir: root)
        let cacheDir = try await cache.prepareOutputDir(for: clip)
        try writeStubPlaylist(to: cacheDir)
        try await cache.markComplete(for: clip)

        actor CallCounter { var count = 0; func bump() { count += 1 } }
        let callCounter = CallCounter()
        let serverRoot = root.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: serverRoot, withIntermediateDirectories: true)
        let server = try PreviewHTTPServer(rootDir: serverRoot)
        let coordinator = PlaybackCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cache: cache,
            server: server,
            transcode: { _, _, _, _ in
                AsyncStream { continuation in
                    Task { await callCounter.bump(); continuation.finish() }
                }
            }
        )

        coordinator.start()
        scanModel.selectedClipID = clip.id

        try await Task.sleep(for: .milliseconds(150))

        #expect(await callCounter.count == 0, "transcode must not be called on cache hit")
        // Phase advances to .preparing before handing off to AVPlayer;
        // .failed would indicate a regression in the cache-hit path.
        if case .failed(let r) = playbackState.phase {
            Issue.record("Unexpected failure on cache hit: \(r)")
        }
    }

    @Test func cacheMissSpawnsTranscode() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let clip = makeClip()
        scanModel.clips = [clip]

        actor CallCounter { var count = 0; func bump() { count += 1 } }
        let callCounter = CallCounter()
        let coordinator = try makeCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cacheRoot: root,
            transcode: { _, _, _, outputDir in
                AsyncStream { continuation in
                    Task {
                        await callCounter.bump()
                        try? FileManager.default.createDirectory(
                            at: outputDir, withIntermediateDirectories: true)
                        try? Data("stub".utf8).write(
                            to: outputDir.appendingPathComponent("playlist.m3u8"))
                        try? Data("stub".utf8).write(
                            to: outputDir.appendingPathComponent("seg_000.m4s"))
                        continuation.yield(.firstSegmentReady)
                        continuation.yield(.completed)
                        continuation.finish()
                    }
                }
            }
        )

        coordinator.start()
        scanModel.selectedClipID = clip.id

        try await Task.sleep(for: .milliseconds(200))

        #expect(await callCounter.count == 1, "transcode must be called exactly once on cache miss")
    }

    @Test func rapidSelectionChangesCancelPriorTranscode() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let clipA = makeClip(id: "CLIP-A", videoStem: "VA.mxf", audioStems: ["AA.mxf"])
        let clipB = makeClip(id: "CLIP-B", videoStem: "VB.mxf", audioStems: ["AB.mxf"])
        scanModel.clips = [clipA, clipB]

        // onTermination fires when the continuation is cancelled/finished.
        actor CancelTracker {
            var cancelledIDs: [String] = []
            func recordCancel(_ id: String) { cancelledIDs.append(id) }
        }
        let tracker = CancelTracker()

        let coordinator = try makeCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cacheRoot: root,
            transcode: { videoURL, _, _, _ in
                let stemName = videoURL.lastPathComponent
                return AsyncStream { continuation in
                    let capturedStem = stemName
                    continuation.onTermination = { _ in
                        Task { await tracker.recordCancel(capturedStem) }
                    }
                    // Hang indefinitely — simulates a slow transcode.
                    // The task will be cancelled by selection change.
                }
            }
        )

        coordinator.start()

        scanModel.selectedClipID = clipA.id
        // Minimal yield so onChange fires for A before we set B.
        try await Task.sleep(for: .milliseconds(20))

        scanModel.selectedClipID = clipB.id

        try await Task.sleep(for: .milliseconds(150))

        // clipA's stream must have been cancelled.
        let cancelled = await tracker.cancelledIDs
        #expect(cancelled.contains("VA.mxf"), "clipA transcode stream must be cancelled")
        #expect(playbackState.currentClipID == clipB.id)
    }

    @Test func observerReArmsAfterFirstFire() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let clip1 = makeClip(id: "CLIP-1", videoStem: "V1.mxf", audioStems: [])
        let clip2 = makeClip(id: "CLIP-2", videoStem: "V2.mxf", audioStems: [])
        let clip3 = makeClip(id: "CLIP-3", videoStem: "V3.mxf", audioStems: [])
        scanModel.clips = [clip1, clip2, clip3]

        actor ObservationCounter {
            var observedIDs: [String] = []
            func record(_ id: String) { observedIDs.append(id) }
        }
        let counter = ObservationCounter()

        // Each call to the transcode closure is a confirmed observation.
        let coordinator = try makeCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cacheRoot: root,
            transcode: { videoURL, _, _, _ in
                let id = videoURL.deletingPathExtension().lastPathComponent
                return AsyncStream { continuation in
                    Task {
                        await counter.record(id)
                        continuation.finish()
                    }
                }
            }
        )

        coordinator.start()

        scanModel.selectedClipID = clip1.id
        try await Task.sleep(for: .milliseconds(60))

        scanModel.selectedClipID = clip2.id
        try await Task.sleep(for: .milliseconds(60))

        scanModel.selectedClipID = clip3.id
        try await Task.sleep(for: .milliseconds(60))

        let observed = await counter.observedIDs
        // A broken re-arm observes only the first selection change.
        #expect(observed.count == 3,
                "all three selection changes must be observed; got \(observed)")
    }

    @Test func transcoderFailureMarksStateFailedAndCacheFailed() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let clip = makeClip()
        scanModel.clips = [clip]

        let cache = try PreviewCache(rootDir: root)
        let serverRoot = root.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: serverRoot, withIntermediateDirectories: true)
        let server = try PreviewHTTPServer(rootDir: serverRoot)
        let coordinator = PlaybackCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cache: cache,
            server: server,
            transcode: { _, _, _, _ in
                AsyncStream { continuation in
                    continuation.yield(.failed(reason: "test failure"))
                    continuation.finish()
                }
            }
        )

        coordinator.start()
        scanModel.selectedClipID = clip.id

        try await Task.sleep(for: .milliseconds(150))

        guard case .failed(let reason) = playbackState.phase else {
            Issue.record("Expected .failed, got \(playbackState.phase)")
            return
        }
        #expect(reason == "test failure")

        // Cache must record the failure so a future cache-hit won't return a broken dir.
        let state = await cache.state(for: clip)
        #expect(state?.status == .failed)
        #expect(state?.reason == "test failure")
    }

    @Test func stopCancelsInFlightTask() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let clip = makeClip()
        scanModel.clips = [clip]

        actor StopTracker {
            var streamTerminated = false
            func markTerminated() { streamTerminated = true }
        }
        let tracker = StopTracker()

        let coordinator = try makeCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cacheRoot: root,
            transcode: { _, _, _, _ in
                AsyncStream { continuation in
                    continuation.onTermination = { _ in
                        Task { await tracker.markTerminated() }
                    }
                    // Hang indefinitely — stop() must cancel this.
                }
            }
        )

        coordinator.start()
        scanModel.selectedClipID = clip.id
        // Let the transcode stream get established.
        try await Task.sleep(for: .milliseconds(60))

        coordinator.stop()
        try await Task.sleep(for: .milliseconds(100))

        let terminated = await tracker.streamTerminated
        #expect(terminated, "stop() must cancel the in-flight transcode stream")
    }

    // MARK: - Adversarial cases (Wave P8.1)

    @Test func videoOnlyClipProducesEmptyAudioPairs() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let clip = makeClip(id: "VIDEO-ONLY", audioStems: [])
        scanModel.clips = [clip]

        let coordinator = try makeCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cacheRoot: root,
            transcode: { _, _, _, outputDir in
                AsyncStream { cont in
                    try? Data("stub".utf8).write(to: outputDir.appendingPathComponent("playlist.m3u8"))
                    try? Data("stub".utf8).write(to: outputDir.appendingPathComponent("seg_000.m4s"))
                    cont.yield(.firstSegmentReady)
                    cont.finish()
                }
            }
        )

        coordinator.start()
        scanModel.selectedClipID = clip.id
        try await Task.sleep(for: .milliseconds(120))

        #expect(playbackState.audioPairs.isEmpty)
        #expect(playbackState.selectedPair == nil)
        if case .failed(let reason) = playbackState.phase {
            Issue.record("Video-only clip should not fail, got: \(reason)")
        }
    }

    @Test func oddAudioStemCountProducesFinalMonoPairWithoutFailure() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let clip = makeClip(id: "ODD-STEMS", audioStems: ["A01.mxf", "A02.mxf", "A03.mxf"])
        scanModel.clips = [clip]

        let coordinator = try makeCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cacheRoot: root,
            transcode: { _, _, _, outputDir in
                AsyncStream { cont in
                    try? Data("stub".utf8).write(to: outputDir.appendingPathComponent("master.m3u8"))
                    try? Data("stub".utf8).write(to: outputDir.appendingPathComponent("seg_000.m4s"))
                    cont.yield(.firstSegmentReady)
                    cont.finish()
                }
            }
        )

        coordinator.start()
        scanModel.selectedClipID = clip.id
        try await Task.sleep(for: .milliseconds(120))

        #expect(playbackState.audioPairs.count == 2)
        #expect(playbackState.audioPairs.last?.isMono == true)
        if case .failed(let reason) = playbackState.phase {
            Issue.record("Odd-stem clip should not fail, got: \(reason)")
        }
    }

    @Test func diskPreflightFailureMarksStateFailed() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Force preflight to fail by demanding more free space than any disk has.
        let cache = try PreviewCache(rootDir: root, minFreeBytesForWrite: .max)
        let serverRoot = root.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: serverRoot, withIntermediateDirectories: true)
        let server = try PreviewHTTPServer(rootDir: serverRoot)

        let coordinator = PlaybackCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cache: cache,
            server: server,
            transcode: { _, _, _, _ in AsyncStream { $0.finish() } }
        )

        let clip = makeClip()
        scanModel.clips = [clip]
        coordinator.start()
        scanModel.selectedClipID = clip.id
        try await Task.sleep(for: .milliseconds(120))

        guard case .failed(let reason) = playbackState.phase else {
            Issue.record("Expected .failed on disk preflight, got \(playbackState.phase)")
            return
        }
        #expect(reason.lowercased().contains("disk"))
    }

    @Test func shutdownSIGTERMsTrackedSubprocess() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let sleepProc = Process()
        sleepProc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleepProc.arguments = ["30"]
        try sleepProc.run()
        let pid = sleepProc.processIdentifier

        let clip = makeClip(id: "SHUTDOWN-CLIP")
        scanModel.clips = [clip]

        let coordinator = try makeCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cacheRoot: root,
            transcode: { _, _, _, outputDir in
                AsyncStream { cont in
                    cont.yield(.started(pid: pid))
                    try? Data("stub".utf8).write(to: outputDir.appendingPathComponent("playlist.m3u8"))
                    try? Data("stub".utf8).write(to: outputDir.appendingPathComponent("seg_000.m4s"))
                    cont.yield(.firstSegmentReady)
                }
            }
        )

        coordinator.start()
        scanModel.selectedClipID = clip.id
        try await Task.sleep(for: .milliseconds(100))

        #expect(sleepProc.isRunning, "sleep subprocess should still be alive before shutdown")

        await coordinator.shutdown()

        // Give kernel time to reap the child after SIGTERM/SIGKILL.
        for _ in 0..<20 {
            if !sleepProc.isRunning { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(!sleepProc.isRunning, "shutdown() must terminate tracked subprocesses")
    }

    @Test func fiveRapidSelectionsResolveToFinalClip() async throws {
        let scanModel = ScanModel()
        let playbackState = PlaybackState()
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let clips = (0..<5).map { makeClip(id: "CLIP-\($0)") }
        scanModel.clips = clips

        actor InvocationLog {
            var started: [String] = []
            var cancelled: [String] = []
            func recordStart(_ id: String) { started.append(id) }
            func recordCancel(_ id: String) { cancelled.append(id) }
        }
        let log = InvocationLog()

        let coordinator = try makeCoordinator(
            scanModel: scanModel,
            playbackState: playbackState,
            cacheRoot: root,
            transcode: { videoURL, _, _, outputDir in
                let id = videoURL.lastPathComponent
                return AsyncStream { cont in
                    Task { await log.recordStart(id) }
                    cont.onTermination = { _ in
                        Task { await log.recordCancel(id) }
                    }
                    // Hang until cancelled — except for whichever runs last,
                    // which we let complete so the pipeline reaches firstSegmentReady.
                }
            }
        )

        coordinator.start()
        for clip in clips {
            scanModel.selectedClipID = clip.id
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))

        let started = await log.started
        let cancelled = await log.cancelled
        #expect(started.count == 5, "all 5 selections should kick off a transcode")
        #expect(cancelled.count >= 4, "at least the first 4 transcodes must be cancelled")
        #expect(playbackState.currentClipID == clips.last?.id)
    }
}
