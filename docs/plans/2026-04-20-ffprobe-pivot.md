# Plan: Pivot from bmx/mxf2raw to ffprobe for MXF metadata

**Drafted:** 2026-04-20 (evening)
**Status:** ready to execute, awaiting go
**Estimated effort:** ~60–90 min end-to-end
**Supersedes:** parts of Wave 2 (`MXFInfoXMLParser`, `BMXWrapper.info(url:)`)
**Does not affect:** Waves 1, 3, 4 (app shell, Clip/aggregator/exporter, UI wiring)

---

## 1. Why this plan exists

Real-data validation against the user's Avid Media Composer 25.12 output (2026-04-20) revealed that **`mxf2raw` cannot open Avid video stems**. The failure is deterministic and systemic — not file-specific:

```
ERROR (libMXF): 'item->length == 16' failed, in libMXF/mxf/mxf_header_metadata.c:2542
ERROR (libMXF): 'mxf_get_video_line_map_item(...)' failed ...
ERROR: Failed to open MXF file '<any V01 DNxHD stem>': general error
```

The root cause is `mxf_get_video_line_map_item()` in libMXF, which hard-asserts `item->length == 16` (i.e. a 2-element Int32 VideoLineMap — the interlaced shape). Avid MC 25.12 writes DNxHD progressive with a non-16-byte VideoLineMap; libMXF refuses to continue.

**bmx is not going to fix this:**
- `bbc/bmx` archived 2025-09-29. v1.6 (already bundled) is terminal.
- `ebu/bmx` active fork (last commit 2026-02-12) has never touched this assertion. No open PR proposes relaxing it. No issue reports the exact error.
- Fix requires patching libMXF, rebuilding from source with cross-compiled uriparser+expat for arm64, maintaining the patch forever. Multi-week ongoing tax.

