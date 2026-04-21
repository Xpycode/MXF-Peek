import Foundation
import Testing
@testable import AvidMXFPeek

/// Tests for `AuditReportExporter` — CSV RFC 4180 escaping + metadata row shape,
/// JSON round-trip against the v1.0.0 schema documented at
/// `docs/specs/audit-report-schema.md`.
struct AuditReportExporterTests {

    // MARK: - Fixture builders

    private func info(
        path: String,
        material: String?,
        video: Int = 0,
        audio: Int = 0,
        name: String? = nil,
        size: Int64 = 1_000_000
    ) -> MXFHeaderInfo {
        MXFHeaderInfo(
            fileURL: URL(fileURLWithPath: path),
            fileSize: size,
            materialPackageUID: material,
            filePackageUID: nil,
            editRateNum: 25,
            editRateDen: 1,
            durationFrames: 250,
            videoTrackCount: video,
            audioTrackCount: audio,
            clipName: name,
            projectName: "PEEKY",
            tapeName: nil,
            parseError: nil,
            parseDurationMs: nil
        )
    }

    private func sampleClips() -> [Clip] {
        ClipAggregator.aggregate([
            info(path: "/V01.mxf", material: "AAAA", video: 1, name: "MyClip", size: 5_000_000_000),
            info(path: "/A01.mxf", material: "AAAA", audio: 1, size: 50_000_000),
            info(path: "/A02.mxf", material: "AAAA", audio: 1, size: 50_000_000)
        ])
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000) // deterministic

    // MARK: - CSV

    @Test func csvHasMetadataPrefixHeaderThenColumnsThenRows() throws {
        let csv = AuditReportExporter.makeCSV(
            clips: sampleClips(),
            sourceFolder: URL(fileURLWithPath: "/Volumes/Drive/Avid MediaFiles/MXF/1"),
            generatedAt: fixedDate
        )
        let lines = csv.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)

        // 3 metadata rows (# source_folder, # generated_at, # schema_version)
        #expect(lines[0].hasPrefix("# source_folder,"), "first row carries source folder")
        #expect(lines[1].hasPrefix("# generated_at,"))
        #expect(lines[2].hasPrefix("# schema_version,"))
        #expect(lines[2].contains(AuditReportExporter.jsonSchemaVersion))

        // Line 3 = column header
        let header = lines[3]
        let expectedColumns = [
            "material_package_uid", "display_name", "project_name", "tape_name",
            "video_track_count", "audio_track_count", "duration_frames",
            "edit_rate", "duration_seconds", "total_bytes", "file_count",
            "is_ungroupable", "parse_error_count"
        ]
        #expect(header == expectedColumns.joined(separator: ","))

