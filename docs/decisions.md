# Decisions Log

This file tracks the WHY behind technical and design decisions.

---

## Template

### [Date] - [Decision Title]
**Context:** [What situation prompted this decision?]
**Options Considered:**
1. [Option A] - [pros/cons]
2. [Option B] - [pros/cons]

**Decision:** [What we chose]
**Rationale:** [Why we chose it]
**Consequences:** [What this means going forward]

---

## Decisions

### 2026-04-20 - Fork from P2toMXF rather than extend it

**Context:** Reddit thread (r/Avid, 2026-04-20) described the pain of auditing Avid `MediaFiles/MXF/` folders with Kyno dying. P2toMXF already carries a bundled MXF toolchain (`mxf2raw`, `bmxtranswrap`, `ffmpeg`, `ffprobe`) and a macOS app shell that could be reused — roughly 60% overlap per the feasibility assessment in `P2toMXF/docs/sessions/2026-04-20.md`.

**Options Considered:**
1. **Extend P2toMXF** — add an "Audit" tab alongside the converter
   - Pros: Zero scaffolding work; shared toolchain is already live
   - Cons: Conflates two unrelated tools (convert vs. audit); Dilutes P2toMXF's single-purpose clarity; UI archetypes differ (queue/converter vs. browser/organizer)
2. **Fork to a new project** — new repo, reuse Services layer, rewrite Models + Views
   - Pros: Preserves single-purpose clarity of both apps; clean UI archetype for audit; independent versioning/signing
   - Cons: One-time scaffolding cost; duplicate toolchain bundle (~several MB per app)
3. **Build from zero** — ignore P2toMXF entirely
   - Pros: No legacy decisions carried forward
   - Cons: Wastes the bundled-toolchain + dylib-rewiring work that already took weeks to get right

**Decision:** Option 2 — fork to a new project (AvidAudit).

**Rationale:** The Services layer (bundled binaries + BMXWrapper + directory scan) is the load-bearing piece and it ports cleanly. The Models + Views must be rebuilt anyway (grouping logic, orphan detection, browser UI), so there's no value in fighting P2toMXF's converter-shaped UI.

**Consequences:**
- P2toMXF stays focused on card-ingest → timeline MXF conversion
- Avid MXF Peek gets its own app identity, signing, and release cadence
- Toolchain bundling pattern is now a reusable template across future MXF-adjacent tools

---

### 2026-04-20 - v1 is read-only (no writes, no preview, no database integration)

**Context:** The temptation with an audit tool is to immediately add "delete orphan" or "re-link clip" buttons. Doing that in v1 risks both data loss (if the orphan detection has false positives) and scope creep (preview, playback, Avid project integration).

**Options Considered:**
1. **Full-service** — audit + delete + relink + preview + export-to-Avid
2. **Read-only audit** — surface facts only; user takes action in Finder/Avid/Resolve
3. **Audit + export report** — read-only + CSV/JSON output for batch action elsewhere

**Decision:** Option 3 for v1 — read-only with CSV + JSON export (see separate export decision below).

**Rationale:**
- Orphan detection against `.mdb`/`.pmr` needs real-world validation before we ever write to disk
- Resolve already handles preview adequately per the Reddit discussion
- "See what you have" is the explicit ask in the thread; "act on it" is secondary and already served by Finder

**Consequences:**
- Zero risk of user-induced data loss in v1
- Drop from P2toMXF: BMX rewrap, concatenation, timecode continuity, queue persistence, speed/ETA tracker
- CSV + JSON export ships in v1 (see later decision); no writes to user filesystem beyond that user-initiated export

---

### 2026-04-20 - Use `mxf2raw --info` for UMID extraction (no custom MXF parser)

**Context:** Avid stores clip grouping inside MXF Header Partition Packs via `MaterialPackageUID` / `SourcePackageID`. These are what let us cluster OP-Atom video and audio stems into a single logical clip.

**Options Considered:**
1. **Custom MXF parser** — read KLV packets directly in Swift
2. **Use bundled `mxf2raw --info`** — already in P2toMXF's resources, already parses headers
3. **Use `ffprobe` only** — may not surface the grouping UIDs reliably

