import Foundation
import Testing
@testable import AvidMXFPeek

/// Tests for `PreviewTranscoder` pure helpers: argument construction,
/// `out_time` parsing, and the first-segment-ready detector. These cover
/// the deterministic parts of the transcoder without launching ffmpeg —
/// the process-orchestration surface is exercised via the AsyncStream
/// consumer-side contract in Wave P6 integration tests.
struct PreviewTranscoderTests {

    // MARK: - Fixture helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewTranscoderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pair(id: Int, left: String, right: String, label: String) -> AudioPair {
        AudioPair(
            id: id,
            leftStemURL: URL(fileURLWithPath: "/tmp/\(left)"),
            rightStemURL: URL(fileURLWithPath: "/tmp/\(right)"),
            label: label
        )
    }

    private func monoPair(id: Int, stem: String, label: String) -> AudioPair {
        let url = URL(fileURLWithPath: "/tmp/\(stem)")
        return AudioPair(id: id, leftStemURL: url, rightStemURL: url, label: label)
    }

    // MARK: - parseOutTime

    @Test func parseOutTimeReturnsSecondsForWellFormed() {
        #expect(PreviewTranscoder.parseOutTime("00:00:00.500000") == 0.5)
        #expect(PreviewTranscoder.parseOutTime("00:00:01.000000") == 1.0)
        #expect(PreviewTranscoder.parseOutTime("01:30:00.250000") == 5400.25)
        #expect(PreviewTranscoder.parseOutTime("00:13:59.999999")! > 839.99)
    }

    @Test func parseOutTimeReturnsNilForMalformed() {
        #expect(PreviewTranscoder.parseOutTime("") == nil)
        #expect(PreviewTranscoder.parseOutTime("junk") == nil)
        #expect(PreviewTranscoder.parseOutTime("10:20") == nil)      // not enough parts
        #expect(PreviewTranscoder.parseOutTime("aa:bb:cc.dd") == nil) // not numeric
    }

    // MARK: - buildArgs shape

    @Test func buildArgsVideoOnlyHasNoFilterNoAudioMaps() throws {
        let outDir = try tempDir()
        defer { try? FileManager.default.removeItem(at: outDir) }

        let args = PreviewTranscoder.buildArgs(
            videoStemURL: URL(fileURLWithPath: "/tmp/V01.mxf"),
            audioPairs: [],
            outputDir: outDir
        )

        #expect(!args.contains("-filter_complex"),
                "video-only must not emit a filter graph")
        #expect(!args.contains("-var_stream_map"),
                "video-only must not emit var_stream_map")
        #expect(args.contains("playlist.m3u8") == false || args.last?.hasSuffix("playlist.m3u8") == true,
                "output playlist is at top level")
        #expect(args.contains("-c:v"))
        #expect(args.contains("h264_videotoolbox"))
    }

    @Test func buildArgsSinglePairHasFilterAndStereoMap() throws {
        let outDir = try tempDir()
        defer { try? FileManager.default.removeItem(at: outDir) }

        let args = PreviewTranscoder.buildArgs(
            videoStemURL: URL(fileURLWithPath: "/tmp/V01.mxf"),
            audioPairs: [pair(id: 0, left: "A01.mxf", right: "A02.mxf", label: "A01_A02")],
            outputDir: outDir
        )

        // Filter graph joins input indexes 1 (A01) and 2 (A02) into [pair0]
        let filterIdx = try #require(args.firstIndex(of: "-filter_complex"))
        let filterValue = args[filterIdx + 1]
        #expect(filterValue.contains("[1:a:0][2:a:0]join=inputs=2:channel_layout=stereo[pair0]"))

        // Audio mapping
        #expect(args.contains("[pair0]"))
        #expect(args.contains("-c:a:0"))
        #expect(args.contains("aac"))

        // Single-pair stays single-rendition (no var_stream_map)
        #expect(!args.contains("-var_stream_map"))
    }

    @Test func buildArgsMultiPairEmitsVarStreamMapAndMasterPlaylist() throws {
        let outDir = try tempDir()
        defer { try? FileManager.default.removeItem(at: outDir) }

        let args = PreviewTranscoder.buildArgs(
            videoStemURL: URL(fileURLWithPath: "/tmp/V01.mxf"),
            audioPairs: [
                pair(id: 0, left: "A01.mxf", right: "A02.mxf", label: "A01_A02"),
                pair(id: 1, left: "A03.mxf", right: "A04.mxf", label: "A03_A04"),
            ],
            outputDir: outDir
        )

        // var_stream_map present with both renditions + default flag on first
        let vsmIdx = try #require(args.firstIndex(of: "-var_stream_map"))
        let vsm = args[vsmIdx + 1]
        #expect(vsm.contains("v:0,agroup:aud"))
        #expect(vsm.contains("name:A01_A02"))
        #expect(vsm.contains("name:A03_A04"))
        #expect(vsm.contains("default:yes"), "first audio rendition must carry default:yes")

        // master playlist name
        let mpnIdx = try #require(args.firstIndex(of: "-master_pl_name"))
        #expect(args[mpnIdx + 1] == "master.m3u8")

        // Output path template uses %v for per-rendition subdir
        #expect(args.last?.contains("stream_%v/playlist.m3u8") == true)
        let segIdx = try #require(args.firstIndex(of: "-hls_segment_filename"))
        #expect(args[segIdx + 1].contains("stream_%v/seg_%03d.m4s"))
    }

    @Test func buildArgsMonoPairReusesSameInputOnBothChannels() throws {
        let outDir = try tempDir()
        defer { try? FileManager.default.removeItem(at: outDir) }

        let args = PreviewTranscoder.buildArgs(
            videoStemURL: URL(fileURLWithPath: "/tmp/V01.mxf"),
            audioPairs: [monoPair(id: 0, stem: "A01.mxf", label: "A01_mono")],
            outputDir: outDir
        )

        // Only one -i for A01 (since left == right, it's a unique stem just once)
        let inputCount = zip(args, args.dropFirst()).filter { $0.0 == "-i" && $0.1 == "/tmp/A01.mxf" }.count
        #expect(inputCount == 1, "mono pair uses the same -i input once")

        // Filter joins input 1 with itself
        let filterIdx = try #require(args.firstIndex(of: "-filter_complex"))
        #expect(args[filterIdx + 1].contains("[1:a:0][1:a:0]join"))
    }

    // MARK: - isFirstSegmentReady

    @Test func isFirstSegmentReadyFalseForEmptyDir() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PreviewTranscoder.isFirstSegmentReady(in: dir) == false)
    }

    @Test func isFirstSegmentReadyTrueWhenSingleRenditionArtifactsExist() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("#EXTM3U".utf8).write(to: dir.appendingPathComponent("playlist.m3u8"))
        try Data(count: 1024).write(to: dir.appendingPathComponent("seg_000.m4s"))
        #expect(PreviewTranscoder.isFirstSegmentReady(in: dir) == true)
    }

    @Test func isFirstSegmentReadyFalseWithOnlyPlaylist() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("#EXTM3U".utf8).write(to: dir.appendingPathComponent("playlist.m3u8"))
        #expect(PreviewTranscoder.isFirstSegmentReady(in: dir) == false)
    }

    @Test func isFirstSegmentReadyTrueForMultiRenditionLayout() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("#EXTM3U\n".utf8).write(to: dir.appendingPathComponent("master.m3u8"))
        let streamDir = dir.appendingPathComponent("stream_0")
        try FileManager.default.createDirectory(at: streamDir, withIntermediateDirectories: true)
        try Data("#EXTM3U\n".utf8).write(to: streamDir.appendingPathComponent("playlist.m3u8"))
        try Data(count: 1024).write(to: streamDir.appendingPathComponent("seg_000.m4s"))

        #expect(PreviewTranscoder.isFirstSegmentReady(in: dir) == true)
    }

    @Test func isFirstSegmentReadyFalseWithOnlyMasterPlaylist() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("#EXTM3U\n".utf8).write(to: dir.appendingPathComponent("master.m3u8"))
        #expect(PreviewTranscoder.isFirstSegmentReady(in: dir) == false)
    }
}
