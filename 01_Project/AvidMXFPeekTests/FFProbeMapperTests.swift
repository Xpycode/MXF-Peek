import Foundation
import Testing
@testable import AvidMXFPeek

/// Fixture-based tests for `FFProbeMapper.map` — the ffprobe-JSON → MXFHeaderInfo
/// boundary. Shapes modeled on real output captured from Avid Media Composer
/// 25.12 DNxHD exports on 2026-04-20; see `docs/plans/2026-04-20-ffprobe-pivot.md`.
struct FFProbeMapperTests {

    // MARK: - Helpers

    private func map(_ json: String, fileURL: URL = URL(fileURLWithPath: "/tmp/sample.mxf"),
                     size: Int64 = 1_000_000) -> MXFHeaderInfo {
        FFProbeMapper.map(
            jsonData: Data(json.utf8),
            fileURL: fileURL,
            fileSize: size,
            parseDurationMs: 42
        )
    }

    // MARK: - Video stem (Avid OP-Atom V01.*.mxf shape)

    @Test func videoStemMapsOwnEssenceOnly() {
        // Shape: stream[0] = own dnxhd video, stream[1..2] = data refs to sibling audio stems.
        let json = """
        {
          "format": {
            "duration": "343.080000",
            "nb_streams": 3,
            "tags": {
              "material_package_umid": "0x060A2B340101010501010F1013000000A0C4040211508206FDEF46149F834AC2",
              "material_package_name": "What if there were 1 trillion more trees",
              "project_name": "PEEKY",
              "operational_pattern_ul": "060e2b34.04010102.0d010201.10030000"
            }
          },
          "streams": [
            {
              "index": 0,
              "codec_type": "video",
              "codec_name": "dnxhd",
              "r_frame_rate": "25/1",
              "time_base": "1/25",
              "tags": {
                "file_package_umid": "0x060A2B340101010501010F1013000000A0C4043D1150820609A146149F834AC2",
                "reel_umid": "0x060A2B340101010501010F1013000000A0C4046C1150820663BE46149F834AC2",
                "reel_name": "source.mp4"
              }
            },
            {
              "index": 1,
              "codec_type": "data",
              "tags": {
                "file_package_umid": "0x060A2B340101010501010F1013000000A0C4046611508206142A46149F834AC2",
                "data_type": "audio"
              }
            },
            {
              "index": 2,
              "codec_type": "data",
              "tags": {
                "file_package_umid": "0x060A2B340101010501010F1013000000A0C4046911508206E56C46149F834AC2",
                "data_type": "audio"
              }
            }
          ]
        }
        """
        let info = map(json)

        #expect(info.materialPackageUID == "060A2B340101010501010F1013000000A0C4040211508206FDEF46149F834AC2")
        #expect(info.filePackageUID == "060A2B340101010501010F1013000000A0C4043D1150820609A146149F834AC2")
        #expect(info.clipName == "What if there were 1 trillion more trees")
        #expect(info.projectName == "PEEKY")
        #expect(info.tapeName == "source.mp4")
        #expect(info.videoTrackCount == 1, "OP-Atom video stem owns exactly one video essence")
        #expect(info.audioTrackCount == 0, "sibling audio stems are references, not this file's essence")
        #expect(info.editRateNum == 25)
        #expect(info.editRateDen == 1)
        #expect(info.durationFrames == 8577)  // 343.08 * 25
        #expect(info.parseError == nil)
        #expect(info.parseDurationMs == 42)
    }

    // MARK: - Audio stem (Avid OP-Atom A01.*.mxf shape)

    @Test func audioStemMapsOwnEssenceOnly() {
        // Shape: stream[0] = data ref to video, stream[1] = own pcm_s24le audio,
        // stream[2] = data ref to sibling audio stem.
        let json = """
        {
          "format": {
            "duration": "343.080000",
            "nb_streams": 3,
            "tags": {
              "material_package_umid": "0xAAAA0002",
              "material_package_name": "Clip",
              "project_name": "PEEKY"
            }
          },
          "streams": [
            {
              "index": 0,
              "codec_type": "data",
              "tags": {
                "file_package_umid": "0xVIDEO",
                "data_type": "video"
              }
            },
            {
              "index": 1,
              "codec_type": "audio",
              "codec_name": "pcm_s24le",
              "time_base": "1/48000",
              "r_frame_rate": "0/0",
              "tags": {
                "file_package_umid": "0xOWNAUDIO"
              }
            },
            {
              "index": 2,
              "codec_type": "data",
              "tags": {
                "file_package_umid": "0xSIBLING",
                "data_type": "audio"
              }
            }
          ]
        }
        """
        let info = map(json)

        #expect(info.videoTrackCount == 0, "audio stem's own essence is audio, not video")
        #expect(info.audioTrackCount == 1, "the other 'audio' data stream is a sibling ref")
        #expect(info.filePackageUID == "OWNAUDIO", "fileUID must be the own stream's UID, not streams[0]")
        // Edit rate via time_base inverse: 1/48000 → 48000/1
        #expect(info.editRateNum == 48000)
        #expect(info.editRateDen == 1)
        // Duration frames: 343.08 s × 48000 = 16_467_840
        #expect(info.durationFrames == 16_467_840)
    }

