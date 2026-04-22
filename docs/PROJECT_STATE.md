# Project State

> **Size limit: <100 lines.** This is a digest, not an archive. Details go in session logs.

## Identity
- **Project:** Avid MXF Peek
- **Display name:** `Avid MXF Peek`
- **Executable / scheme:** `AvidMXFPeek`
- **Bundle ID:** `com.lucesumbrarum.AvidMXFPeek`
- **Folder:** `/Users/sim/XcodeProjects/1-macOS/AvidMXFPeek/`
- **One-liner:** Read-only macOS auditor for Avid `MediaFiles/MXF/*/` folders — groups OP-Atom clips by `MaterialPackageUID`, shows owning project/bin, flags orphans not referenced by `.mdb`/`.pmr`
- **Tags:** macOS, SwiftUI, Avid, MXF, media-management
- **Started:** 2026-04-20

## Current Position
- **Funnel:** build (ship-prep)
- **Phase:** implementation (Waves 1–4 done, pivot done, tests done, dead-code sweep done, polish remaining)
- **Focus:** v1.2 player — **Waves P1 + P2 + P3 ✅ DONE**. P1 spike (2026-04-21) validated HLS live-mux. P2 bundling (2026-04-22) added ffmpeg alongside ffprobe. P3 server (2026-04-22) landed `PreviewHTTPServer.swift` — actor over NWListener, loopback-only, Range support per §10.2. Next: **Wave P4** (`PreviewTranscoder.swift` — ffmpeg process orchestration + AsyncStream event output).
- **Status:** v1 feature-complete + public on GitHub. **45 tests green** (11 new in PreviewHTTPServerTests: start/stop/idempotent, 404, 403, MIME dispatch, byte-range 206/416/501, concurrent GETs). Source ~1960 LOC (was 1690; +270 server). .app **133 MB**. All operations loopback-only, no firewall/local-network prompts.
- **Last updated:** 2026-04-22 (Wave P3 complete — PreviewHTTPServer shipped with 11 tests green; ready for Wave P4)

## Funnel Progress (Ralph-style)

| Funnel | Status | Gate |
|--------|--------|------|
| **Define** | done | v1 scope narrowed post-research (orphan detection → v1.1) |
| **Plan** | done | `docs/IMPLEMENTATION_PLAN.md` written with 5-wave build sequence |
| **Build** | active | Wave 1 done; Wave 2 next |

## Phase Progress
```
[###############.....] 76% - task-based (22 archived / 29 total incl. v1.1+v1.2 backlog). v1-only: 21 of 22 done ≈ 95%.
```

| Phase | Status | Tasks |
|-------|--------|-------|
| Discovery | done | Feasibility + research complete |
| Planning | done | `IMPLEMENTATION_PLAN.md` + `docs/plans/2026-04-20-ffprobe-pivot.md` |
| Implementation | done (v1) | Waves 1–4 ✅ · pivot 2026-04-20-C ✅ · Waves 4.6-A/4.6-B/4.7/5.0/5.1 ✅ · P5 ✅ · 5.2b ✅ · 5.3(1-3) ✅ · 5.3-case-4 optional (manual perf run) |
| Polish | active | First commit public on GitHub; distribution artifacts + notarized build + version bump pending user decision |
| v1.2 Player | plan ready | `docs/specs/player.md` + `docs/plans/2026-04-22-player-hls.md` both drafted. Design = HLS live-mux + loopback NWListener server + AVPlayer. Wave P1 spike (4h) is the next concrete action; P2-P8 commit on green. |

## Why this, why now
Reddit thread (2026-04-20, r/Avid): Kyno is dying, Avid Media Tool is clunky, MDVx only reads databases not media, Resolve Media page handles preview but not orphan detection. Unmet need: *space accountability* — "which MXFs are wasting space, which project do they belong to?"

## v1 scope (read-only auditor — narrowed 2026-04-20 post-research)
- **Single-folder drop target** (no multi-folder library / no scan history persistence)
- Point at an `Avid MediaFiles/MXF/1` folder (or parent `MediaFiles/MXF/`)
- Scan `.mxf`, invoke `mxf2raw --info --info-format xml --avid` per file
- Cluster by `MaterialPackageUID` → one row per logical clip (video + N audio tracks)
- Extract project name via `--avid` → show owning project per clip
- Browser UI: clip name, UMID, duration, tracks, project, size
- **Audit report export (CSV + JSON)**