**Decision:** Option 2. `mxf2raw` ships with `libMXF++` which is the reference implementation; no reason to rebuild it.

**Rationale:** `mxf2raw --info file.mxf` already outputs `MaterialPackageUID` and `SourcePackageID`. The work is aggregation, not parsing.

**Consequences:**
- Avid MXF Peek inherits P2toMXF's `Resources/lib/` bundle + dylib rewiring
- `BMXWrapper.swift` ports over with a new `info(url:)` method added
- `ffprobe` stays bundled for duration/track-layout readouts but isn't load-bearing for grouping

---

### 2026-04-20 - App name is "Avid MXF Peek"

**Context:** Working name during scaffolding was "AvidAudit." Needed a final public-facing name before Xcode project creation.

**Options Considered:**
1. **AvidAudit** — descriptive but generic; overlaps with non-Avid "auditing" connotations
2. **MXFPeek** — short, evocative, but doesn't signal the Avid-specific OP-Atom/grouping/orphan angle
3. **Avid MXF Peek** — combines Avid specificity with the "quick look" intent the Reddit thread describes

**Decision:** "Avid MXF Peek" — display name with spaces. Executable/scheme/target identifier is `AvidMXFPeek` (no spaces, identifier-legal). Bundle ID `com.lucesumbrarum.AvidMXFPeek`.

