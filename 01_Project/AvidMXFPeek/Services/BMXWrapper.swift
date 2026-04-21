import Foundation

// MARK: - MXFHeaderInfo
//
// Result type for a single-file MXF header probe. Populated by ffprobe JSON
// (`format.tags` + `streams[].tags`) via `BMXWrapper.info(url:)`. Fields are
// optional because defensive decoding tolerates missing / renamed keys; the
// owner of this struct (`ClipAggregator`, the UI) handles nil gracefully.

struct MXFHeaderInfo: Sendable, Identifiable, Hashable {
    var id: URL { fileURL }

    let fileURL: URL
    let fileSize: Int64

    /// Hex UMID. Clips sharing this value are one logical clip (video + audio stems).
    let materialPackageUID: String?
    /// Hex UMID for the file's own source package (unique per MXF file).
    let filePackageUID: String?

    let editRateNum: Int32?
    let editRateDen: Int32?
    let durationFrames: Int64?

    let videoTrackCount: Int
    let audioTrackCount: Int

    let clipName: String?
    let projectName: String?
    let tapeName: String?

    let parseError: String?
    let parseDurationMs: Int?

    var trackCount: Int { videoTrackCount + audioTrackCount }

    var durationSeconds: Double? {
        guard let frames = durationFrames,
              let num = editRateNum, let den = editRateDen,
              num > 0 else { return nil }
        return Double(frames) * Double(den) / Double(num)
    }

    /// Short UMID form for display (last 16 hex chars — the instance tail of the SMPTE UMID).
    var shortMaterialUID: String? {
        guard let umid = materialPackageUID else { return nil }
        let hex = umid.trimmingCharacters(in: .whitespacesAndNewlines)
        return hex.count >= 16 ? String(hex.suffix(16)) : hex
    }

    /// Best-effort display name: clipName → filename without extension.
    var displayName: String {
        clipName ?? fileURL.deletingPathExtension().lastPathComponent
    }

    static func failed(url: URL, size: Int64, reason: String) -> MXFHeaderInfo {
        MXFHeaderInfo(
            fileURL: url, fileSize: size,
            materialPackageUID: nil, filePackageUID: nil,
            editRateNum: nil, editRateDen: nil, durationFrames: nil,
            videoTrackCount: 0, audioTrackCount: 0,
            clipName: nil, projectName: nil, tapeName: nil,
            parseError: reason, parseDurationMs: nil
        )
    }
}

// MARK: - BMXWrapper
//
// Legacy type name; currently an **ffprobe** wrapper. Wraps a single-file
// `ffprobe -show_format -show_streams -of json` invocation and maps the
// result into an `MXFHeaderInfo`. Renamed on a future pass.
//
// Why ffprobe, not bmx/mxf2raw: real-data validation on Avid MC 25.12 DNxHD
// output showed libMXF's `mxf_get_video_line_map_item` hard-asserts
// `item->length == 16`, which Avid's progressive writer violates — every
// video stem fails at open time. bbc/bmx archived 2025-09-29; ebu/bmx fork
// has no fix. ffprobe reads both video and audio stems cleanly and surfaces
// `project_name` which mxf2raw did not. See
// `docs/plans/2026-04-20-ffprobe-pivot.md` and decision `2026-04-20-C`.

final class BMXWrapper {

    enum BMXError: LocalizedError {
        case ffprobeNotFound
        case probeFailed(String)

        var errorDescription: String? {
            switch self {
            case .ffprobeNotFound:
                return "ffprobe binary missing from app bundle"
            case .probeFailed(let message):
                return "ffprobe failed: \(message)"
            }
        }
    }

    private let toolResolver = BundledToolResolver.shared

    /// Probe a single MXF file and map its ffprobe JSON into an `MXFHeaderInfo`.
    /// Never throws: per-file errors (missing binary, bad file, probe non-zero
    /// exit, JSON parse failure) are returned as `MXFHeaderInfo.failed(...)`
    /// so a scan of N files never stalls on one bad clip.
    func info(url: URL) async -> MXFHeaderInfo {
        let startedAt = Date()
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        guard let ffprobe = toolResolver.path(for: .ffprobe) else {
            return .failed(url: url, size: fileSize, reason: "ffprobe binary missing from bundle")
        }

        let args = [
            "-v", "error",
            "-show_format", "-show_streams",
            "-of", "json",
            url.path
        ]
        let data: Data
        do {
            data = try await runAndCollect(at: ffprobe, arguments: args)
        } catch {
            return .failed(url: url, size: fileSize, reason: error.localizedDescription)
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        return FFProbeMapper.map(
            jsonData: data, fileURL: url, fileSize: fileSize, parseDurationMs: elapsedMs
        )
    }

    /// Run a short-lived subprocess to completion and return stdout as `Data`.
    ///
    /// Uses `waitUntilExit()` + `readDataToEndOfFile()` — avoids the tail-byte
    /// race in a `readabilityHandler`-based path, and is simpler for
    /// fire-and-collect invocations like ffprobe. `Task.detached` keeps the
    /// blocking reads off the caller's actor.
    private func runAndCollect(at executable: URL, arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let message = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "exit \(process.terminationStatus)"
                throw BMXError.probeFailed(message)
            }
            return stdoutData
        }.value
    }
}