## Deferred to v1.1+ (explicit, documented)
- **Orphan detection** via `.mdb`/`.pmr` cross-reference — research showed these are OMFI Bento containers (not MS Access); no maintained OSS parser exists. Deferred per decision 2026-04-20-B.
- Preview/playback, any writes (delete/move/re-link), multi-folder library with persisted scan history, timecode continuity, concatenation, rewrap.

## Parallel research track (non-blocking, v1.1 prep)
OMFI/Bento parsing spike starts once user provides sample `.mdb`/`.pmr` files. See `docs/IMPLEMENTATION_PLAN.md` "Parallel research track" section for plan.

## Carryover from P2toMXF (~60%)
App shell (HSplitView, FCPToolbarButtonStyle, Theme, `.hiddenTitleBar`), bundled `ffmpeg`/`ffprobe`/`bmxtranswrap`/`mxf2raw` with `@executable_path` dylibs, `BMXWrapper.swift`, queue/verification/thumbnail pipeline, `P2CardParser.discoverP2Cards` scan pattern, build-phase `ditto` of `Resources/lib/`, entitlements (sandbox off, hardened runtime, unsigned-memory, library-validation disabled).

## Must build fresh
Clip grouping by MXF header UMIDs, `.mdb`/`.pmr` orphan cross-reference, project-name extraction, browser/organizer UI.

## Active Decisions
- 2026-04-20: Name → "Avid MXF Peek" (display) / `AvidMXFPeek` (target) / `com.lucesumbrarum.AvidMXFPeek`
- 2026-04-20: Single-folder drop-target UX (no library, no persisted scan history)
- 2026-04-20: v1 ships with audit report export — CSV + JSON
- 2026-04-20: `.mdb`/`.pmr` parsing runs as parallel research spike (non-blocking for app shell + grouping)
- 2026-04-20: **Orphan detection deferred to v1.1** — research found `.mdb`/`.pmr` are OMFI Bento containers with no viable OSS parser (decision 2026-04-20-B)
- 2026-04-20: Fork, don't extend — new project, reuse Services, rewrite Models + Views
- 2026-04-20: v1 is read-only; no writes, no preview
- 2026-04-20: Use `mxf2raw --info` for UMID extraction (no custom MXF parser)
- 2026-04-21: Public GitHub repo named **MXF-Peek** (not AvidMXFPeek) to dodge trademark association; app-facing display name + bundle ID unchanged
- 2026-04-21: Preview/playback is the **Kyno-replacement feature**, not polish — promoted from backlog candidate to first-class v1.2 priority (raw Reddit thread confirms MDVx's preview gap is the competitive opening)
- 2026-04-21: v1.2 player path = ffmpeg remux/transcode to cached `.mov` → AVPlayer (the naïve AVComposition path is dead; AVFoundation can't open Avid OP-Atom MXF). Requires reintroducing ffmpeg to bundle. Gated on Wave P1 spike. **→ REVISED 2026-04-21 late**: design shifted from cached full-file transcode to **HLS live-mux** (Option 2 of 7 surveyed). Uniform ~0.5-2s startup vs linear-in-clip-length for the cached approach. HTTP server is loopback-only NWListener, user-invisible. Verified via probes: ffmpeg H.264/VideoToolbox HLS command works against real MXF at ~9× realtime encode; NWListener `requiredLocalEndpoint = .hostPort(.ipv4(.loopback), .any)` is the clean binding syntax. UNC-path fast-path dropped (semantically wrong for an audit tool). Plan at `docs/plans/2026-04-22-player-hls.md`; Option 5 (custom `AVSampleBufferDisplayLayer` + `libavformat`) noted as v2 ambition.

## Blockers
None yet — scaffolding not started.

## Open questions
All v1-scoping questions resolved. Next unknowns live inside the `.mdb` spike and will surface there.

## Resume

---
*Updated by Claude. Source of truth for project position.*
