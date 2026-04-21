import Foundation

// MARK: - AuditReportExporter
//
// Writes the results of an MXF-folder audit to disk as CSV (RFC 4180) or JSON
// (schema v1.0.0, documented in docs/specs/audit-report-schema.md).
//
// Kept separate from the legacy P2toMXF conversion-report generator above —
// same file slot to avoid pbxproj surgery, but zero code-level dependency.

enum AuditReportExporter {

    /// Schema version written into JSON exports. Bump on breaking field changes.
    /// Stability contract: within a major version, fields may be added but not
    /// renamed or removed; types do not change.
    static let jsonSchemaVersion = "1.0.0"

    // MARK: - Top-level API

    /// Build the report bytes for an audit. Pure — does not touch disk.
    /// Callers wrap in `write(to:)` or adapt for NSSavePanel.
    static func makeJSON(
        clips: [Clip],
        sourceFolder: URL?,
        generatedAt: Date = Date()
    ) throws -> Data {
        let dto = buildDTO(clips: clips, sourceFolder: sourceFolder, generatedAt: generatedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(dto)
    }

    static func makeCSV(
        clips: [Clip],
        sourceFolder: URL?,
        generatedAt: Date = Date()
    ) -> String {
        var out = ""
        // Metadata header (comment lines — Numbers/Excel tolerate extra header rows
        // but to stay RFC 4180 strict these go above the header row as regular data
        // rows prefixed with "# ". Most readers treat them as data; the column row
        // follows. Downstream scripts should `grep -v '^#'` or parse from the
        // `material_package_uid,...` line.
        if let folder = sourceFolder {
            out += "# source_folder," + csvField(folder.path) + "\r\n"
        }
        out += "# generated_at," + csvField(ISO8601DateFormatter().string(from: generatedAt)) + "\r\n"
        out += "# schema_version," + csvField(jsonSchemaVersion) + "\r\n"

        // Column header
        let columns = [
            "material_package_uid", "display_name", "project_name", "tape_name",
            "video_track_count", "audio_track_count", "duration_frames",
            "edit_rate", "duration_seconds", "total_bytes", "file_count",
            "is_ungroupable", "parse_error_count"
        ]
        out += columns.joined(separator: ",") + "\r\n"

        for clip in clips {
            let editRate = clip.editRate.map { "\($0.num)/\($0.den)" } ?? ""
            let row: [String] = [
                clip.materialPackageUID ?? "",
                clip.displayName,
                clip.projectName ?? "",
                clip.tapeName ?? "",
                String(clip.videoTrackCount),
                String(clip.audioTrackCount),
                clip.durationFrames.map(String.init) ?? "",
                editRate,
                clip.durationSeconds.map { String(format: "%.3f", $0) } ?? "",
                String(clip.totalSize),
                String(clip.fileCount),
                clip.isUngroupable ? "true" : "false",
                String(clip.parseErrorCount)
            ].map(csvField)
            out += row.joined(separator: ",") + "\r\n"
        }
        return out
    }

    static func writeJSON(
        clips: [Clip],
        sourceFolder: URL?,
        to url: URL,
        generatedAt: Date = Date()
    ) throws {
        let data = try makeJSON(clips: clips, sourceFolder: sourceFolder, generatedAt: generatedAt)
        try data.write(to: url, options: .atomic)
    }

    static func writeCSV(
        clips: [Clip],
        sourceFolder: URL?,
        to url: URL,
        generatedAt: Date = Date()
    ) throws {
        let text = makeCSV(clips: clips, sourceFolder: sourceFolder, generatedAt: generatedAt)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Private: DTO + CSV helpers

    private static func buildDTO(clips: [Clip], sourceFolder: URL?, generatedAt: Date) -> AuditReportDTO {
        let summary = AuditReportDTO.Summary(
            total_clips: clips.count,
            total_files: clips.reduce(0) { $0 + $1.fileCount },
            ungroupable_clips: clips.filter(\.isUngroupable).count,
            parse_error_files: clips.reduce(0) { $0 + $1.parseErrorCount },
            total_bytes: clips.reduce(Int64(0)) { $0 + $1.totalSize }
        )

        let clipDTOs = clips.map { clip -> AuditReportDTO.ClipDTO in
            AuditReportDTO.ClipDTO(
                material_package_uid: clip.materialPackageUID,
                display_name: clip.displayName,
                project_name: clip.projectName,
                tape_name: clip.tapeName,
                video_track_count: clip.videoTrackCount,
                audio_track_count: clip.audioTrackCount,
                duration_frames: clip.durationFrames,
                edit_rate_num: clip.editRate?.num,
                edit_rate_den: clip.editRate?.den,
                duration_seconds: clip.durationSeconds,
                total_bytes: clip.totalSize,
                is_ungroupable: clip.isUngroupable,
                files: clip.files.map { info in
                    AuditReportDTO.FileDTO(
                        url: info.fileURL.path,
                        size: info.fileSize,
                        parse_error: info.parseError
                    )
                }
            )
        }

        return AuditReportDTO(
            schema_version: jsonSchemaVersion,
            generated_at: generatedAt,
            source_folder: sourceFolder?.path,
            summary: summary,
            clips: clipDTOs
        )
    }

    /// RFC 4180 field escaping: quote if the field contains comma, quote, CR, or LF;
    /// internal double-quotes are doubled; otherwise emit as-is.
    private static func csvField(_ s: String) -> String {
        let needsQuote = s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        if !needsQuote { return s }
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

// MARK: - DTO (wire format)
//
// Explicit snake_case struct — stable JSON field names that survive internal
// refactors of MXFHeaderInfo / Clip. Bump jsonSchemaVersion if you need to
// rename or remove a field here.

private struct AuditReportDTO: Encodable {
    let schema_version: String
    let generated_at: Date
    let source_folder: String?
    let summary: Summary
    let clips: [ClipDTO]

    struct Summary: Encodable {
        let total_clips: Int
        let total_files: Int
        let ungroupable_clips: Int
        let parse_error_files: Int
        let total_bytes: Int64
    }

    struct ClipDTO: Encodable {
        let material_package_uid: String?
        let display_name: String
        let project_name: String?
        let tape_name: String?
        let video_track_count: Int
        let audio_track_count: Int
        let duration_frames: Int64?
        let edit_rate_num: Int32?
        let edit_rate_den: Int32?
        let duration_seconds: Double?
        let total_bytes: Int64
        let is_ungroupable: Bool
        let files: [FileDTO]
    }

    struct FileDTO: Encodable {
        let url: String
        let size: Int64
        let parse_error: String?
    }
}

