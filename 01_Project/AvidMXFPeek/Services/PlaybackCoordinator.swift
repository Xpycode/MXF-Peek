import AVFoundation
import Darwin
import Foundation
import Observation

/// Drives the v1.2 preview player pipeline: observe selection → cache lookup →
/// transcode if miss → serve over HTTP → hand AVPlayer a playlist URL.
///
/// Owns the loopback HTTP server and the transcode task lifecycle. Rapid
/// selection changes cancel the previous preparation task (structured-
/// concurrency supersedence pattern — see §11.2 of the plan).
///
/// See `docs/plans/2026-04-22-player-hls.md` §P6.2 + §P6.4 + §11.
@MainActor
@Observable
final class PlaybackCoordinator {

    // MARK: - Dependencies

    private let scanModel: ScanModel
    private let playbackState: PlaybackState
    private let cache: PreviewCache
    private let server: PreviewHTTPServer
    typealias TranscodeStream = AsyncStream<PreviewTranscoder.TranscodeEvent>
    typealias TranscoderCall = @Sendable (URL, [AudioPair], Double?, URL) -> TranscodeStream
    private let transcode: TranscoderCall

    // MARK: - Private state

    /// Handle for the in-flight prepare task. Cancelling this also tears down
    /// the AVPlayerItem.status observer, which runs inside the same task tree.
    private var currentPrepTask: Task<Void, Never>?

    /// PIDs of currently-running ffmpeg subprocesses, tracked from `.started`
    /// events. Used by `shutdown()` to fan out SIGTERM at app-quit time so
    /// children don't get reparented to launchd. See plan §P8.4.
    private var activePIDs: Set<pid_t> = []

    // MARK: - Init

    init(
        scanModel: ScanModel,
        playbackState: PlaybackState,
        cache: PreviewCache,
        server: PreviewHTTPServer,
        transcode: @escaping TranscoderCall
    ) {
        self.scanModel = scanModel
        self.playbackState = playbackState
        self.cache = cache
        self.server = server
        self.transcode = transcode
    }

    /// Convenience init for production use. Resolves ffmpeg from the bundle.
    convenience init(
        scanModel: ScanModel,
        playbackState: PlaybackState,
        cache: PreviewCache,
        server: PreviewHTTPServer
    ) {
        let resolver = BundledToolResolver.shared
        let url = resolver.path(for: .ffmpeg) ?? URL(fileURLWithPath: "/dev/null")
        let transcoder = PreviewTranscoder(ffmpegURL: url)
        self.init(
            scanModel: scanModel,
            playbackState: playbackState,
            cache: cache,
            server: server,
            transcode: { videoURL, pairs, duration, outputDir in
                transcoder.transcode(
                    videoStemURL: videoURL,
                    audioPairs: pairs,
                    durationSeconds: duration,
                    outputDir: outputDir
                )
            }
        )
    }

    // MARK: - Lifecycle

    /// Begin observing `scanModel.selectedClipID`. Call once at app launch.
    func start() {
        observeSelection()
    }

    /// Tear down: cancel in-flight work, pause player, stop HTTP server.
    func stop() {
        currentPrepTask?.cancel()
        currentPrepTask = nil
        playbackState.player?.pause()
        Task { await server.stop() }
    }

    /// Async shutdown for app-quit. Synchronously SIGTERMs all tracked ffmpeg
    /// children, waits 500 ms (10× ffmpeg's HLS ENDLIST flush time per spike
    /// P1.2), then SIGKILLs any survivor. Caller awaits before replying
    /// `.terminateNow` to AppKit. See plan §P8.4 + §11 research notes.
    func shutdown() async {
        currentPrepTask?.cancel()
        currentPrepTask = nil
        playbackState.player?.pause()

        let pids = activePIDs
        activePIDs.removeAll()
        for pid in pids { _ = kill(pid, SIGTERM) }

        try? await Task.sleep(nanoseconds: 500_000_000)

        for pid in pids { _ = kill(pid, SIGKILL) }

        await server.stop()
    }

    /// Tail-drain hook for the detached tail consumer. Removes a pid from the
    /// active set after the transcode emits `.completed` / `.failed`.
    fileprivate func removeActivePID(_ pid: pid_t) {
        activePIDs.remove(pid)
    }

    // MARK: - Selection observation

