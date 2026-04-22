import Foundation
import CryptoKit

/// On-disk cache for preview transcodes.
///
/// Each entry is a subdirectory of `rootDir` named after the SHA-256 of the
/// clip identity (`materialKey` + each file's path + each file's size). This
/// means a rescan that finds the same files at the same sizes reuses the
/// cache; moving or resizing any file invalidates the entry.
///
/// Per-entry layout matches what `PreviewTranscoder` writes (playlist.m3u8
/// or master.m3u8 + fMP4 segments) plus a `.transcode-state` JSON sidecar
/// tracking status + started/accessed timestamps for LRU eviction.
///
/// Hash key is 16 hex chars (first 8 bytes of SHA-256). Collision risk at
/// the expected scale (thousands of clips per project) is negligible.
actor PreviewCache {

    enum CacheError: Error, CustomStringConvertible {
        case insufficientDiskSpace(freeBytes: Int64, requiredBytes: Int64)
        case cacheDirectoryCreationFailed(URL, Error)
        case stateReadFailed(URL, Error)

        var description: String {
            switch self {
            case .insufficientDiskSpace(let free, let required):
                return "Insufficient disk space: \(free) B free, \(required) B required"
            case .cacheDirectoryCreationFailed(let url, let e):
                return "Could not create cache dir \(url.path): \(e)"
            case .stateReadFailed(let url, let e):
                return "Could not read transcode-state at \(url.path): \(e)"
            }
        }
    }

    struct TranscodeState: Codable, Equatable {
        enum Status: String, Codable {
            case running
            case complete
            case failed
        }
        let status: Status
        let pid: Int32?
        let startedAt: Date
        var accessedAt: Date
        let reason: String?
    }

    private let fm = FileManager.default
    private let rootDir: URL
    /// Disk-space preflight threshold. Default 1 GB — covers ~33 clip-minutes at
    /// 30 MB/min (see plan §2.4). Overridable for tests (pass a very high value
    /// to force the preflight to fail on any disk).
    private let minFreeBytesForWrite: Int64

    init(rootDir: URL, minFreeBytesForWrite: Int64 = 1_000_000_000) throws {
        do {
            try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        } catch {
            throw CacheError.cacheDirectoryCreationFailed(rootDir, error)
        }
        self.rootDir = rootDir.standardizedFileURL
        self.minFreeBytesForWrite = minFreeBytesForWrite
    }

    /// Default cache root: `~/Library/Caches/<bundle-id>/previews/`.
    static func defaultRootDir() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lucesumbrarum.AvidMXFPeek"
        return caches.appendingPathComponent(bundleID).appendingPathComponent("previews")
    }

    // MARK: - Hashing

    /// Deterministic 16-hex-char key for a clip. Pure — exposed internally
    /// for test assertions and log correlation.
    nonisolated static func hashKey(for clip: Clip) -> String {
        let fileParts = clip.files
            .sorted { $0.fileURL.path < $1.fileURL.path }
            .map { "\($0.fileURL.path)|\($0.fileSize)" }
        let input = "\(clip.materialKey)|\(fileParts.joined(separator: "|"))"
        var hasher = SHA256()
        hasher.update(data: Data(input.utf8))
        let digest = hasher.finalize()
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Absolute path to a clip's cache directory (whether or not it exists).
    /// `isDirectory: true` is load-bearing: without it, `appendingPathComponent`
    /// does a filesystem probe and the returned URL's `hasDirectoryPath` flag
    /// flips based on whether the directory currently exists — which breaks
    /// URL equality across `prepareOutputDir` calls on the same clip.
    nonisolated func directoryURL(for clip: Clip) -> URL {
        rootDir.appendingPathComponent(Self.hashKey(for: clip), isDirectory: true)
    }

    // MARK: - Public API

    /// Return the cache dir for a clip **iff** the entry exists and its
    /// state is `complete`. Touches access time as a side effect (LRU).
    /// Running / failed / missing entries all return nil.
    func pathIfCached(for clip: Clip) -> URL? {
        let dir = directoryURL(for: clip)
        guard fm.fileExists(atPath: dir.path) else { return nil }
        guard let state = try? readState(at: dir), state.status == .complete else { return nil }
        touchAccess(at: dir)
        return dir
    }

    /// Prepare a clean output directory for a new transcode. Wipes any prior
    /// contents, enforces the disk-space preflight, writes a `running`
    /// state file with timestamp. Returns the directory ffmpeg should target.
    func prepareOutputDir(for clip: Clip, pid: Int32? = nil) throws -> URL {
        try assertDiskSpace()
        let dir = directoryURL(for: clip)
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw CacheError.cacheDirectoryCreationFailed(dir, error)
        }
        let now = Date()
        let state = TranscodeState(
            status: .running, pid: pid, startedAt: now, accessedAt: now, reason: nil
        )
        try writeState(state, at: dir)
        return dir
    }

    /// Flip a clip's entry from `running` → `complete`. Safe to call even if
    /// the entry was already complete (idempotent). Bumps access time.
    func markComplete(for clip: Clip) throws {
        let dir = directoryURL(for: clip)
        let existing = (try? readState(at: dir))
        let now = Date()
        let state = TranscodeState(
            status: .complete,
            pid: nil,
            startedAt: existing?.startedAt ?? now,
            accessedAt: now,
            reason: nil
        )
        try writeState(state, at: dir)
    }

    /// Flip a clip's entry from `running` → `failed`, recording the reason.
    /// Failed entries are eligible for eviction on the next `evictToFit`.
    func markFailed(for clip: Clip, reason: String) throws {
        let dir = directoryURL(for: clip)
        let existing = (try? readState(at: dir))
        let now = Date()
        let state = TranscodeState(
            status: .failed,
            pid: nil,
            startedAt: existing?.startedAt ?? now,
            accessedAt: now,
            reason: reason
        )
        try writeState(state, at: dir)
    }

    /// Enumerate and sweep the cache down to 80% of `budgetBytes` when total
    /// on-disk size exceeds the budget. Oldest `.complete` or `.failed`
    /// entries are removed first (by `accessedAt`). `.running` entries are
    /// never touched — they belong to an in-flight transcode.
    @discardableResult
    func evictToFit(budgetBytes: Int64) -> Int {
        let entries = listEntries()
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > budgetBytes else { return 0 }

        let target = Int64(Double(budgetBytes) * 0.8)
        var currentSize = total
        var removed = 0

        // LRU by accessedAt. Running entries filtered out entirely.
        let candidates = entries
            .filter { $0.state.status != .running }
            .sorted { $0.state.accessedAt < $1.state.accessedAt }

        for entry in candidates {
            if currentSize <= target { break }
            try? fm.removeItem(at: entry.url)
            currentSize -= entry.size
            removed += 1
        }
        return removed
    }

    /// Total on-disk size of all entries (including `.transcode-state`).
    func totalSize() -> Int64 {
        listEntries().reduce(0) { $0 + $1.size }
    }

    /// Current state for a clip, nil if no entry exists or state is unreadable.
    func state(for clip: Clip) -> TranscodeState? {
        try? readState(at: directoryURL(for: clip))
    }

    // MARK: - Internals

    private struct Entry {
        let url: URL
        let state: TranscodeState
        let size: Int64
    }

    private func listEntries() -> [Entry] {
        guard let children = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [Entry] = []
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDir else { continue }
            guard let state = try? readState(at: child) else { continue }
            out.append(Entry(url: child, state: state, size: directorySize(child)))
        }
        return out
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    private func stateFile(in dir: URL) -> URL {
        dir.appendingPathComponent(".transcode-state")
    }

    private func readState(at dir: URL) throws -> TranscodeState {
        let url = stateFile(in: dir)
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TranscodeState.self, from: data)
        } catch {
            throw CacheError.stateReadFailed(url, error)
        }
    }

    private func writeState(_ state: TranscodeState, at dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateFile(in: dir), options: .atomic)
    }

    private func touchAccess(at dir: URL) {
        guard var state = try? readState(at: dir) else { return }
        state.accessedAt = Date()
        try? writeState(state, at: dir)
    }

    private func assertDiskSpace() throws {
        let values = try? rootDir.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let free = Int64(values?.volumeAvailableCapacity ?? Int.max)
        if free < minFreeBytesForWrite {
            throw CacheError.insufficientDiskSpace(
                freeBytes: free,
                requiredBytes: minFreeBytesForWrite
            )
        }
    }
}