**Rationale:** "Peek" matches the v1 philosophy (read-only, inspect-don't-act). "Avid" scopes the app's audience clearly. The three-word display name is fine on macOS — Apple's own apps do this ("Apple Configurator 2", "Pro Video Formats").

**Consequences:**
- Working folder renamed `AvidAudit/` → `AvidMXFPeek/` in the same session (2026-04-20); harness CWD followed the inode rename without issue
- `CFBundleDisplayName` = "Avid MXF Peek", `CFBundleName` = "AvidMXFPeek"
- Domain convention confirmed as `com.lucesumbrarum.<AppName>` (matches CropBatch; P2toMXF's `com.p2tomxf.app` is the outlier, not the pattern)

---

### 2026-04-20 - Single-folder drop target, no multi-folder library

**Context:** Needed to choose between two UX archetypes: (a) single scope target like P2toMXF's card picker, or (b) library-style app that remembers multiple volumes across launches (would need `QueueManager`-style persistence).

**Options Considered:**
1. **Single folder** — user picks a folder, app audits it, results clear on next pick. No persistence.
2. **Library** — app tracks many volumes, shows last-scan timestamps, allows diffing scans over time.

**Decision:** Option 1 — single folder.

**Rationale:** v1 is a sharp tool, not a file manager. Library UX adds persistence, indexing, migration concerns, and staleness-detection logic that obscure the core audit value. If users want multi-folder audits, they can run the tool multiple times and export the reports.

**Consequences:**
- `QueueManager` persistence from P2toMXF is **not** ported
- No SQLite, no `UserDefaults` scan history, no "recent folders" menu (at most a standard Recents menu item via `NSDocumentController` conventions — deferred)
- If v2 demands a library, it's a clean additive layer rather than a retrofit

---

### 2026-04-20 - v1 ships with CSV + JSON audit report export

**Context:** The Reddit thread's baseline ask is "see what I have." But producing a file you can hand to a collaborator, email to post-production, or diff month-over-month is the natural next step — and not hard once the data model exists in memory.

**Options Considered:**
1. **View-only v1, export in v1.1** — original draft; minimizes scope
2. **CSV only** — spreadsheet-friendly, good for assistants/producers
3. **JSON only** — structured, good for scripting / re-processing
4. **Both CSV and JSON in v1**

**Decision:** Option 4. Both formats in v1.

**Rationale:** Once the audit model is in memory, serializing to either format is a ~30-line job per format. Skipping it for v1 saves a trivial amount of work but defers a feature users will immediately want. CSV for humans, JSON for scripts — different audiences, same data.

**Consequences:**
- v1 includes an "Export…" toolbar action with format picker
- Need an `AuditReport` value type with `Codable` conformance for JSON and a dedicated CSV encoder
- Export dialog follows `docs/cookbook/05-export-file-dialogs.md`

---

### 2026-04-20 - `.mdb` / `.pmr` parsing runs as a parallel research spike

**Context:** Orphan detection — the Kyno-killer feature — requires parsing Avid's `.mdb` and `.pmr` MediaDatabase files. The format is not publicly documented; existing open-source tooling (`MDVx`, `mdbtool`) may cover some of it but the extent is unknown. The user confirmed "proper research needed."

**Options Considered:**
1. **Spike first, block everything else** — no app shell until we know the format
2. **Ship app shell + grouping without orphan detection** — defer orphan feature to v1.1
3. **Parallel tracks** — spike research + app-shell development proceed independently; merge when spike resolves

**Decision:** Option 3 — parallel tracks.

**Rationale:** The app shell, directory scan, `mxf2raw --info` grouping, and CSV/JSON export are standalone-valuable even without orphan detection — this is roughly what Kyno delivered and users praised. Blocking all of it on the hardest research question is unnecessary. Meanwhile, orphan detection *is* the flagship feature, so the spike can't be punted indefinitely — it must resolve before v1 is declared shippable.

**Spike plan:**
- Survey existing tools: MDVx source (if available), `mdbtool`, forum write-ups, Avid Media Composer SDK (if anything public)
- Capture sample `.mdb` + `.pmr` files from a known-state MediaFiles folder (known clip list → known expected parse output)
- Binary inspection with `hexdump` + `xxd` to identify record boundaries
- Probable structure: fixed-width header + repeating clip records keyed by UMID

**Consequences:**
- If spike succeeds → orphan detection ships in v1
- If spike partially succeeds (e.g., can read `.mdb` but not `.pmr`) → ship what works, document the gap
- If spike fails entirely → v1 ships as "OP-Atom browser with export" and orphan detection becomes v2 ambition (still better than Finder, still an improvement over current tooling)

---

### 2026-04-20-B - Orphan detection deferred from v1 to v1.1

**Context:** Implementation-planning research (see `docs/IMPLEMENTATION_PLAN.md` Finding 2) investigated the `.mdb`/`.pmr` parsing spike originally scheduled as a parallel v1 track. The format is **not** Microsoft Access despite the extension — it is **OMFI data stored in Bento containers** (Apple's compound-document format from the early '90s). OMFI SDK error codes like `omfiHPDomain_INT_FAILED` confirm the lineage.

**Options Considered:**
1. **Write a Bento/OMFI parser from scratch** — multi-week spike on an unmaintained format; no sample files available on this Mac to validate against
2. **Use Otneb** (partial Bento TOC shim in Deck2OMF Suite on SourceForge) — only known OSS reader; niche, old, shim-style, not production-grade
3. **Use BMX** — already bundled, but survey confirmed BMX does **not** parse Avid `.mdb`/`.pmr`
4. **Use AAF SDK** — AAF superseded OMFI but isn't format-compatible; would also be a rewrite
5. **Defer orphan detection to v1.1** — ship v1 without it

**Decision:** Option 5 — defer to v1.1.

**Rationale:**
- Writing a correct Bento parser against '90s specs, with no sample files on hand and no way to produce synthetic ones, is disproportionate to shipping a single feature.
- App shell + folder scan + clip grouping + CSV/JSON export are **standalone-valuable** — this is roughly what Kyno delivered and users praised. v1 remains useful without orphan flagging.
- The Reddit thread that motivated this project described multiple pains; orphan detection is one of them, not the only one.
- Deferring preserves ship speed now while keeping the option open when sample files become available.

**Consequences:**
- v1 scope narrows: no "orphan" column in the browser, no orphan filter in export
- v1 ships faster — unblocks Waves 1–4 of the implementation plan (scaffold, scan, aggregate, UI) with zero OMFI dependency
- Sample `.mdb`/`.pmr` files remain a research target — when user provides real samples, the parallel spike starts: hex-dump → try Otneb → survey MAJ → assess feasibility for v1.1
- If the spike eventually fails too, orphan detection becomes permanently-deferred and the app stays a "grouping browser with export" — still a Kyno-class improvement over current tooling

---

### 2026-04-20-C — Pivot from bmx/mxf2raw to ffprobe for MXF metadata

**Context:** Wave 2 built `BMXWrapper.info(url:)` + `MXFInfoXMLParser` speculatively against the shape of `mxf2raw --info` XML. Wave 5.2 real-data validation on user-supplied Avid Media Composer 25.12 DNxHD output from `/Volumes/1TB extra/Avid MediaFiles/MXF/1` revealed two problems:
1. `mxf2raw` fails deterministically on every Avid video stem with `CHK_ORET(item->length == 16)` in `libMXF/mxf/mxf_header_metadata.c`'s `mxf_get_video_line_map_item` — Avid MC 25.x writes progressive `VideoLineMap` with a non-16-byte layout that libMXF's 2-Int32 assumption rejects at file-open time.
2. Even on audio stems that `mxf2raw` *does* open, our parser's flat local-name key-lookup (`material_package_uid`, `edit_rate_numerator`, etc.) didn't match the actual qualified XML structure (`<material_package>/<package_uid>`, `<edit_rate>25/1</edit_rate>`, `<duration count="…">` attribute).

**Options Considered:**
1. **Fork `ebu/bmx` and patch libMXF** — relax the 16-byte assertion to handle variable VideoLineMap item lengths. Rejected: `bbc/bmx` archived 2025-09-29 with v1.6 terminal; `ebu/bmx` active but no interest in this fix; ownership burden for a multi-week-plus-ongoing patch on a single-use tool.
2. **Hybrid: `mxf2raw` for audio stems, `ffprobe` for video stems** — two code paths; no capability gain; rejected.
3. **Custom Swift MXF-header parser** — multi-week research spike with the same Avid-quirk exposure; rejected.
4. **Bundle Homebrew's dynamic `ffprobe` + all libav* dylibs** — 200+ MB bundle, fragile version coupling; rejected.
5. **`ffprobe` static arm64 from martin-riedl.de (same distributor as the existing bundled `ffmpeg`)** — sole reader, reads both video and audio stems cleanly, surfaces `project_name` (previously believed unavailable), ~60 MB binary replacing 4 binaries + 5 dylibs.

**Decision:** Option 5. `ffprobe` is the sole bundled MXF metadata reader.

**Rationale:** The read-side failure is fundamental to bmx's design assumption about Avid's descriptor shape, not a missing feature; patching upstream is multi-week and unending; ffprobe already works; ffprobe gives us *more* metadata (`project_name`, `comment_UNC Path`, codec details) than the original plan had budgeted for; same distributor (martin-riedl.de) already used for the existing bundled ffmpeg, so the codesign trust chain is unchanged.

**Consequences:**
- `BMXWrapper.info(url:)` rewritten against `ffprobe -show_format -show_streams -of json`.
- New `FFProbeMapper` enum replaces `MXFInfoXMLParser` (deleted).
- **Per-file track counting rewritten** to look only at the file's own essence stream (identified by non-nil `codec_name`). Avid OP-Atom files carry references to sibling stems in their `streams` array — every `.mxf` sees the whole clip graph — which caused an N-way over-count before this fix. `file_package_uid` is similarly read off the own stream, not `streams[0]` (which for audio stems is the video-ref stream).
- **Code-review finding #1** (subprocess pipe tail race in the old `readabilityHandler` pattern) retired as a side effect — the new `runAndCollect` uses `waitUntilExit + readDataToEndOfFile`.
- **`project_name` now reliably surfaced per clip** — every real Avid file has it. Inspector / Table / CSV / JSON all carry it.
- **Legacy bmx + P2toMXF code retained** (FFmpegWrapper, VerificationService, BMXWrapper legacy rewrap methods, BundledToolResolver's ffmpeg/bmxtranswrap/mxf2raw cases, Resources/ffmpeg + mxf2raw + bmxtranswrap + lib/) to keep compile green without a pbxproj sweep — dead at runtime, never reached. Full removal scheduled for Wave 4.6 alongside the model/view split.
- Build-phase Run Script extended to ditto `Resources/ffprobe` into the bundle.

**See:** `docs/plans/2026-04-20-ffprobe-pivot.md` for full execution trail; `docs/sessions/2026-04-20-evening.md` for narrative.

---

*Add decisions as they are made. Future-you will thank present-you.*
