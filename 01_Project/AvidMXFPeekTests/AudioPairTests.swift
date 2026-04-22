import Foundation
import Testing
@testable import AvidMXFPeek

/// Tests for `AudioPair.pairsFromClip` — the stem-to-stereo-pair grouping
/// used by the v1.2 preview transcoder. Ensures audio stems are grouped
/// deterministically (sort by filename) and odd counts fall back to mono.
struct AudioPairTests {

    // MARK: - Fixture helpers

    private func stem(_ name: String, video: Int = 0, audio: Int = 0) -> MXFHeaderInfo {
        MXFHeaderInfo(
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
            fileSize: 1_000_000,
            materialPackageUID: "MATERIAL",
            filePackageUID: nil,
            editRateNum: 25,
            editRateDen: 1,
            durationFrames: 250,
            videoTrackCount: video,
            audioTrackCount: audio,
            clipName: nil,
            projectName: nil,
            tapeName: nil,
            parseError: nil,
            parseDurationMs: nil
        )
    }

    private func clip(files: [MXFHeaderInfo]) -> Clip {
        ClipAggregator.aggregate(files).first!
    }

    // MARK: - Empty / video-only

    @Test func videoOnlyClipProducesNoPairs() {
        let c = clip(files: [stem("V01.EEEE_AAAAAAV.mxf", video: 1)])
        #expect(AudioPair.pairsFromClip(c) == [])
    }

    @Test func clipWithNoFilesProducesNoPairs() {
        // Build an ungroupable-but-somehow-empty scenario via direct construction
        let c = Clip(materialKey: "EMPTY", files: [], isUngroupable: false)
        #expect(AudioPair.pairsFromClip(c) == [])
    }

    // MARK: - Even-count pairing

    @Test func twoAudioStemsProduceOneStereoPair() {
        let c = clip(files: [
            stem("V01.EEEE_AAAAAAV.mxf", video: 1),
            stem("A01.EEEF_AAAAAAA.mxf", audio: 1),
            stem("A02.EEF0_AAAAAAB.mxf", audio: 1),
        ])
        let pairs = AudioPair.pairsFromClip(c)
        #expect(pairs.count == 1)
        #expect(pairs[0].id == 0)
        #expect(pairs[0].label == "A01_A02")
        #expect(pairs[0].isMono == false)
        #expect(pairs[0].leftStemURL.lastPathComponent.hasPrefix("A01"))
        #expect(pairs[0].rightStemURL.lastPathComponent.hasPrefix("A02"))
    }

    @Test func fourAudioStemsProduceTwoPairs() {
        let c = clip(files: [
            stem("V01.EEEE_AAAAAAV.mxf", video: 1),
            stem("A01.EEEF_AAAAAAA.mxf", audio: 1),
            stem("A02.EEF0_AAAAAAB.mxf", audio: 1),
            stem("A03.EEF1_AAAAAAC.mxf", audio: 1),
            stem("A04.EEF2_AAAAAAD.mxf", audio: 1),
        ])
        let pairs = AudioPair.pairsFromClip(c)
        #expect(pairs.count == 2)
        #expect(pairs.map(\.label) == ["A01_A02", "A03_A04"])
        #expect(pairs.map(\.id) == [0, 1])
        #expect(pairs.allSatisfy { !$0.isMono })
    }

    // MARK: - Odd-count fallback

    @Test func oddAudioStemCountProducesFinalMonoPair() {
        let c = clip(files: [
            stem("V01.EEEE_AAAAAAV.mxf", video: 1),
            stem("A01.EEEF_AAAAAAA.mxf", audio: 1),
            stem("A02.EEF0_AAAAAAB.mxf", audio: 1),
            stem("A03.EEF1_AAAAAAC.mxf", audio: 1),
        ])
        let pairs = AudioPair.pairsFromClip(c)
        #expect(pairs.count == 2)
        #expect(pairs[0].label == "A01_A02")
        #expect(pairs[0].isMono == false)
        #expect(pairs[1].label == "A03_mono")
        #expect(pairs[1].isMono == true)
        #expect(pairs[1].leftStemURL == pairs[1].rightStemURL)
    }

    @Test func singleAudioStemBecomesMonoPair() {
        let c = clip(files: [
            stem("V01.EEEE_AAAAAAV.mxf", video: 1),
            stem("A01.EEEF_AAAAAAA.mxf", audio: 1),
        ])
        let pairs = AudioPair.pairsFromClip(c)
        #expect(pairs.count == 1)
        #expect(pairs[0].isMono)
        #expect(pairs[0].label == "A01_mono")
    }

    // MARK: - Ordering

    @Test func audioStemsAreSortedByFilenameBeforePairing() {
        // Input out-of-order; pairs should still come out A01/A02, A03/A04.
        let c = clip(files: [
            stem("V01.EEEE_AAAAAAV.mxf", video: 1),
            stem("A04.EEF2_AAAAAAD.mxf", audio: 1),
            stem("A01.EEEF_AAAAAAA.mxf", audio: 1),
            stem("A03.EEF1_AAAAAAC.mxf", audio: 1),
            stem("A02.EEF0_AAAAAAB.mxf", audio: 1),
        ])
        let pairs = AudioPair.pairsFromClip(c)
        #expect(pairs.map(\.label) == ["A01_A02", "A03_A04"])
    }
}