**`ffprobe` reads the same file cleanly** and surfaces *more* metadata than mxf2raw did, including `project_name` (which I'd previously marked as likely-unavailable in v1). Verified on both video *and* audio stems in the user's Avid folder.

See `docs/sessions/2026-04-20-evening.md` for the full investigation trail.

## 2. Findings summary

### 2.1 What mxf2raw gave us vs what ffprobe gives us

| Field | mxf2raw XML (audio only, video fails) | ffprobe JSON (all stems) |
|---|---|---|
| `material_package_uid` | `<material_package>/<package_uid>` | `format.tags.material_package_umid` |
| `file_package_uid` | `<file_source_package>/<package_uid>` | `stream[].tags.file_package_umid` |
| clip name | `<clip>/<name>` | `format.tags.material_package_name` |
| edit rate | `<clip>/<edit_rate>` (e.g. `48000/1`) | not in format; derivable from `stream.r_frame_rate` / `time_base` |
| duration | `<duration count="16467840">` attribute | `format.duration` (seconds) |
| video/audio track kind | `<track>/<essence_kind>` (child element, wrong in our parser) | `stream.codec_type` + per-stream `data_type` |
| **project name** | **not surfaced** | **`format.tags.project_name` → "PEEKY"** ✓ |
| original source file | physical_source_package/name | `format.tags.comment_UNC Path` |
| codec | partial | `stream.codec_name` (e.g. `dnxhd`), `stream.profile` |
| product version | identification/product_name | `format.tags.product_name` |
| modification date | identification/modified_date | `format.tags.modification_date` |

### 2.2 Why our Wave 2 parser was broken in addition to the open failure

Even for audio stems that mxf2raw *does* open, our `MXFInfoXMLParser` relies on flat local-name lookups (e.g. key `material_package_uid`). The real XML uses qualified structure: `<material_package>/<package_uid>`. Our parser would have returned `nil` for material_package_uid even on audio stems. Both bugs — the tool-level open failure AND the parser-level key mismatch — get eliminated by the pivot.

### 2.3 Bundle shape today vs after pivot

Current `01_Project/AvidMXFPeek/Resources/`:

| Binary / lib | Size | Keep? |
|---|---|---|
| `ffmpeg` (martin-riedl.de static arm64, 8.0.1) | 59 MB | **drop** (not needed for read-only auditor) |
| `mxf2raw` | 256 KB | **drop** |
| `bmxtranswrap` | 272 KB | **drop** |
| `lib/libbmx.1.dylib` | ~1 MB | drop |
| `lib/libMXF.1.dylib` | ~900 KB | drop |
| `lib/libMXF++.1.dylib` | ~700 KB | drop |
| `lib/libexpat.1.dylib` | ~400 KB | drop |
| `lib/liburiparser.1.dylib` | ~80 KB | drop |
| **to add: `ffprobe`** (martin-riedl.de static arm64) | ~60 MB | **add** |

Net bundle-size change: roughly break-even, maybe −3 MB. **Massive reduction in code surface**: 4 binaries + 5 dylibs → 1 binary, zero dylibs.

### 2.4 Source for the new ffprobe binary

**martin-riedl.de** — same distributor the existing bundled `ffmpeg` came from (confirmed via `ffmpeg -version`: `8.0.1-https://www.martin-riedl.de`, arm64 native, static, already successfully codesigned with our cert). No new vendor to vet; same provenance path already accepted for shipping.

- Latest arm64 snapshot: <https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/snapshot/ffprobe.zip>
- Release builds: <https://ffmpeg.martin-riedl.de/> (prefer release for stability — pick version matching existing ffmpeg 8.0.1 if still listed, otherwise latest release)

## 3. Scope of changes

### 3.1 Files to modify

| Path | Change |
|---|---|
| `01_Project/AvidMXFPeek/Resources/ffprobe` | **new** — place static arm64 binary |
| `01_Project/AvidMXFPeek/Resources/ffmpeg` | delete (unused after pivot) |
| `01_Project/AvidMXFPeek/Resources/mxf2raw` | delete |
| `01_Project/AvidMXFPeek/Resources/bmxtranswrap` | delete |
| `01_Project/AvidMXFPeek/Resources/lib/` | delete entire dir |
| `01_Project/AvidMXFPeek/Services/BMXWrapper.swift` | gut — keep outer class + `info(url:)` async signature, replace everything below it with ffprobe invocation + `FFProbeReport` Codable + mapping; rename file to `MXFProber.swift` as part of 4.6 sweep (defer the rename; just rewrite contents for now) |
| `01_Project/AvidMXFPeek/Services/BundledToolResolver.swift` | remove `.ffmpeg`, `.bmxtranswrap`, `.mxf2raw` enum cases; remove `bmxEnvironment()`, `bmxLibPath`; keep `.ffprobe` only |
| `01_Project/AvidMXFPeek/Services/FFmpegWrapper.swift` | **delete** — dead from P2toMXF, no calls from new code |
| `01_Project/AvidMXFPeek/Services/VerificationService.swift` | **delete** — dead from P2toMXF |
| `01_Project/AvidMXFPeek/Services/P2CardParser.swift` | unchanged (Wave 4.6 rename + split still pending) |
| `01_Project/AvidMXFPeek/ContentView.swift` | surface `MXFHeaderInfo.projectName` in Inspector + Table already does; verify wiring after the rewrite; optionally show UNC path |
| `bundle-ffmpeg.sh` | rename → `bundle-ffprobe.sh`; swap logic; fix broken `RESOURCES_DIR` path (currently `AvidMXFPeek/AvidMXFPeek/Resources` — actual path is `01_Project/AvidMXFPeek/Resources`); remove ffmpeg logic |
| `sign-bundled-binaries.sh` | drop signing of ffmpeg/bmxtranswrap/mxf2raw + dylib loop; keep ffprobe only; fix the same `RESOURCES_DIR` path bug |
| `01_Project/AvidMXFPeek.xcodeproj/project.pbxproj` | remove build-phase reference to ditto'ing `lib/` (since we no longer bundle any dylibs); no other pbxproj changes |
| `docs/PROJECT_STATE.md` | tech-stack section: replace "mxf2raw / ffmpeg / bmxtranswrap + dylibs" with "ffprobe only" |
| `CLAUDE.md` (project root) | same tech-stack correction |
| `docs/decisions.md` | log the pivot with reasoning |

### 3.2 Files explicitly NOT changed

- `Services/P2CardParser.swift` (scanner + Clip + Aggregator) — input interface stays `MXFHeaderInfo`
- `Services/ReportGenerator.swift` (AuditReportExporter, schema v1.0.0) — output unchanged
- `docs/specs/audit-report-schema.md` — JSON schema already uses `project_name` — field was always in the DTO, just nil in practice. Will start carrying real values after pivot. Optional: bump to schema v1.1.0 to signal the field is now reliable; not required for v1.0.0 correctness.

### 3.3 MXFHeaderInfo field additions (optional, low-cost)

Current struct (`BMXWrapper.swift:10-66`) already has `projectName`, `clipName`, `tapeName`, UIDs, etc. Additions worth making while we're in there:
- `codecName: String?` (e.g. "DNxHD")
- `originalSourcePath: String?` (from ffprobe's `comment_UNC Path`)
- `productName: String?` (e.g. "Avid Media Composer 25.12.0.58863")
- `modifiedAt: Date?` (from `modification_date`)

Inspector can surface these; CSV/JSON exporter will skip them for v1 to preserve `schema_version = 1.0.0`, add in v1.1.0.

## 4. Sequenced execution steps

### Step 1 — Fetch + verify the static ffprobe binary (5 min)

```bash
# From project root
cd /Users/sim/XcodeProjects/1-macOS/AvidMXFPeek

# Pull latest release zip (prefer release over snapshot for stability)
curl -L -o /tmp/ffprobe-arm64.zip \
    "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffprobe.zip"

# Unzip
unzip -o /tmp/ffprobe-arm64.zip -d /tmp/ffprobe-arm64/

# Verify it's arm64 static Mach-O
file /tmp/ffprobe-arm64/ffprobe
#   expect: Mach-O 64-bit executable arm64

# Verify no dylib deps (should be system frameworks only)
otool -L /tmp/ffprobe-arm64/ffprobe | head -20
#   expect: only /System/Library/* and /usr/lib/libSystem.B.dylib

# Confirm it actually runs and reports project_name on the user's sample
/tmp/ffprobe-arm64/ffprobe -v error -show_format -show_streams -of json \
    "/Volumes/1TB extra/Avid MediaFiles/MXF/1/V01.E60C20DF_A0C40A0C4043DV.mxf" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('project_name:', d['format']['tags'].get('project_name'))"
#   expect: project_name: PEEKY
```

### Step 2 — Place into bundle + codesign (5 min)

```bash
RES=/Users/sim/XcodeProjects/1-macOS/AvidMXFPeek/01_Project/AvidMXFPeek/Resources
cp /tmp/ffprobe-arm64/ffprobe "$RES/ffprobe"
chmod +x "$RES/ffprobe"

# Reuse existing dev-cert identity; entitlements inherited from sign-bundled-binaries.sh
ENT=$(mktemp)
cat > "$ENT" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
EOF

codesign --force --options runtime --timestamp --sign \
    2D26CB1211F32FD4E3C6EF413EC1EDD6F30631AA \
    --entitlements "$ENT" "$RES/ffprobe"
rm "$ENT"

codesign -dvv "$RES/ffprobe" 2>&1 | grep -E 'Identifier|flags|Authority|Runtime'
#   expect: flags=0x10000(runtime), Apple Development authority chain
```

### Step 3 — Rewrite `BMXWrapper.info(url:)` against ffprobe JSON (20 min)

Keep the outer `class BMXWrapper` + async signature. Replace everything inside with:

```swift
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
    do { data = try await runAndCollect(at: ffprobe, arguments: args) }
    catch {
        return .failed(url: url, size: fileSize, reason: error.localizedDescription)
    }

    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    return FFProbeMapper.map(jsonData: data, fileURL: url, fileSize: fileSize, parseDurationMs: elapsedMs)
}
```

New `FFProbeReport` Codable struct + `enum FFProbeMapper`, roughly 80 lines total:

```swift
private struct FFProbeReport: Decodable {
    struct Format: Decodable {
        let filename: String?
        let duration: String?        // seconds as string in ffprobe JSON
        let size: String?
        let nb_streams: Int?
        let tags: [String: String]?
    }
    struct Stream: Decodable {
        let index: Int?
        let codec_type: String?      // "video" | "audio" | "data"
        let codec_name: String?
        let r_frame_rate: String?    // e.g. "25/1"
        let time_base: String?
        let tags: [String: String]?
    }
    let format: Format
    let streams: [Stream]?
}

enum FFProbeMapper {
    static func map(jsonData: Data, fileURL: URL, fileSize: Int64, parseDurationMs: Int) -> MXFHeaderInfo {
        let report: FFProbeReport
        do { report = try JSONDecoder().decode(FFProbeReport.self, from: jsonData) }
        catch {
            return .failed(url: fileURL, size: fileSize,
                           reason: "ffprobe JSON parse failed: \(error.localizedDescription)")
        }

        let formatTags = report.format.tags ?? [:]
        let streams = report.streams ?? []

        // UIDs — strip the leading "0x" that ffprobe adds for byte-string tags
        let materialUID = formatTags["material_package_umid"].map(stripHexPrefix)
        // file_package_umid lives on streams, not format. Take the first stream's.
        let fileUID = streams.compactMap { $0.tags?["file_package_umid"] }.first.map(stripHexPrefix)

        // Edit rate + duration — derive from first video stream if present, else first audio
        let primary = streams.first(where: { $0.codec_type == "video" }) ?? streams.first
        let (editNum, editDen) = primary?.r_frame_rate.flatMap(parseRational) ?? (nil, nil)
        let durationSeconds = Double(report.format.duration ?? "")
        let durationFrames: Int64? = {
            guard let s = durationSeconds, let num = editNum, let den = editDen, den > 0 else { return nil }
            return Int64((s * Double(num) / Double(den)).rounded())
        }()

        // Track counts
        let video = streams.filter { $0.codec_type == "video" }.count
        // Audio may be codec_type=audio OR codec_type=data with tags.data_type=audio
        let audio = streams.filter {
            $0.codec_type == "audio" || ($0.codec_type == "data" && $0.tags?["data_type"] == "audio")
        }.count

        return MXFHeaderInfo(
            fileURL: fileURL,
            fileSize: fileSize,
            materialPackageUID: materialUID,
            filePackageUID: fileUID,
            editRateNum: editNum,
            editRateDen: editDen,
            durationFrames: durationFrames,
            videoTrackCount: video,
            audioTrackCount: audio,
            clipName: formatTags["material_package_name"],
            projectName: formatTags["project_name"],
            tapeName: streams.compactMap { $0.tags?["reel_name"] }.first,
            parseError: nil,
            parseDurationMs: parseDurationMs
        )
    }

    private static func stripHexPrefix(_ s: String) -> String {
        s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
    }

    private static func parseRational(_ s: String) -> (Int32?, Int32?) {
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let n = Int32(parts[0]), let d = Int32(parts[1]) else { return (nil, nil) }
        return (n, d)
    }
}
```

The `runAndCollect(at:arguments:)` helper (replacing `runMxf2Raw`) fixes the code-review #1 finding by using `waitUntilExit()` + `readDataToEndOfFile()` instead of `readabilityHandler` — no more tail-byte race. ~20 lines:

```swift
private func runAndCollect(at executable: URL, arguments: [String]) async throws -> Data {
    try await Task.detached(priority: .userInitiated) { () throws -> Data in
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit \(p.terminationStatus)"
            throw BMXError.conversionFailed(msg)
        }
        return stdoutData
    }.value
}
```

Delete the old `runMxf2Raw`, the old `DataCollector`, the entire `MXFInfoXMLParser` enum. The existing `OutputCollector` can go too if no longer used (it's only touched by the rewrap path which we're deleting — check call sites).

### Step 4 — Prune `BundledToolResolver`, delete dead services (10 min)

```swift
// BundledToolResolver.swift — new enum
enum BundledTool: String, CaseIterable {
    case ffprobe
}
```

Remove `bmxLibPath`, `bmxEnvironment()`. Any caller of those is in `BMXWrapper.swift`'s legacy code path — all going away.

```bash
# Delete dead files — these are P2toMXF leftovers with zero new-code references
# (verified via: grep -l FFmpegWrapper ...  → only FFmpegWrapper.swift itself;
#                grep -l VerificationService ... → only VerificationService.swift itself)
rm 01_Project/AvidMXFPeek/Services/FFmpegWrapper.swift
rm 01_Project/AvidMXFPeek/Services/VerificationService.swift
```

pbxproj will complain about missing file references; Xcode will offer to remove them on next open, or do it manually in the pbxproj surgery pass (Wave 4.6).

### Step 5 — Fix + trim bundle scripts (5 min)

Rename `bundle-ffmpeg.sh` → `bundle-ffprobe.sh`, replace body:

```bash
#!/bin/bash
# Bundle static ffprobe into AvidMXFPeek.app/Contents/Resources
# Source: https://ffmpeg.martin-riedl.de (arm64 static, same distributor as previous ffmpeg)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/01_Project/AvidMXFPeek/Resources"   # fixed path — was wrong in inherited script

if [ -n "${1-}" ]; then
    FFPROBE_PATH="$1"
elif [ -x "/opt/homebrew/bin/ffprobe" ]; then
    FFPROBE_PATH="/opt/homebrew/bin/ffprobe"
else
    echo "Usage: $0 /path/to/static/ffprobe"
    echo "Recommend: download arm64 static build from https://ffmpeg.martin-riedl.de/"
    exit 1
fi

cp "$FFPROBE_PATH" "$RESOURCES_DIR/ffprobe"
chmod +x "$RESOURCES_DIR/ffprobe"
echo "Bundled ffprobe from $FFPROBE_PATH"
echo "Now run ./sign-bundled-binaries.sh"
```

Trim `sign-bundled-binaries.sh` to sign only ffprobe, fix the path bug:

```bash
RESOURCES_DIR="$SCRIPT_DIR/01_Project/AvidMXFPeek/Resources"   # was $SCRIPT_DIR/AvidMXFPeek/Resources
# ...
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" "$RESOURCES_DIR/ffprobe"
# (drop dylib loop, drop ffmpeg/bmxtranswrap/mxf2raw lines)
```

### Step 6 — Delete unused bundle artifacts (1 min)

```bash
RES=/Users/sim/XcodeProjects/1-macOS/AvidMXFPeek/01_Project/AvidMXFPeek/Resources
rm "$RES/ffmpeg" "$RES/mxf2raw" "$RES/bmxtranswrap"
rm -rf "$RES/lib"
```

### Step 7 — Build, launch, scan the real folder (15 min)

```bash
# Clean derived data for certainty (optional but the earlier runs cached old Resources)
rm -rf ~/Library/Developer/Xcode/DerivedData/AvidMXFPeek-*

# Build
xcodebuild -project 01_Project/AvidMXFPeek.xcodeproj \
    -scheme AvidMXFPeek -destination 'platform=macOS' build

# Launch
killall AvidMXFPeek 2>/dev/null || true
open /Users/sim/Library/Developer/Xcode/DerivedData/AvidMXFPeek-*/Build/Products/Debug/AvidMXFPeek.app
```

Manual verification (user or me via screenshot):
1. Drop `/Volumes/1TB extra/Avid MediaFiles/MXF/1` onto the main pane — expect drop-overlay, then progress bar, then 2 rows in the Table (2 distinct clips based on UMIDs)
2. Each row shows: clip name, short UMID, duration, V+A track counts (1+2 for our samples), project name "PEEKY", size
3. Click a row → Inspector shows per-file list (3 files: V01 + A01 + A02), each with UMID, codec, duration
4. Export CSV → open in Numbers, verify data round-trips correctly
5. Export JSON → verify JSON matches `docs/specs/audit-report-schema.md` v1.0.0 shape, `project_name: "PEEKY"` present

### Step 8 — Log decisions + update state (5 min)

Append to `docs/decisions.md`:
> `2026-04-20-C` — **Pivot from bmx/mxf2raw to ffprobe for MXF metadata extraction.** Evidence: mxf2raw's libMXF asserts `item->length == 16` on Avid MC 25.x VideoLineMap; bbc/bmx archived 2025-09-29, ebu/bmx has no fix planned. ffprobe reads all stems cleanly and surfaces `project_name` which mxf2raw did not. Sole bundled toolchain binary post-pivot. See `docs/plans/2026-04-20-ffprobe-pivot.md`.

Update `docs/PROJECT_STATE.md` tech-stack section and `CLAUDE.md`:
- Drop "mxf2raw", "bmxtranswrap", "+ dylibs", "BMX"
- Replace with: "ffprobe (martin-riedl.de static arm64 build) for metadata extraction — no other bundled toolchain"

Record cookbook-worthy pattern: `ffprobe as the universal MXF metadata reader when bmx/libMXF fails on non-standard Avid descriptors`. Capture to project cookbook; evaluate global cookbook addition after pattern stabilises in v1.1.

## 5. Verification strategy

### 5.1 Unit-level (without full scan)

```bash
# Byte-level: confirm ffprobe sees project_name on the first clip
/path/to/built/ffprobe -v error -show_format -of json \
    "/Volumes/1TB extra/Avid MediaFiles/MXF/1/A01.E60C20E0_A0C40A0C40466A.mxf" \
    | python3 -c "import sys,json; t=json.load(sys.stdin)['format']['tags']; print(t['project_name'], t['material_package_umid'])"
# expected: PEEKY 0x060A2B34...FDEF46149F834AC2
```

### 5.2 End-to-end on the user's Avid folder

Expected Table contents after scan of `/Volumes/1TB extra/Avid MediaFiles/MXF/1`:

| Name | Short UMID | V+A | Project | Size |
|---|---|---|---|---|
| What if there were 1 trillion more trees – Jean-François Bastin | `…FDEF…9F834AC2` suffix (16 hex) | 1+2 | PEEKY | ~5.3 GB |
| *(second clip, name TBD based on V01.E60C1F20 file headers)* | different UMID | 1+? | PEEKY | ~32 GB |

Ungroupable-clip count should be **0**. If any clip shows ungroupable or missing UMID, the mapping is buggy.

### 5.3 Known-issue retire list

| Was | After pivot |
|---|---|
| Code-review #1 — subprocess pipe tail race (readabilityHandler vs terminationHandler) | **Fixed** — new `runAndCollect` uses `readDataToEndOfFile()` + `waitUntilExit()` |
| Code-review #2 — subprocess leak on scan cancellation | **Still open** — same pattern as before; noted for v1.1 |
| Code-review #3 — unreachable `NSError` throw in `writeCSV` | **Unchanged** — exporter untouched; queued as Wave 4.7 |
| Schema-knowledge-partial caveat in `MXFInfoXMLParser` | **Gone** — parser deleted |

## 6. Rollback

All changes are in tracked files. If the pivot goes sideways:

```bash
# Restore the resources (before deletion we can tar them)
cd /Users/sim/XcodeProjects/1-macOS/AvidMXFPeek/01_Project/AvidMXFPeek
tar czf /tmp/avidmxfpeek-resources-backup.tgz Resources/
# …do the pivot…
# If rolling back:
rm -rf Resources/
tar xzf /tmp/avidmxfpeek-resources-backup.tgz
```

Code-side rollback:
- Keep a copy of the current `BMXWrapper.swift` as `BMXWrapper.swift.pre-ffprobe.bak` during the edit window
- `BundledToolResolver.swift` changes are small — git-style diff in memory
- Deleted `FFmpegWrapper.swift` + `VerificationService.swift` are dead code; can restore from P2toMXF if ever needed

No pbxproj changes in the hot path (file deletions will show as missing refs but compile; clean up during Wave 4.6).

## 7. Open questions / risks

1. **Which ffprobe version to pin?** Snapshot vs release. Recommendation: match the existing bundled ffmpeg's vintage (ffmpeg 8.0.1 released late 2025). If martin-riedl.de release matching exists, use that; otherwise, latest release. Document the choice.
2. **Avid's `project_name` tag** — have only verified on this one project ("PEEKY"). If a clip imported from a different Avid project shares the same MediaFiles folder, would `project_name` differ per clip? Almost certainly yes (project name is per-material-package metadata). Need to verify with a multi-project sample in Wave 5.2+.
3. **`comment_UNC Path` nullability** — surfaced in the user's sample. Unknown whether Avid always writes it (e.g. for clips created via Avid capture, not file import). Treat as optional. Don't make the UI break if absent.
4. **ffprobe JSON schema stability** — ffmpeg project is generally careful about tag names, but individual releases could reshape fields. Defensive decoding (tolerate missing fields, use optional types) mitigates this — matches the pattern already in `MXFHeaderInfo`.
5. **Time_base vs r_frame_rate** — for audio stems, `r_frame_rate` is `0/0` (no frame rate). Use `time_base` inverse for audio edit rate (`1/48000` → 48000/1). Handle both.
6. **Large scan performance** — ffprobe process spawn time per file is ~20–50 ms on M-series Macs. With `MXFFolderScanner`'s `maxConcurrent: 8`, a 1000-file folder takes ~6 seconds. A 10000-file folder ~60 seconds. Acceptable; same order of magnitude as `mxf2raw` would have been.

## 8. Post-pivot follow-ups

Push into `TASKS.md` once the pivot lands:

- [ ] **Wave 5.0** Add unit test target (was pending anyway; pivot'd code has more structured JSON input → easier to write fixtures)
- [ ] **Wave 5.1** Unit tests — `FFProbeMapper` fixture tests covering video stem, audio stem, missing-field-fallback, malformed-JSON, and multi-stream (video + audio in same MXF) cases
- [ ] **Wave 5.2b** (new) Adversarial: import a clip with a DIFFERENT avid project_name into the same MediaFiles folder; verify the Table shows two distinct project values
- [ ] **Wave 4.6** pbxproj sweep (unchanged scope, but simpler now — fewer files to manage)
- [ ] **Wave 5 schema bump consideration** — whether to promote `codec_name` / `comment_UNC Path` / `product_name` into `AuditReportExporter` DTO as schema v1.1.0, or keep them internal-only for v1.0.0

## 9. Sources

- [bbc/bmx releases — archived 2025-09-29, v1.6 terminal](https://github.com/bbc/bmx/releases)
- [ebu/bmx — active fork](https://github.com/ebu/bmx)
- [libMXF `mxf_get_video_line_map_item` source (the assertion)](https://raw.githubusercontent.com/ebu/bmx/main/deps/libMXF/mxf/mxf_header_metadata.c)
- [bbc/bmx #36 — VideoLineMap inconsistency](https://github.com/bbc/bmx/issues/36)
- [bbc/bmx #2 — Avid OP-Atom support discussion](https://github.com/bbc/bmx/discussions/2)
- [martin-riedl.de — arm64 static ffmpeg/ffprobe builds (same distributor as existing bundled ffmpeg)](https://ffmpeg.martin-riedl.de/)
- [FFmpeg MXF demuxer commit history — actively maintained](https://github.com/FFmpeg/FFmpeg/commits/master/libavformat/mxfdec.c)

## 10. Decision log entries to write

On completion, append to `docs/decisions.md`:

```
## 2026-04-20-C — Pivot from bmx/mxf2raw to ffprobe

**Context.** Wave 2 built `BMXWrapper.info(url:)` + `MXFInfoXMLParser` against
speculative bmx `mxf2raw --info` XML shapes. Wave 5.2 real-data validation
against Avid Media Composer 25.12 DNxHD output showed that (a) mxf2raw hard-
asserts `item->length == 16` in `libMXF/mxf/mxf_header_metadata.c:2542` when
reading Avid's progressive VideoLineMap, failing on every video stem, and
(b) even on audio stems our parser's flat local-name key-lookup didn't match
the actual qualified XML structure.

**Decision.** Replace mxf2raw as the metadata reader with ffprobe.

**Consequences.**
- Single bundled binary (ffprobe ~60 MB, from martin-riedl.de arm64 static,
  same source as the ffmpeg previously bundled) replaces four binaries +
  five dylibs (~63 MB total).
- `project_name` is now reliably surfaced per clip — previously assumed
  unavailable in v1.
- Subprocess pipe tail race (code-review #1) fixed as a side effect via the
  simpler `waitUntilExit + readDataToEndOfFile` pattern.
- bmx-derived code paths (`FFmpegWrapper`, `VerificationService`, half of
  `BMXWrapper`) deleted; `BundledToolResolver` trimmed to a single case.

**Alternatives considered.**
- Fork ebu/bmx and patch `mxf_get_video_line_map_item` to handle variable
  item lengths — rejected: multi-week build/test/notarise tax, permanent
  maintenance burden, no upstream interest.
- Keep mxf2raw for audio stems alongside ffprobe for video — rejected: two
  code paths where one works, extra binary, no capability gain.
- Custom Swift MXF-header parser — rejected: research-spike territory, same
  Avid-quirk exposure.

See `docs/plans/2026-04-20-ffprobe-pivot.md` for full plan + execution trail.
```
