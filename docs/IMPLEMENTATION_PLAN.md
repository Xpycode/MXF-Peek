# Implementation Plan — Avid MXF Peek v1

> Researched 2026-04-20. Supersedes the "Next session" sketch in `sessions/2026-04-20.md`.
> Regenerate if assumptions break; do not patch.

## Goal
Ship a read-only macOS auditor that points at an `Avid MediaFiles/MXF/*/` folder, groups OP-Atom clips by `MaterialPackageUID`, and exports a CSV/JSON audit report. Orphan detection is **explicitly deferred to v1.1**; see research findings below.

---

## Research findings (2026-04-20)

### Finding 1 — `mxf2raw` capability is confirmed
Bundled `mxf2raw` (bmx v1.6.0, already in `P2toMXF/Resources/`) supports:
- `-i / --info` → emits MXF metadata
- `--info-format xml` → **stable machine-parseable output** (use this, not text)
- `--info-file <name>` → write to file (we'll pipe stdout instead)
- `--avid` → extract Avid-specific metadata (project name, tape name, master mob refs)
- `--check-complete` → validates structure, fails on truncated writes

**Decision:** invoke as `mxf2raw --info --info-format xml --avid <file>`, capture stdout, parse XML with `XMLParser` / `XMLDocument`.

**Gap:** no `.mxf` samples on this Mac (confirmed via `mdfind` — zero hits). Cannot validate the exact XML schema until user provides a real file from an Avid MediaFiles folder. Work around by designing the parser defensively (nil-safe, unknown-element tolerant) and validating against the first real sample that lands.

### Finding 2 — `.mdb`/`.pmr` parsing is **not viable for v1**
The research verdict is unambiguous enough to change scope:

| Fact | Source |
|------|--------|
| `msmMMOB.mdb` is **not** a Microsoft Access file despite the extension | [archiveteam/OMF](http://fileformats.archiveteam.org/wiki/OMF_Interchange) |
| It is **OMFI data stored in Bento containers** (Apple's compound-document format, early '90s) | archiveteam/OMF; Avid error codes like `omfiHPDomain_INT_FAILED` |
| Bento is effectively dead — no maintained OSS parser exists | [archiveteam/Bento](http://fileformats.archiveteam.org/wiki/Bento) |
| Only known OSS reader is **Otneb** (partial shim inside Deck2OMF Suite on SourceForge) | [deck2omf.sourceforge.net](https://deck2omf.sourceforge.net/) |
| BMX library (the one we already bundle) does **not** parse `.mdb`/`.pmr` | [github.com/bbc/bmx](https://github.com/bbc/bmx) README survey |
| MDVx (closed-source, the one working tool) reads these directly and says "only the info in .mdb/.pmr is used" | [MDVx manual](http://djfio.com/mdv/MDVx-theManual.pdf) (host was ECONNREFUSED during research) |
| `msmMMOB.mdb` holds MOB (Media OBject) records with Source IDs (UMID equivalents) | Avid community forums |
| `msmFMID.pmr` is a Persistent Media Record — an index of file MOBs → MXF files | Avid community forums |

**Verdict:** a correct Bento/OMFI parser is a multi-week spike on unmaintained '90s specs, with no sample files on hand and no way to produce synthetic ones. For v1 this cost is not justified — we'd be gold-plating a single feature (orphan detection) at the risk of the whole ship date. **Defer.**

### Finding 3 — P2toMXF port surface (~4,700 LOC Services total)
| File | LOC | v1 action |
|------|-----|-----------|
| `BundledToolResolver.swift` | 121 | Port as-is |
| `DiskSpace.swift` | 55 | Port as-is |
| `TempDirectoryManager.swift` | 76 | Port as-is (may not need it) |
| `UpdaterController.swift` | 39 | Port as-is |
| `BMXWrapper.swift` | 340 | Port + **extend with `info(url:) async throws -> MXFHeaderInfo`** |
| `P2CardParser.swift` | 372 | Port **structure** (`withTaskGroup` scan pattern); replace P2 domain with MXF folder walk |
| `VerificationService.swift` | 736 | **Port only the "inspect without converting" pattern**, drop conversion bits |
| `FFmpegWrapper*` | 903 | **Skip** |
| `QueueManager*` | 999 | **Skip** |
| `SpeedTracker.swift` | 320 | **Skip** |
| `ThumbnailManager.swift` | 260 | **Skip** |
| `ReportGenerator.swift` | 198 | **Write fresh** (P2 one is conversion-queue-specific) |
| `Resources/lib/` (5 dylibs) | — | Port as-is + same Run-Script ditto phase |
| `bundle-ffmpeg.sh`, `sign-bundled-binaries.sh` | — | Port as-is |

Net new Swift for v1: ~800–1200 LOC (models + scan + aggregate + export + SwiftUI shell).

---

## Revised v1 scope

**In scope:**
- Single-folder drop target / Open-Folder toolbar button
- Scan `.mxf` files recursively under selected folder
- Per-file: invoke `mxf2raw --info --info-format xml --avid`, parse UMID/duration/tracks/project
- Group OP-Atom files by `MaterialPackageUID` → one row per logical clip
- Browser UI: list clips with name, UMID, duration, tracks (V/A count), project, size
- Toolbar: Open Folder, Rescan, Export CSV, Export JSON
- Exports write to user-chosen path via `NSSavePanel`

**Deferred to v1.1+ (explicit, documented):**
- **Orphan detection** via `.mdb`/`.pmr` cross-reference — needs the OMFI/Bento spike
- Preview/playback
- Any writes (delete/move/re-link)
- Multi-folder library / persisted scan history

This narrowing is a direct consequence of Finding 2. The `docs/PROJECT_STATE.md` "v1 scope" section needs updating to match — flag when user approves this plan.

---

## Acceptance Criteria (v1)

- [ ] User selects a folder; app recursively lists every `.mxf` inside
- [ ] Each `.mxf` is parsed via `mxf2raw --info --info-format xml --avid`; failures are surfaced per-file, not fatal
- [ ] Files sharing a `MaterialPackageUID` appear as one row (tracks = sum of V+A count)
- [ ] Clip row shows: name, UMID (short form), duration `HH:MM:SS:FF`, track count, owning project (from `--avid`), total size
- [ ] Export CSV produces a valid RFC-4180 file readable in Numbers/Excel
- [ ] Export JSON is valid against a documented schema (schema file ships with the app)
- [ ] 500-MXF folder scans in under 30 s on M4 Pro (perf budget — adjust after first real-data run)
- [ ] No crashes on: empty folder, folder with zero MXFs, folder with one corrupt MXF, folder with 10k MXFs

---

## Build sequence (waves)

### Wave 1 — scaffold & toolchain (parallel, no deps)
- [ ] **1.1** Read `docs/cookbook/00-app-shell.md` in full → `(reference only)`
  - Success: know the App Shell Standard constraints cold before Xcode project creation
- [ ] **1.2** Create Xcode project `01_Project/AvidMXFPeek.xcodeproj` → App Shell Standard (HSplitView, `FCPToolbarButtonStyle`, `Theme`, `.windowStyle(.hiddenTitleBar)`, `.preferredColorScheme(.dark)`, `.toolbarRole(.editor)`)
  - Bundle: `CFBundleDisplayName=Avid MXF Peek`, `CFBundleName=AvidMXFPeek`, id=`com.lucesumbrarum.AvidMXFPeek`
  - Entitlements: sandbox OFF, hardened runtime ON, `allow-unsigned-executable-memory`, `disable-library-validation`
  - Success: app launches, shows empty HSplitView
- [ ] **1.3** Port `Resources/lib/` + `bundle-ffmpeg.sh` + `sign-bundled-binaries.sh` from P2toMXF
  - Add Run Script phase that `ditto`s `Resources/lib/` into the bundle
  - **Critical:** `Resources/lib/` stays OUT of the Xcode project navigator
  - `ENABLE_USER_SCRIPT_SANDBOXING=NO` on that phase
  - Success: `Contents/Resources/mxf2raw` resolves and runs `--version` at launch
- [ ] **1.4** Port `BundledToolResolver.swift` → `Services/BundledToolResolver.swift`
  - Success: `BundledToolResolver.resolve(.mxf2raw)` returns the correct URL

### Wave 2 — parse & scan (depends on Wave 1)
- [ ] **2.1** Define `Models/MXFHeaderInfo.swift`
  - Fields: `fileURL`, `materialPackageUID: UUID/String`, `sourcePackageUID`, `duration: CMTime`, `trackCount`, `videoTrackCount`, `audioTrackCount`, `projectName: String?`, `tapeName: String?`, `fileSize: Int64`, `parseError: Error?`
- [ ] **2.2** Port + extend `Services/BMXWrapper.swift` with `info(url:) async throws -> MXFHeaderInfo`
  - Invokes `mxf2raw --info --info-format xml --avid <file>`, parses stdout XML
  - Defensive parsing: unknown elements ignored, missing fields → nil
  - **Backpressure:** unit test against a known XML fixture checked into `Tests/Fixtures/`
- [ ] **2.3** Port `P2CardParser.swift` structure → `Services/MXFFolderScanner.swift`
  - `scan(folder:) -> AsyncStream<MXFHeaderInfo>` using `withTaskGroup`
  - Throttle concurrency (start with 8 parallel `mxf2raw` calls; tune later)
  - Per-file errors surface as `MXFHeaderInfo` with `parseError` set, not thrown

### Wave 3 — aggregate & export (depends on Wave 2)
- [ ] **3.1** `Models/Clip.swift` — aggregated view (one per `MaterialPackageUID`)
- [ ] **3.2** `Services/ClipAggregator.swift` — groups `[MXFHeaderInfo]` by UMID → `[Clip]`
- [ ] **3.3** `Services/AuditReportExporter.swift` — CSV (RFC-4180) + JSON
  - JSON schema checked into `docs/specs/audit-report-schema.md`

### Wave 4 — UI (depends on Wave 3)
- [ ] **4.1** `Views/ClipListView.swift` — `Table` with clip columns
- [ ] **4.2** `Views/ClipDetailView.swift` — right pane, shows file list for selected clip
- [ ] **4.3** Toolbar: Open Folder (`.fileImporter` or `NSOpenPanel`), Rescan, Export CSV, Export JSON
  - Reference: `docs/cookbook/05-export-file-dialogs.md`
- [ ] **4.4** Drag-and-drop folder target on main view (`docs/cookbook/11-drag-drop.md`)

### Wave 5 — verification
- [ ] **5.1** Unit tests: XML fixture → `MXFHeaderInfo`; aggregation rules; CSV/JSON shape
- [ ] **5.2** Real-data run on user-provided sample folder (blocks here until sample arrives — see "Dependencies")
- [ ] **5.3** Adversarial passes: empty folder, 1 corrupt MXF, permission-denied subfolder, 10k-file synthetic folder

---

## Dependencies / Blockers

| Item | Who resolves | Why it matters |
|------|--------------|----------------|
| **At least one real Avid `MediaFiles/MXF/<n>/` folder with `.mxf` files** | User — export from a current project | Wave 2.2 unit-test fixture + Wave 5.2 validation. We cannot confirm `mxf2raw` XML schema without real output. |
| **Ideally**: the `msmMMOB.mdb` and `msmFMID.pmr` alongside those MXFs | User | For the v1.1 orphan-detection spike. Not blocking v1 ship. |

---

## Parallel research track — OMFI/Bento spike (non-blocking, v1.1 prep)

Starts whenever user provides sample `.mdb`/`.pmr` files. Goal = feasibility read, not a shipped parser.

1. Hex-dump first 512 bytes of `msmMMOB.mdb` → confirm Bento magic vs. other container
2. Clone + build Otneb from Deck2OMF SourceForge, run its dump tool against the sample
3. Survey MAJ (AMWA-TV/maj) for any Avid-OMFI dissector code
4. If Otneb + MAJ together give a readable MOB list with Source IDs → schedule a v1.1 Swift port
5. If not → orphan detection stays a "nice to have" permanent deferral; ship v1 + maybe integrate MDVx as a sibling tool

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `mxf2raw --info --info-format xml` produces different XML than expected | Medium | High (blocks Wave 2) | Design parser to tolerate schema drift; validate early on first real sample |
| `mxf2raw --avid` doesn't expose `projectName` at all | Medium | Medium (UI column missing) | Fallback: extract from `AAF`/`SourceReference` paths if present; else show blank |
| User's MediaFiles folder is massive (100k+ MXFs) | Low | Medium (perf) | Stream results, don't block UI; show progress; cap concurrent `mxf2raw` calls |
| Codesigning the bundled toolchain on a fresh Developer ID setup has friction | Medium | Low-Medium | Inherited from P2toMXF — follow the exact `sign-bundled-binaries.sh` flow |
| Sample MXFs from user use a codec or wrapper `mxf2raw` rejects | Low | Medium | Handle `--check-complete` failure; report as parse-error row, don't crash |

---

## Operational Learnings
*Populated during implementation.*

## Blocked Tasks
*Populated when tasks block.*

---

## Execution Log
| Wave | Started | Completed | Commits |
|------|---------|-----------|---------|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |

---
*Delete when v1 ships. Archive to `sessions/` for reference.*
