# Tasks Archive

> **Completed tasks archive.** Used for progress calculation.

## Stats
- **Total archived:** 22
- **Last updated:** 2026-04-21

## Completed

<!-- Newest at top. Added by /log when tasks complete. -->
<!-- Format: - [x] Task description (YYYY-MM-DD) -->

- [x] **5.2b** Multi-project stress test — real-data verification against user's MediaFiles folder containing media from 3 Avid projects across 3 numbered subfolders. Scanner surfaced 3 distinct `project_name` values in the Project column (`sss`, `PEEKY`, `Fookls`), each attributed per-clip from its own MXF header. Confirms ffprobe's per-file `project_name` read isn't leaking a global value across the scan. (2026-04-21)
- [x] **5.3 (cases 1–3)** Adversarial pass Swift tests — new `MXFFolderScannerTests.swift` with 8 tests covering empty folder (3 variants: empty, non-mxf files only, nonexistent path), corrupt MXF (3 variants: single, 5×batched, nested subfolder), permission-denied (2 variants: top-level 0o000 returns empty, denied-subfolder lets top-level files through). All 34 suite tests green in ~1.7 s. Key fix during authoring: path equality broke on macOS's `/var → /private/var` APFS firmlink — `resolvingSymlinksInPath()` is a no-op on firmlinks; must use `URLResourceValues.canonicalPath` to match enumerator output. Case 4 (10k-file stress) left for a manual perf run — ffprobe startup cost × 10k would blow the unit-test budget (2026-04-21)
- [x] **P5** Bundle/sign scripts retrofit — created `bundle-ffprobe.sh` (replaces `bundle-ffmpeg.sh`) with correct `01_Project/AvidMXFPeek/Resources` path, otool-based dylib preflight rejecting Homebrew ffprobe, BSD-portable same-file copy guard. Rewrote `sign-bundled-binaries.sh` — stripped dylib loop and legacy binary signing (ffmpeg/bmxtranswrap/mxf2raw), 80→55 lines. Both smoke-tested green: flags=0x10000(runtime), team=FDMSRXXN73 (2026-04-21)
- [x] **4.6-B** Swift dead-code sweep — 30 P2toMXF files deleted (ConversionViewModel×4, Models×4, Services×13, Views×9) via sed-on-pbxproj + disk rm; trimmed in place: P2CardParser 613→242 LOC (kept MXFFolderScanner/Clip/ClipAggregator), ReportGenerator 401→199 LOC (kept AuditReportExporter), BMXWrapper ~650→300 LOC, BundledToolResolver 4 cases→1, AvidMXFPeekApp legacy notifications removed. Source ~4500→1507 LOC; .app 78→74 MB; 26 tests still green (2026-04-20)
- [x] **5.1** Unit tests — 26 tests across FFProbeMapperTests (9: own-essence extraction video/audio/single-file, defensive decoding, hex-prefix), ClipAggregatorTests (8: grouping, ungroupable, whitespace trim, natural sort, durations, sizes, empty), AuditReportExporterTests (9: CSV metadata rows + RFC 4180 + CRLF + escaping, JSON schema shape + pinned 1.0.0 + ISO dates). All green in ~0.07 s (2026-04-20)
- [x] **5.0** Unit test target wired via Xcode File→New→Target (Swift Testing `@Test`/`#expect`, PBXFileSystemSynchronizedRootGroup for auto-wiring new test files, PBXTargetDependency to app target, `xcodebuild test` runs the suite) (2026-04-20)
- [x] **4.7** Code-review nits — writeCSV uses `Data(text.utf8)` (unreachable NSError throw deleted); audit-report-schema.md gained CSV Export Format section covering metadata-prefix rows, RFC 4180 escaping, CRLF endings, Python+shell parse examples (2026-04-20)
- [x] **4.6-A** pbxproj + bundle cleanup — removed pbxproj refs for ffmpeg/mxf2raw/bmxtranswrap; removed PBXFileSystemSynchronizedRootGroup + PBXFileSystemSynchronizedBuildFileExceptionSet for `lib/`; trimmed Run Script to ffprobe-only; removed stale LIBRARY_SEARCH_PATHS; deleted the 3 binaries + `lib/` from Resources. Bundle 122 MB→59 MB in Resources (2026-04-20)
- [x] Known issue #1 — subprocess pipe tail race in BMXWrapper retired via `runAndCollect` using `waitUntilExit + readDataToEndOfFile` (side effect of P3 ffprobe rewrite) (2026-04-20)
- [x] **P8** Logged decision `2026-04-20-C` in decisions.md; PROJECT_STATE.md + CLAUDE.md tech-stack sections updated to remove bmx toolchain; architectural decision captured to vestige (2026-04-20)
- [x] **P7** Build + launch + scan `/Volumes/1TB extra/Avid MediaFiles/MXF/1` — Table shows 4 clips, all `project_name="PEEKY"`, per-file counts correct after P3.5 fix (2026-04-20)
- [x] **P6** Deleted ffmpeg/mxf2raw/bmxtranswrap + `lib/` from Resources (completed as part of 4.6-A) (2026-04-20)
- [x] **P4** BMXWrapper legacy methods + BundledToolResolver multi-case enum + FFmpegWrapper + VerificationService all removed (completed as part of 4.6-B) (2026-04-20)
- [x] **P3.5** Per-file track-count fix — OP-Atom stems carry the whole clip graph in `streams`; count only own essence (non-nil `codec_name`), fixing `1+6` → `1+2` on YouTube clips. Also fixed `file_package_uid` to come from own stream, not `streams[0]` (2026-04-20)
- [x] **P3** Rewrote BMXWrapper.info(url:) against ffprobe JSON — new FFProbeReport Codable + FFProbeMapper, new runAndCollect subprocess helper (2026-04-20)
- [x] **P2** Bundled ffprobe in Resources, codesigned with hardened runtime (flags=0x10000, Apple Dev cert, Runtime 12.3) (2026-04-20)
- [x] **P1** Fetched + verified martin-riedl.de arm64 static ffprobe 8.1 — Mach-O static, no dylib deps, smoke-tested against real Avid MXF file (2026-04-20)
- [x] **4.5** Progress indicator — `TimelineView` elapsed + scanned/total counter (2026-04-20)
- [x] **4.4** Drag-and-drop folder target on the main pane with drop-target overlay (2026-04-20)
- [x] **4.3** Toolbar wiring — `.fileImporter` for Open Folder; `NSSavePanel` for Export CSV / JSON; Rescan button (2026-04-20)
- [x] **4.2** `ClipTableView` — Table with Name / UMID / Duration / V+A / Project / Size columns (2026-04-20)
- [x] **4.1** `ScanModel` — state enum + @Observable class + consume loop (A1+B3) (2026-04-20)

---
*Auto-updated by /log. Count used for progress calculation.*