    /// `withObservationTracking` fires exactly once then detaches. The re-arm
    /// inside `onChange` is load-bearing — without it only the first selection
    /// change after launch is observed (§11.1).
    private func observeSelection() {
        withObservationTracking {
            _ = scanModel.selectedClipID
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleSelectionChange()
                self?.observeSelection()   // re-arm
            }
        }
    }

    @MainActor
    private func handleSelectionChange() {
        currentPrepTask?.cancel()
        currentPrepTask = nil

        guard let clipID = scanModel.selectedClipID else {
            playbackState.reset()
            playbackState.player?.replaceCurrentItem(with: nil)
            return
        }

        currentPrepTask = Task { [weak self] in
            await self?.prepare(for: clipID)
        }
    }

    // MARK: - Prepare pipeline

    private func prepare(for clipID: Clip.ID) async {
        guard let clip = scanModel.clips.first(where: { $0.id == clipID }) else {
            playbackState.phase = .failed("Clip not found")
            return
        }

        // Publish audio pairs early so the picker can render while the first
        // segment is still being transcoded.
        let pairs = AudioPair.pairsFromClip(clip)
        playbackState.audioPairs = pairs
        playbackState.selectedPair = pairs.first
        playbackState.currentClipID = clipID

        let preparingStartedAt = Date()
        playbackState.phase = .preparing(startedAt: preparingStartedAt, progress: nil)

        // Ensure the loopback server is running (idempotent).
        let baseURL: URL
        do {
            baseURL = try await server.start()
        } catch {
            playbackState.phase = .failed("HTTP server failed to start: \(error.localizedDescription)")
            return
        }

        guard !Task.isCancelled else { return }

        let hashKey = PreviewCache.hashKey(for: clip)

        if await cache.pathIfCached(for: clip) == nil {
            // Cache miss: prepare directory and spawn ffmpeg.
            let preparedDir: URL
            do {
                preparedDir = try await cache.prepareOutputDir(for: clip, pid: nil)
            } catch {
                playbackState.phase = .failed("Disk preflight failed: \(error.localizedDescription)")
                return
            }

            guard !Task.isCancelled else { return }

            guard let videoStemURL = clip.files.first(where: { $0.videoTrackCount > 0 })?.fileURL else {
                playbackState.phase = .failed("No video stem found in clip")
                return
            }

            let events = transcode(videoStemURL, pairs, clip.durationSeconds, preparedDir)

            // Consume events until firstSegmentReady, then hand the stream to a
            // background task so .completed / .failed still reaches the cache even
            // after we unblock AVPlayer setup below.
            var iterator = events.makeAsyncIterator()
            var firstSegmentSeen = false

            var trackedPID: pid_t?

            while let event = await iterator.next() {
                guard !Task.isCancelled else { return }
                switch event {
                case .started(let pid):
                    trackedPID = pid
                    activePIDs.insert(pid)
                case .progress(let fraction):
                    playbackState.phase = .preparing(startedAt: preparingStartedAt, progress: fraction)
                case .firstSegmentReady:
                    firstSegmentSeen = true
                case .completed:
                    if let pid = trackedPID { activePIDs.remove(pid); trackedPID = nil }
                    try? await cache.markComplete(for: clip)
                    firstSegmentSeen = true
                case .failed(let reason):
                    if let pid = trackedPID { activePIDs.remove(pid); trackedPID = nil }
                    try? await cache.markFailed(for: clip, reason: reason)
                    playbackState.phase = .failed(reason)
                    return
                }
                if firstSegmentSeen { break }
            }

            guard firstSegmentSeen else {
                // Stream ended without firstSegmentReady — transcode was cancelled or silent-failed.
                return
            }

            // Drain the tail (remaining .progress, .completed, .failed) off the main path.
            let tailPID = trackedPID
            Task.detached { [cache, clip, weak self] in
                var iter = iterator
                while let event = await iter.next() {
                    switch event {
                    case .completed:
                        try? await cache.markComplete(for: clip)
                        if let pid = tailPID { await self?.removeActivePID(pid) }
                    case .failed(let reason):
                        try? await cache.markFailed(for: clip, reason: reason)
                        if let pid = tailPID { await self?.removeActivePID(pid) }
                    default:
                        break
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }

        // Choose the playlist filename based on whether multiple audio pairs exist.
        // ≥2 pairs → master.m3u8 (multi-rendition); ≤1 pair → playlist.m3u8 (single rendition).
        let playlistName = pairs.count >= 2 ? "master.m3u8" : "playlist.m3u8"
        let playlistURL = baseURL.appendingPathComponent("\(hashKey)/\(playlistName)")

        let asset = AVURLAsset(url: playlistURL)
        let item = AVPlayerItem(asset: asset)

        if let existing = playbackState.player {
            existing.replaceCurrentItem(with: item)
        } else {
            let player = AVPlayer(playerItem: item)
            // Start immediately on readyToPlay rather than waiting for AVPlayer's
            // internal stall-avoidance buffer — appropriate for loopback HTTP with
            // negligible latency. See plan §7 learnings.
            player.automaticallyWaitsToMinimizeStalling = false
            playbackState.player = player
        }

        playbackState.player?.play()

        // Observe AVPlayerItem.status inside this task so the observer is cancelled
        // automatically when selection changes (§P6.4, §11.3).
        await observePlayerItemStatus(item, asset: asset)
    }

    // MARK: - AVPlayerItem status observer (§P6.4)

    /// KVO-to-AsyncSequence bridge. Runs until item reaches a terminal status
    /// or the enclosing Task is cancelled on selection change.
    private func observePlayerItemStatus(_ item: AVPlayerItem, asset: AVURLAsset) async {
        for await _ in item.publisher(for: \.status).values {
            switch item.status {
            case .readyToPlay:
                playbackState.phase = .playing
                if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
                    playbackState.audibleGroup = group
                }
                return  // terminal success
            case .failed:
                playbackState.phase = .failed(item.error?.localizedDescription ?? "Unknown player error")
                return  // terminal failure
            case .unknown:
                break
            @unknown default:
                break
            }

            if Task.isCancelled { return }
        }
    }

    // MARK: - Audio pair switching

    /// Route the player to a different HLS audio rendition without re-transcoding.
    func selectPair(_ pair: AudioPair) {
        guard let group = playbackState.audibleGroup,
              let item = playbackState.player?.currentItem else { return }

        // Match rendition by label. ffmpeg writes the pair label as the HLS
        // rendition name via `-var_stream_map name:<label>`.
        let matched = group.options.first { $0.displayName.contains(pair.label) }
        guard let option = matched else { return }

        item.select(option, in: group)
        playbackState.selectedPair = pair
    }
}
