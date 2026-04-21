import Foundation
import Testing
@testable import AvidMXFPeek

/// Tests for `ClipAggregator.aggregate` — the pure function that groups a flat
/// `[MXFHeaderInfo]` into logical `[Clip]` by `materialPackageUID`.
struct ClipAggregatorTests {

    // MARK: - Helpers

    private func info(
        path: String,
        material: String?,
        file: String? = nil,
        video: Int = 0,
        audio: Int = 0,
        name: String? = nil,
        project: String? = "PEEKY",
        size: Int64 = 1_000_000
    ) -> MXFHeaderInfo {
        MXFHeaderInfo(
            fileURL: URL(fileURLWithPath: path),
            fileSize: size,
            materialPackageUID: material,
            filePackageUID: file,
            editRateNum: 25,
            editRateDen: 1,
            durationFrames: 250,
            videoTrackCount: video,
            audioTrackCount: audio,
            clipName: name,
            projectName: project,
            tapeName: nil,
            parseError: nil,
            parseDurationMs: 10
        )
    }

    // MARK: - Grouping by material UID

    @Test func opAtomStemsGroupIntoOneClip() {
        // 1 video + 2 audio stems all sharing the same material UID.
        let files = [
            info(path: "/V01.mxf", material: "AAAA", video: 1, name: "MyClip"),
            info(path: "/A01.mxf", material: "AAAA", audio: 1),
            info(path: "/A02.mxf", material: "AAAA", audio: 1)
        ]
        let clips = ClipAggregator.aggregate(files)
        #expect(clips.count == 1)

        let clip = clips[0]
        #expect(clip.fileCount == 3)
        #expect(clip.videoTrackCount == 1)
        #expect(clip.audioTrackCount == 2)
        #expect(clip.trackCount == 3)
        #expect(clip.isUngroupable == false)
        #expect(clip.materialPackageUID == "AAAA")
        #expect(clip.displayName == "MyClip")
    }

    @Test func distinctMaterialUIDsProduceDistinctClips() {
        let files = [
            info(path: "/V01_a.mxf", material: "AAAA", video: 1, name: "Clip A"),
            info(path: "/V01_b.mxf", material: "BBBB", video: 1, name: "Clip B")
        ]
        let clips = ClipAggregator.aggregate(files)
        #expect(clips.count == 2)
        #expect(Set(clips.map(\.materialPackageUID)) == Set(["AAAA", "BBBB"]))
    }

    @Test func missingMaterialUIDFallsBackToUngroupable() {
        // File with nil UID and one with empty UID both become single-file
        // ungroupable clips keyed by file URL.
        let files = [
            info(path: "/orphan1.mxf", material: nil, video: 1, name: "orphan1"),
            info(path: "/orphan2.mxf", material: "", video: 1, name: "orphan2"),
            info(path: "/grouped.mxf", material: "CCCC", video: 1, name: "grouped")
        ]
        let clips = ClipAggregator.aggregate(files)
        #expect(clips.count == 3)

        let ungroupable = clips.filter(\.isUngroupable)
        #expect(ungroupable.count == 2, "nil + empty-string both fall through to ungroupable")
        for clip in ungroupable {
            #expect(clip.fileCount == 1)
            #expect(clip.materialPackageUID == nil)
        }
    }

    @Test func whitespaceInUIDGroupsAsIfTrimmed() {
        // If two infos have UIDs differing only by surrounding whitespace, they
        // should group together. ClipAggregator trims before bucketing.
        let files = [
            info(path: "/a.mxf", material: "  AAAA  ", video: 1),
            info(path: "/b.mxf", material: "AAAA", audio: 1)
        ]
        let clips = ClipAggregator.aggregate(files)
        #expect(clips.count == 1)
        #expect(clips[0].fileCount == 2)
    }

    // MARK: - Sort ordering

    @Test func sortsByDisplayNameNaturallyNotLexically() {
        // Finder-style: A001_C009 must sort before A001_C010, not after.
        let files = [
            info(path: "/a.mxf", material: "X1", video: 1, name: "A001_C010"),
            info(path: "/b.mxf", material: "X2", video: 1, name: "A001_C009"),
            info(path: "/c.mxf", material: "X3", video: 1, name: "A001_C100")
        ]
        let clips = ClipAggregator.aggregate(files)
        #expect(clips.map(\.displayName) == ["A001_C009", "A001_C010", "A001_C100"])
    }

    // MARK: - Derived Clip fields

    @Test func clipDurationUsesMaxAcrossFiles() {
        // If one stem's duration failed to parse (nil), `max` still yields the
        // others. For OP-Atom all stems share duration in practice.
        var a = info(path: "/V01.mxf", material: "D", video: 1)
        var b = info(path: "/A01.mxf", material: "D", audio: 1)
        a = MXFHeaderInfo(
            fileURL: a.fileURL, fileSize: a.fileSize,
            materialPackageUID: a.materialPackageUID, filePackageUID: a.filePackageUID,
            editRateNum: 25, editRateDen: 1, durationFrames: 250,
            videoTrackCount: a.videoTrackCount, audioTrackCount: a.audioTrackCount,
            clipName: nil, projectName: nil, tapeName: nil,
            parseError: nil, parseDurationMs: nil
        )
        b = MXFHeaderInfo(
            fileURL: b.fileURL, fileSize: b.fileSize,
            materialPackageUID: b.materialPackageUID, filePackageUID: b.filePackageUID,
            editRateNum: 25, editRateDen: 1, durationFrames: nil,  // partial parse
            videoTrackCount: b.videoTrackCount, audioTrackCount: b.audioTrackCount,
            clipName: nil, projectName: nil, tapeName: nil,
            parseError: "partial", parseDurationMs: nil
        )
        let clips = ClipAggregator.aggregate([a, b])
        #expect(clips.count == 1)
        #expect(clips[0].durationFrames == 250, "max across files ignores nil")
        #expect(clips[0].hasParseErrors == true)
        #expect(clips[0].parseErrorCount == 1)
    }

    @Test func totalSizeSumsAcrossFiles() {
        let files = [
            info(path: "/V01.mxf", material: "E", video: 1, size: 5_000_000_000),
            info(path: "/A01.mxf", material: "E", audio: 1, size: 50_000_000),
            info(path: "/A02.mxf", material: "E", audio: 1, size: 50_000_000)
        ]
        let clips = ClipAggregator.aggregate(files)
        #expect(clips[0].totalSize == 5_100_000_000)
    }

    @Test func emptyInputYieldsEmptyOutput() {
        #expect(ClipAggregator.aggregate([]).isEmpty)
    }
}