// MARK: - FFProbeReport (wire format)
//
// Lean Codable view over the subset of `ffprobe -show_format -show_streams -of json`
// we consume. Extra fields are ignored — `JSONDecoder` tolerates them by default.

private struct FFProbeReport: Decodable {
    struct Format: Decodable {
        let duration: String?       // seconds, as string in ffprobe JSON
        let nb_streams: Int?
        let tags: [String: String]?
    }
    struct Stream: Decodable {
        let index: Int?
        let codec_type: String?     // "video" | "audio" | "data"
        let codec_name: String?
        let r_frame_rate: String?   // e.g. "25/1" — "0/0" for audio streams
        let time_base: String?      // e.g. "1/25" for video, "1/48000" for audio
        let tags: [String: String]?
    }
    let format: Format
    let streams: [Stream]?
}

// MARK: - FFProbeMapper
//
// Pure mapping from ffprobe JSON to MXFHeaderInfo. No I/O. Tolerant of
// missing fields — every output field is optional except track counts
// (default 0) and file-level fields supplied by the caller.

enum FFProbeMapper {

    static func map(
        jsonData: Data,
        fileURL: URL,
        fileSize: Int64,
        parseDurationMs: Int
    ) -> MXFHeaderInfo {
        let report: FFProbeReport
        do {
            report = try JSONDecoder().decode(FFProbeReport.self, from: jsonData)
        } catch {
            return .failed(
                url: fileURL, size: fileSize,
                reason: "ffprobe JSON parse failed: \(error.localizedDescription)"
            )
        }

        let formatTags = report.format.tags ?? [:]
        let streams = report.streams ?? []

        // UMIDs — ffprobe renders byte-string tags with a "0x" prefix; strip so
        // the stored UID is just hex and compares cleanly downstream.
        let materialUID = formatTags["material_package_umid"].map(stripHexPrefix)

        // Find the file's **own** essence stream. Avid OP-Atom encodes the
        // whole clip's stem graph in every .mxf — ffprobe surfaces it as a
        // `streams` array where the own essence has a real `codec_name`
        // (e.g. "dnxhd" for video, "pcm_s24le" for audio) and the references
        // to sibling stems have `codec_type="data"` with a `data_type` tag.
        //
        // Everything derived below (fileUID, track counts, edit rate) uses
        // ONLY the own stream — otherwise per-file counts balloon into
        // "1 video + N audio" on every stem, and the clip-level sum across
        // stems is multiplied by fileCount.
        let ownStream = streams.first(where: { $0.codec_name?.isEmpty == false })

        let fileUID = ownStream?.tags?["file_package_umid"].map(stripHexPrefix)

        // Edit rate: prefer `r_frame_rate` (set for video), fall back to
        // `time_base` inverse (set for audio — "1/48000" → edit rate 48000/1).
        let (editNum, editDen): (Int32?, Int32?) = {
            if let r = ownStream?.r_frame_rate,
               let parsed = parseRational(r), parsed.0 > 0, parsed.1 > 0 {
                return (parsed.0, parsed.1)
            }
            if let tb = ownStream?.time_base,
               let parsed = parseRational(tb), parsed.0 > 0, parsed.1 > 0 {
                return (parsed.1, parsed.0)
            }
            return (nil, nil)
        }()

        let durationSeconds = Double(report.format.duration ?? "")
        let durationFrames: Int64? = {
            guard let seconds = durationSeconds,
                  let num = editNum, let den = editDen,
                  den > 0, seconds.isFinite, seconds >= 0
            else { return nil }
            return Int64((seconds * Double(num) / Double(den)).rounded())
        }()

        // Per-file track count is 0 or 1 — OP-Atom stems carry exactly one
        // essence. Clip-level totals (sum across stems in `ClipAggregator`)
        // then correctly surface "1 video + N audio" where N = number of
        // audio stem files, matching the logical stereo/5.1/etc. layout.
        let videoTrackCount = (ownStream?.codec_type == "video") ? 1 : 0
        let audioTrackCount = (ownStream?.codec_type == "audio") ? 1 : 0

        return MXFHeaderInfo(
            fileURL: fileURL,
            fileSize: fileSize,
            materialPackageUID: materialUID,
            filePackageUID: fileUID,
            editRateNum: editNum,
            editRateDen: editDen,
            durationFrames: durationFrames,
            videoTrackCount: videoTrackCount,
            audioTrackCount: audioTrackCount,
            clipName: formatTags["material_package_name"],
            projectName: formatTags["project_name"],
            tapeName: streams.compactMap { $0.tags?["reel_name"] }.first,
            parseError: nil,
            parseDurationMs: parseDurationMs
        )
    }

    private static func stripHexPrefix(_ s: String) -> String {
        s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
    }

    private static func parseRational(_ s: String) -> (Int32, Int32)? {
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let num = Int32(parts[0]),
              let den = Int32(parts[1]) else { return nil }
        return (num, den)
    }
}