    // MARK: - Single-file clip (camera-native, e.g. Fuji X-H2S)

    @Test func singleFileVideoOnlyClip() {
        // One stream, own video essence, no audio siblings.
        let json = """
        {
          "format": {
            "duration": "2120.5",
            "nb_streams": 1,
            "tags": {
              "material_package_umid": "0xCAMERA",
              "material_package_name": "X-S20--2026-03-06",
              "project_name": "PEEKY"
            }
          },
          "streams": [
            {
              "index": 0,
              "codec_type": "video",
              "codec_name": "dnxhd",
              "r_frame_rate": "25/1",
              "tags": {
                "file_package_umid": "0xCAMERAFILE"
              }
            }
          ]
        }
        """
        let info = map(json)
        #expect(info.videoTrackCount == 1)
        #expect(info.audioTrackCount == 0)
        #expect(info.clipName == "X-S20--2026-03-06")
    }

    // MARK: - Defensive decoding

    @Test func missingFormatTagsGracefullyNilsOut() {
        let json = """
        {"format":{"duration":"10.0","nb_streams":1},"streams":[{"codec_type":"video","codec_name":"dnxhd","r_frame_rate":"25/1"}]}
        """
        let info = map(json)
        #expect(info.materialPackageUID == nil)
        #expect(info.clipName == nil)
        #expect(info.projectName == nil)
        #expect(info.tapeName == nil)
        #expect(info.videoTrackCount == 1, "own essence still counts even without format tags")
    }

    @Test func emptyStreamsArrayYieldsZeroCounts() {
        let json = """
        {"format":{"duration":"10.0","nb_streams":0,"tags":{"project_name":"PEEKY"}},"streams":[]}
        """
        let info = map(json)
        #expect(info.videoTrackCount == 0)
        #expect(info.audioTrackCount == 0)
        #expect(info.filePackageUID == nil, "no streams → no own essence → no fileUID")
        #expect(info.editRateNum == nil)
        #expect(info.durationFrames == nil, "no edit rate → can't compute frames")
        #expect(info.projectName == "PEEKY", "format tags survive even with empty streams")
    }

    @Test func allDataStreamsNoOwnEssence() {
        // Pathological: every stream is a data-ref (no codec_name anywhere).
        // Should yield zero counts, nil fileUID.
        let json = """
        {"format":{"duration":"10.0"},"streams":[{"codec_type":"data","tags":{"data_type":"audio"}}]}
        """
        let info = map(json)
        #expect(info.videoTrackCount == 0)
        #expect(info.audioTrackCount == 0, "data-only streams are refs, not own essence")
        #expect(info.filePackageUID == nil)
    }

    @Test func malformedJSONReturnsFailedInfo() {
        let info = map("{ not json at all")
        #expect(info.parseError != nil)
        #expect(info.parseError?.contains("JSON") == true)
        #expect(info.videoTrackCount == 0)
        #expect(info.audioTrackCount == 0)
    }

    @Test func invalidEditRateDoesNotCrashDuration() {
        // r_frame_rate is "0/0" (valid-looking but num=0) — parser must reject
        // and fall through to time_base, which here is also 0/0. Result: nil rate,
        // nil frames, but no crash.
        let json = """
        {"format":{"duration":"10.0"},"streams":[{"codec_type":"video","codec_name":"dnxhd","r_frame_rate":"0/0","time_base":"0/0"}]}
        """
        let info = map(json)
        #expect(info.editRateNum == nil)
        #expect(info.editRateDen == nil)
        #expect(info.durationFrames == nil)
        #expect(info.videoTrackCount == 1, "track counting still works even when rate is bogus")
    }

    @Test func hexPrefixStrippedCaseInsensitive() {
        // Lowercase "0x" (normal ffprobe) and uppercase "0X" both strip.
        let json = """
        {
          "format":{"duration":"1.0","tags":{"material_package_umid":"0xABCD"}},
          "streams":[{"codec_type":"video","codec_name":"dnxhd","r_frame_rate":"25/1","tags":{"file_package_umid":"0X1234"}}]
        }
        """
        let info = map(json)
        #expect(info.materialPackageUID == "ABCD")
        #expect(info.filePackageUID == "1234")
    }
}
