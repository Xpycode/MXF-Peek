import Foundation

// MARK: - MXFFolderScanner
//
// Recursively walks a folder for `.mxf` files and yields `MXFHeaderInfo` values
// as `mxf2raw --info` completes on each one. Concurrency is capped so a 10k-file
// folder doesn't fork 10k subprocesses at once.
//
// Each scan creates a fresh `BMXWrapper` per task; instances are lightweight and
// the `info(url:)` path is self-contained (no shared cancel/process state).
// Per-file errors are surfaced as `MXFHeaderInfo.failed(...)` — the stream never
// throws for a single bad clip.

struct MXFFolderScanner {

    /// How many concurrent `mxf2raw` subprocesses to run at peak.
    /// Tune upward if CPU is idle on large scans; downward if thermal pressure shows up.
    var maxConcurrent: Int = 8

    /// Recursively enumerate all `.mxf` files under `folder`. Returns URLs sorted
    /// by path for stable output order. Does NOT follow symbolic links (avoids
    /// accidental full-volume walks if a symlink points at root).
    static func discoverMXFFiles(under folder: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles, .skipsPackageDescendants
        ]
        guard let enumerator = fm.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: options, errorHandler: nil
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            if url.pathExtension.caseInsensitiveCompare("mxf") == .orderedSame {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Stream header info for every `.mxf` under `folder`. Order of yields is
    /// scan-completion order, not file-system order — clients should identify
    /// entries by `MXFHeaderInfo.fileURL`, not by arrival index.
    func scan(folder: URL) -> AsyncStream<MXFHeaderInfo> {
        let files = Self.discoverMXFFiles(under: folder)
        let concurrency = max(1, maxConcurrent)

        return AsyncStream<MXFHeaderInfo> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                if files.isEmpty {
                    continuation.finish()
                    return
                }

                await withTaskGroup(of: MXFHeaderInfo.self) { group in
                    var index = 0

                    // Seed the group up to the concurrency cap.
                    let initialBatch = min(concurrency, files.count)
                    while index < initialBatch {
                        let url = files[index]
                        group.addTask {
                            let wrapper = BMXWrapper()
                            return await wrapper.info(url: url)
                        }
                        index += 1
                    }

                    // Drain and refill: as each task completes, yield it and
                    // enqueue the next so the group stays near `concurrency` wide.
                    while let result = await group.next() {
                        if Task.isCancelled { break }
                        continuation.yield(result)
                        if index < files.count {
                            let url = files[index]
                            group.addTask {
                                let wrapper = BMXWrapper()
                                return await wrapper.info(url: url)
                            }
                            index += 1
                        }
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience: collect the entire stream into an array. For small folders
    /// or testing. Real UI should consume the stream progressively.
    func scanAll(folder: URL) async -> [MXFHeaderInfo] {
        var results: [MXFHeaderInfo] = []
        for await info in scan(folder: folder) {
            results.append(info)
        }
        return results
    }
}

// MARK: - Clip
//
// One logical clip = one row in the browser = one export record.
// Normal Avid OP-Atom clips have N+1 files (video + N audio stems) sharing
// the same MaterialPackageUID. Files without a parseable UMID become
// "ungroupable" single-file clips so nothing gets silently dropped.

struct Clip: Sendable, Identifiable, Hashable {
    /// Either the shared MaterialPackageUID or (for ungroupable) the file URL string.
    /// Stable across runs for the same inputs; usable as SwiftUI row identity.
    let materialKey: String

    /// The MXFs in this clip, ordered by path for stable output. For ungroupable
    /// clips this contains exactly one file.
    let files: [MXFHeaderInfo]

    /// True when grouping fell back on the file URL because the file's
    /// MaterialPackageUID was missing or unparseable.
    let isUngroupable: Bool

    var id: String { materialKey }

    // Derived values — computed each access; `files` is immutable so results are stable.

    var materialPackageUID: String? {
        isUngroupable ? nil : files.first?.materialPackageUID
    }

    var displayName: String {
        files.first(where: { $0.clipName != nil })?.clipName
            ?? files.first?.fileURL.deletingPathExtension().lastPathComponent
            ?? materialKey
    }

    var projectName: String? {
        files.first(where: { $0.projectName != nil })?.projectName
    }

    var tapeName: String? {
        files.first(where: { $0.tapeName != nil })?.tapeName
    }

    /// Sum of each file's videoTrackCount. For Avid OP-Atom this is typically 1
    /// (video stem) + 0 (audio stems) = 1.
    var videoTrackCount: Int {
        files.reduce(0) { $0 + $1.videoTrackCount }
    }

    /// Sum of each file's audioTrackCount. For OP-Atom this is typically
    /// 0 (video stem) + N * 1 (audio stems) = N.
    var audioTrackCount: Int {
        files.reduce(0) { $0 + $1.audioTrackCount }
    }

    var trackCount: Int { videoTrackCount + audioTrackCount }

    var totalSize: Int64 {
        files.reduce(0) { $0 + $1.fileSize }
    }

    /// Max duration across member files — for OP-Atom all stems share the same
    /// clip duration, but `max` is safer than `first` if parsing missed one.
    var durationFrames: Int64? {
        files.compactMap(\.durationFrames).max()
    }

    /// First non-nil edit rate. OP-Atom stems share the same rate in practice.
    var editRate: (num: Int32, den: Int32)? {
        for file in files {
            if let n = file.editRateNum, let d = file.editRateDen, d > 0 {
                return (n, d)
            }
        }
        return nil
    }

    var durationSeconds: Double? {
        guard let frames = durationFrames, let er = editRate, er.num > 0 else { return nil }
        return Double(frames) * Double(er.den) / Double(er.num)
    }

    var hasParseErrors: Bool {
        files.contains { $0.parseError != nil }
    }

    var parseErrorCount: Int {
        files.filter { $0.parseError != nil }.count
    }

    var fileCount: Int { files.count }
}

// MARK: - ClipAggregator
//
// Pure function: takes a flat list of per-file `MXFHeaderInfo`, groups them
// into logical `Clip`s by `materialPackageUID`. Files without a UMID become
// one-member ungroupable clips so the browser/export never silently drops data.
//
// Output order is deterministic: alphabetical by displayName.

enum ClipAggregator {

    static func aggregate(_ infos: [MXFHeaderInfo]) -> [Clip] {
        var bucketed: [String: [MXFHeaderInfo]] = [:]
        var ungroupable: [MXFHeaderInfo] = []

        for info in infos {
            if let umid = info.materialPackageUID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !umid.isEmpty {
                bucketed[umid, default: []].append(info)
            } else {
                ungroupable.append(info)
            }
        }

        var clips: [Clip] = bucketed.map { (umid, files) in
            Clip(
                materialKey: umid,
                files: files.sorted { $0.fileURL.path < $1.fileURL.path },
                isUngroupable: false
            )
        }

        clips += ungroupable.map { info in
            Clip(
                materialKey: info.fileURL.absoluteString,
                files: [info],
                isUngroupable: true
            )
        }

        clips.sort { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        return clips
    }
}
