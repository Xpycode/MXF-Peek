import Foundation

/// Drives a single ffmpeg invocation that transcodes an Avid OP-Atom clip
/// (video stem + N audio stems) into live-mux HLS fMP4 for preview playback.
///
/// The transcoder is fire-and-forget: call `transcode(…)` and consume the
/// returned `AsyncStream<TranscodeEvent>`. Cancelling the consuming Task
/// sends `SIGTERM` to ffmpeg, waits up to 2 s, then `SIGKILL` if still alive.
///
/// Output layout depends on `audioPairs.count`:
/// - 0 pairs: video-only `playlist.m3u8` + `seg_NNN.m4s` in `outputDir`
/// - 1 pair:  single-rendition `playlist.m3u8` in `outputDir`, stereo embedded
/// - ≥2 pairs: `master.m3u8` + `stream_%v/playlist.m3u8` per rendition
///
/// The pipeline spec is `docs/plans/2026-04-22-player-hls.md` §2.2.
struct PreviewTranscoder {

    enum TranscodeEvent: Sendable, Equatable {
        case started(pid: Int32)
        case firstSegmentReady
        case progress(fraction: Double)
        case completed
        case failed(reason: String)
    }

    let ffmpegURL: URL

    init(ffmpegURL: URL) {
        self.ffmpegURL = ffmpegURL
    }

    /// Kick off a transcode. The returned stream yields events until ffmpeg
    /// exits or the consumer cancels. Consumer cancellation terminates ffmpeg.
    func transcode(
        videoStemURL: URL,
        audioPairs: [AudioPair],
        durationSeconds: Double?,
        outputDir: URL
    ) -> AsyncStream<TranscodeEvent> {
        let ffmpegURL = self.ffmpegURL
        return AsyncStream { continuation in
            let args = Self.buildArgs(
                videoStemURL: videoStemURL,
                audioPairs: audioPairs,
                outputDir: outputDir
            )
            let process = Process()
            process.executableURL = ffmpegURL
            process.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // stderr — accumulate into a reason buffer for .failed().
            let stderrBuffer = StderrBuffer()
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    stderrBuffer.append(text)
                }
            }