        // Line 4 = clip data row
        #expect(lines[4].contains("AAAA"))
        #expect(lines[4].contains("MyClip"))
        #expect(lines[4].contains("PEEKY"))
    }

    @Test func csvFieldEscapingRFC4180() throws {
        // Names containing commas, quotes, and newlines must be quoted with
        // internal quotes doubled.
        let nasty = info(
            path: "/nasty.mxf",
            material: "XYZ",
            video: 1,
            name: #"He said "hi, world"\#nnewline"#
        )
        let csv = AuditReportExporter.makeCSV(
            clips: ClipAggregator.aggregate([nasty]),
            sourceFolder: nil,
            generatedAt: fixedDate
        )
        // Expect the displayName cell to be wrapped in quotes + internal
        // quotes doubled.
        #expect(csv.contains(#""He said ""hi, world""\#nnewline""#))
    }

    @Test func csvLineEndingsAreCRLF() throws {
        let csv = AuditReportExporter.makeCSV(
            clips: sampleClips(), sourceFolder: nil, generatedAt: fixedDate
        )
        #expect(csv.contains("\r\n"), "CSV must use CRLF line endings")
        // After stripping every well-formed CRLF, no bare CR or LF should remain
        // (our fixture has no newlines inside fields).
        let stripped = csv.replacingOccurrences(of: "\r\n", with: "")
        #expect(!stripped.contains("\n"), "bare LF found — line endings must be CRLF")
        #expect(!stripped.contains("\r"), "bare CR found — line endings must be CRLF")
    }

    @Test func csvOmitsSourceFolderRowWhenNil() {
        let csv = AuditReportExporter.makeCSV(
            clips: sampleClips(), sourceFolder: nil, generatedAt: fixedDate
        )
        #expect(!csv.contains("# source_folder"))
        #expect(csv.contains("# generated_at"))
    }

    @Test func csvEmptyClipsStillProducesHeader() {
        let csv = AuditReportExporter.makeCSV(
            clips: [], sourceFolder: nil, generatedAt: fixedDate
        )
        #expect(csv.contains("material_package_uid"))
        let lines = csv.split(separator: "\r\n").map(String.init)
        // generated_at + schema_version + column header = 3 lines, no data rows
        #expect(lines.count == 3)
    }

    // MARK: - JSON

    @Test func jsonDecodesToSchemaShape() throws {
        let data = try AuditReportExporter.makeJSON(
            clips: sampleClips(),
            sourceFolder: URL(fileURLWithPath: "/tmp/test"),
            generatedAt: fixedDate
        )

        // Round-trip through Foundation JSONSerialization for a schema-level check.
        let any = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(any as? [String: Any])

        #expect(dict["schema_version"] as? String == AuditReportExporter.jsonSchemaVersion)
        #expect(dict["generated_at"] is String, "date encoded as ISO 8601 string")
        #expect(dict["source_folder"] as? String == "/tmp/test")

        let summary = try #require(dict["summary"] as? [String: Any])
        #expect(summary["total_clips"] as? Int == 1)
        #expect(summary["total_files"] as? Int == 3)
        #expect(summary["ungroupable_clips"] as? Int == 0)
        #expect(summary["parse_error_files"] as? Int == 0)
        #expect((summary["total_bytes"] as? Int64) == 5_100_000_000
                || (summary["total_bytes"] as? Int) == 5_100_000_000)

        let clips = try #require(dict["clips"] as? [[String: Any]])
        #expect(clips.count == 1)
        let clip = clips[0]
        #expect(clip["material_package_uid"] as? String == "AAAA")
        #expect(clip["display_name"] as? String == "MyClip")
        #expect(clip["project_name"] as? String == "PEEKY")
        #expect(clip["video_track_count"] as? Int == 1)
        #expect(clip["audio_track_count"] as? Int == 2)
        #expect(clip["is_ungroupable"] as? Bool == false)

        let files = try #require(clip["files"] as? [[String: Any]])
        #expect(files.count == 3)
        #expect(Set(files.compactMap { $0["url"] as? String })
                == Set(["/V01.mxf", "/A01.mxf", "/A02.mxf"]))
    }

    @Test func jsonSchemaVersionIsStable() {
        // A bump to this constant is a contract-breaking change. This test
        // will fail intentionally to force reviewers to consider consequences
        // for external consumers of the audit report.
        #expect(AuditReportExporter.jsonSchemaVersion == "1.0.0")
    }

    @Test func jsonDateIsISO8601WithSecondsPrecision() throws {
        let data = try AuditReportExporter.makeJSON(
            clips: [], sourceFolder: nil, generatedAt: fixedDate
        )
        let string = try #require(String(data: data, encoding: .utf8))
        // 1_800_000_000 epoch = 2027-01-15T08:00:00Z
        #expect(string.contains("2027-01-15T08:00:00Z"))
    }

    @Test func jsonEmptyInputStillValid() throws {
        let data = try AuditReportExporter.makeJSON(
            clips: [], sourceFolder: nil, generatedAt: fixedDate
        )
        let dict = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let summary = try #require(dict["summary"] as? [String: Any])
        #expect(summary["total_clips"] as? Int == 0)
        #expect(summary["total_files"] as? Int == 0)
        let clips = try #require(dict["clips"] as? [[String: Any]])
        #expect(clips.isEmpty)
    }
}
