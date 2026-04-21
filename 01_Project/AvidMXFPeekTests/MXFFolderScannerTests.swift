import Foundation
import Testing
@testable import AvidMXFPeek

/// 5.3 adversarial passes for `MXFFolderScanner` — empty folder, corrupt MXF
/// mid-scan, permission-denied subfolder. Case 4 (10k-file synthetic stress)
/// is a manual run, not covered here.
///
/// These tests drive real `ffprobe` subprocesses against on-disk fixtures.
/// Tests depend on `ffprobe` being resolvable via `BundledToolResolver` —
/// when run under `xctest` there's no app bundle, so the Homebrew fallback
/// (`/opt/homebrew/bin/ffprobe` or `/usr/local/bin/ffprobe`) is required.
struct MXFFolderScannerTests {

    // MARK: - Helpers

    /// Make a fresh temp folder, run `body`, then restore permissions and delete.
    /// Permission restore is defensive: tests that chmod 000 subfolders would
    /// otherwise leak undeletable directories if they threw before restoring.
    private func withTempFolder<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let fm = FileManager.default
        // Canonicalize the temp-dir parent so the URL prefix matches what
        // the scanner's FileManager enumerator returns. On macOS, `/var` is
        // an APFS firmlink to `/private/var` — `resolvingSymlinksInPath()`
        // leaves it untouched, but `canonicalPath` (and `realpath(3)`) resolve
        // it. Without this, `row.fileURL == expected` fails with
        // `/private/var/...` vs `/var/...` mismatches.
        let rawParent = fm.temporaryDirectory
        let canonical = (try? rawParent.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            ?? rawParent.path
        let parent = URL(fileURLWithPath: canonical)
        let folder = parent.appendingPathComponent("AvidMXFPeekTests-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        defer {
            // Restore 0o755 on each top-level child (including any chmod-000
            // subfolders) so `removeItem` can recurse. Using shallow
            // `contentsOfDirectory` — recursive variants fail on locked subtrees.
            // Top-level chmod happens last so we can still list after a test
            // locked the parent itself.
            if let children = try? fm.contentsOfDirectory(atPath: folder.path) {
                for child in children {
                    let full = folder.appendingPathComponent(child).path
                    _ = try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: full)
                }
            }
            _ = try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            _ = try? fm.removeItem(at: folder)
        }

        return try await body(folder)
    }

    /// Write N zero bytes to `url` so ffprobe has something to choke on.
    private func writeDummyMXF(at url: URL, bytes: Int = 512) throws {
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    // MARK: - Case 1: empty folder

    @Test func emptyFolder_producesNoResults() async throws {
        try await withTempFolder { folder in
            let scanner = MXFFolderScanner()
            let results = await scanner.scanAll(folder: folder)
            #expect(results.isEmpty)
        }
    }

    @Test func folderWithNoMXFExtension_producesNoResults() async throws {
        try await withTempFolder { folder in
            try "hello".data(using: .utf8)!
                .write(to: folder.appendingPathComponent("notes.txt"))
            try Data(repeating: 0, count: 64)
                .write(to: folder.appendingPathComponent("clip.mov"))

            let scanner = MXFFolderScanner()
            let results = await scanner.scanAll(folder: folder)
            #expect(results.isEmpty, ".mxf extension check is case-insensitive but format-agnostic — non-mxf files must be ignored")
        }
    }

    @Test func nonexistentFolder_returnsEmptyWithoutCrashing() async throws {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let scanner = MXFFolderScanner()
        let results = await scanner.scanAll(folder: ghost)
        #expect(results.isEmpty)
    }

    // MARK: - Case 2: corrupt MXF mid-scan

    @Test func singleCorruptMXF_surfacesAsParseErrorRow() async throws {
        try await withTempFolder { folder in
            let corrupt = folder.appendingPathComponent("corrupt.mxf")
            try writeDummyMXF(at: corrupt, bytes: 512)

            let scanner = MXFFolderScanner()
            let results = await scanner.scanAll(folder: folder)

            #expect(results.count == 1)
            let row = try #require(results.first)
            #expect(row.parseError != nil, "corrupt MXF must surface a parseError, not be silently dropped")
            #expect(row.fileURL == corrupt)
            #expect(row.fileSize == 512)
            #expect(row.materialPackageUID == nil)
            #expect(row.videoTrackCount == 0)
            #expect(row.audioTrackCount == 0)
        }
    }

    @Test func multipleCorruptMXFs_allSurfaceIndividually() async throws {
        try await withTempFolder { folder in
            for i in 0..<5 {
                let url = folder.appendingPathComponent("bad_\(i).mxf")
                try writeDummyMXF(at: url, bytes: 128)
            }

            let scanner = MXFFolderScanner()
            let results = await scanner.scanAll(folder: folder)

            #expect(results.count == 5, "scan must not abort on individual failures — every file gets a row")
            #expect(results.allSatisfy { $0.parseError != nil }, "every corrupt file must produce a parseError row")
        }
    }

    @Test func corruptMXFInNestedSubfolder_isStillEnumerated() async throws {
        try await withTempFolder { folder in
            let sub = folder.appendingPathComponent("nested/deeper")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let corrupt = sub.appendingPathComponent("corrupt.mxf")
            try writeDummyMXF(at: corrupt, bytes: 256)

            let scanner = MXFFolderScanner()
            let results = await scanner.scanAll(folder: folder)

            #expect(results.count == 1, "scanner recurses into subfolders — nested file must be found")
            #expect(results.first?.fileURL == corrupt)
            #expect(results.first?.parseError != nil)
        }
    }

    // MARK: - Case 3: permission-denied

    @Test func permissionDeniedTopLevel_returnsEmptyInsteadOfCrashing() async throws {
        try await withTempFolder { folder in
            // Seed a file, then lock the folder so the enumerator can't walk it.
            try writeDummyMXF(at: folder.appendingPathComponent("would-have-scanned.mxf"))

            let fm = FileManager.default
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
            // Defer in withTempFolder restores 0o755 before removal.

            let scanner = MXFFolderScanner()
            let results = await scanner.scanAll(folder: folder)

            #expect(results.isEmpty, "chmod-000 top-level folder must degrade to empty, not crash")
        }
    }

    @Test func permissionDeniedSubfolder_topLevelFilesStillScan() async throws {
        try await withTempFolder { folder in
            let topFile = folder.appendingPathComponent("top.mxf")
            try writeDummyMXF(at: topFile, bytes: 256)

            let denied = folder.appendingPathComponent("locked")
            let fm = FileManager.default
            try fm.createDirectory(at: denied, withIntermediateDirectories: true)
            try writeDummyMXF(at: denied.appendingPathComponent("hidden.mxf"), bytes: 256)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)

            let scanner = MXFFolderScanner()
            let results = await scanner.scanAll(folder: folder)

            // Current behavior: FileManager enumerator with nil errorHandler
            // silently skips denied subdirectories. Top-level files still scan.
            // If we ever want denied subfolders to surface as a user-visible
            // warning, change the errorHandler in discoverMXFFiles.
            let scannedPaths = Set(results.map { $0.fileURL.path })
            #expect(scannedPaths.contains(topFile.path), "top-level file must still be scanned despite denied sibling")
            #expect(!scannedPaths.contains(denied.appendingPathComponent("hidden.mxf").path),
                    "file inside chmod-000 subfolder should not be reached (current documented behavior)")
        }
    }
}