            // stdout — parse -progress key=value lines for out_time.
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n") {
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let key = line[..<eq]
                    let value = line[line.index(after: eq)...]
                    if key == "out_time", let elapsed = Self.parseOutTime(String(value)) {
                        if let duration = durationSeconds, duration > 0 {
                            let fraction = min(1.0, elapsed / duration)
                            continuation.yield(.progress(fraction: fraction))
                        }
                    }
                }
            }

            // firstSegmentReady polling (see plan §10.4).
            let readyTask = Task {
                while !Task.isCancelled {
                    if Self.isFirstSegmentReady(in: outputDir) {
                        continuation.yield(.firstSegmentReady)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }

            // Termination → emit completed/failed and finish the stream.
            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                readyTask.cancel()
                if proc.terminationStatus == 0 {
                    continuation.yield(.completed)
                } else {
                    let stderrSnapshot = stderrBuffer.snapshot()
                    let reason = stderrSnapshot.isEmpty
                        ? "ffmpeg exited with status \(proc.terminationStatus)"
                        : stderrSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.yield(.failed(reason: reason))
                }
                continuation.finish()
            }

            // Cancellation → SIGTERM, then SIGKILL after 2 s grace.
            continuation.onTermination = { _ in
                readyTask.cancel()
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }

            // Launch.
            do {
                try process.run()
                continuation.yield(.started(pid: process.processIdentifier))
            } catch {
                continuation.yield(.failed(reason: "failed to launch ffmpeg: \(error)"))
                continuation.finish()
            }
        }
    }

    // MARK: - Pure helpers (testable)

    /// Build the ffmpeg argument vector for one transcode job. Exposed as
    /// `internal static` so tests can exercise it without launching a process.
    static func buildArgs(
        videoStemURL: URL,
        audioPairs: [AudioPair],
        outputDir: URL
    ) -> [String] {
        var args: [String] = ["-y", "-loglevel", "error", "-progress", "pipe:1"]

        // Inputs: video first (index 0), then unique audio stems in first-use order.
        args.append(contentsOf: ["-i", videoStemURL.path])

        var audioStems: [URL] = []
        for pair in audioPairs {
            if !audioStems.contains(pair.leftStemURL)  { audioStems.append(pair.leftStemURL) }
            if !audioStems.contains(pair.rightStemURL) { audioStems.append(pair.rightStemURL) }
        }
        for stem in audioStems {
            args.append(contentsOf: ["-i", stem.path])
        }

        // filter_complex: one join per pair.
        if !audioPairs.isEmpty {
            var filters: [String] = []
            for (i, pair) in audioPairs.enumerated() {
                let leftIdx = (audioStems.firstIndex(of: pair.leftStemURL) ?? 0) + 1    // +1 because input 0 is video
                let rightIdx = (audioStems.firstIndex(of: pair.rightStemURL) ?? 0) + 1
                filters.append("[\(leftIdx):a:0][\(rightIdx):a:0]join=inputs=2:channel_layout=stereo[pair\(i)]")
            }
            args.append(contentsOf: ["-filter_complex", filters.joined(separator: "; ")])
        }

        // Video mapping + codec.
        args.append(contentsOf: [
            "-map", "0:v:0",
            "-c:v", "h264_videotoolbox",
            "-b:v", "4M",
            "-pix_fmt", "yuv420p",
        ])

        // Audio mappings — one per pair.
        for i in 0..<audioPairs.count {
            args.append(contentsOf: [
                "-map", "[pair\(i)]",
                "-c:a:\(i)", "aac",
                "-b:a:\(i)", "192k",
            ])
        }

        // HLS output shape.
        args.append(contentsOf: [
            "-hls_time", "4",
            "-hls_playlist_type", "event",
            "-hls_flags", "independent_segments+append_list",
            "-hls_segment_type", "fmp4",
        ])

        if audioPairs.count >= 2 {
            // Multi-rendition: master playlist + per-rendition subdirs.
            var mapParts = ["v:0,agroup:aud"]
            for (i, pair) in audioPairs.enumerated() {
                let isDefault = (i == 0) ? ",default:yes" : ""
                mapParts.append("a:\(i),agroup:aud,language:en,name:\(pair.label)\(isDefault)")
            }
            args.append(contentsOf: [
                "-var_stream_map", mapParts.joined(separator: " "),
                "-master_pl_name", "master.m3u8",
                "-hls_segment_filename", outputDir.appendingPathComponent("stream_%v/seg_%03d.m4s").path,
                "-f", "hls",
                outputDir.appendingPathComponent("stream_%v/playlist.m3u8").path,
            ])
        } else {
            // Single rendition (0 or 1 pair): single playlist at top level.
            args.append(contentsOf: [
                "-hls_segment_filename", outputDir.appendingPathComponent("seg_%03d.m4s").path,
                "-f", "hls",
                outputDir.appendingPathComponent("playlist.m3u8").path,
            ])
        }

        return args
    }

    /// Parse ffmpeg's `out_time=HH:MM:SS.ffffff` string into seconds.
    /// Returns nil for malformed input.
    static func parseOutTime(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let sec = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + sec
    }

    /// Check whether the output directory has a playlist + at least one segment,
    /// i.e. AVPlayer can now open it. Covers both single-rendition and
    /// multi-rendition (master.m3u8) layouts.
    static func isFirstSegmentReady(in outputDir: URL) -> Bool {
        let fm = FileManager.default

        // Single-rendition layout
        let topPlaylist = outputDir.appendingPathComponent("playlist.m3u8")
        let topFirstSeg = outputDir.appendingPathComponent("seg_000.m4s")
        if fm.fileExists(atPath: topPlaylist.path) && fm.fileExists(atPath: topFirstSeg.path) {
            return true
        }

        // Multi-rendition layout
        let master = outputDir.appendingPathComponent("master.m3u8")
        guard fm.fileExists(atPath: master.path) else { return false }
        guard let entries = try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil) else {
            return false
        }
        for entry in entries where entry.lastPathComponent.hasPrefix("stream_") {
            let seg = entry.appendingPathComponent("seg_000.m4s")
            if fm.fileExists(atPath: seg.path) { return true }
        }
        return false
    }
}

// Small thread-safe string accumulator for stderr capture.
// `Pipe.readabilityHandler` fires on an internal queue, so we serialize appends.
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        text += s
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}
