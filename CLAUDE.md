# Avid MXF Peek

Read-only macOS auditor for Avid `MediaFiles/MXF/*/` folders. Groups OP-Atom clips by `MaterialPackageUID`, surfaces owning project/bin, flags orphans not referenced by `.mdb`/`.pmr`.

- **Display name:** `Avid MXF Peek`
- **Target / scheme / executable:** `AvidMXFPeek`
- **Bundle ID:** `com.lucesumbrarum.AvidMXFPeek`
- **Folder:** `/Users/sim/XcodeProjects/1-macOS/AvidMXFPeek/`

## Status
Phase 0 — scoping/scaffolding. No code yet. Forked conceptually from `P2toMXF` on 2026-04-20 per feasibility assessment in `P2toMXF/docs/sessions/2026-04-20.md`.

## Tech stack
- **Language/UI:** Swift + SwiftUI, macOS 14+ (`@Observable` requires 14)
- **App shell:** Directions App Shell Standard — HSplitView, `FCPToolbarButtonStyle`, `.windowStyle(.hiddenTitleBar)`, `.preferredColorScheme(.dark)`, `Theme` struct. See `/Users/sim/XcodeProjects/0-DIRECTIONS/__DIRECTIONS/docs/cookbook/00-app-shell.md`
- **Bundled toolchain:** `ffprobe` (static arm64, martin-riedl.de, v8.1) — sole reader post 2026-04-20-C pivot. Legacy `ffmpeg` / `mxf2raw` / `bmxtranswrap` + `lib/*.dylib` still in bundle but dead at runtime; deletion scheduled for Wave 4.6.
- **MXF parsing:** `ffprobe -show_format -show_streams -of json` + `FFProbeMapper` in `Services/BMXWrapper.swift`. **NOT** bmx/mxf2raw — libMXF's `VideoLineMap` assertion is incompatible with Avid Media Composer 25.x progressive output; see `docs/decisions.md` entry `2026-04-20-C`.
- **Per-file essence counting:** Avid OP-Atom files enumerate the whole clip's stem graph in `ffprobe`'s `streams`. The file's *own* essence is the stream with a non-nil `codec_name`; everything else is a ref to a sibling stem. Counting only the own stream keeps `Clip.{video,audio}TrackCount` honest.
- **Database parsing:** `.mdb` / `.pmr` — OMFI/Bento containers, no viable OSS parser; orphan detection deferred to v1.1 (decision `2026-04-20-B`)
- **Concurrency:** Swift Concurrency, `withTaskGroup` for bounded-concurrency directory scans, `AsyncStream<MXFHeaderInfo>` → `@Observable ScanModel` with debounced batch aggregation (A1/B3 — 50 yields ∥ 250 ms)
- **Entitlements:** Sandbox off, hardened runtime on, disable-library-validation, allow-unsigned-executable-memory (inherited from the toolchain bundling pattern)

## Key architecture decisions
See `docs/decisions.md` for full reasoning.
1. **Fork from P2toMXF, don't extend it.** Reuse Services layer, rewrite Models + Views.
2. **v1 is read-only.** No writes, no preview, no database mutation. Surface facts; user acts elsewhere.
3. **Use `mxf2raw --info` for UMID extraction.** No custom MXF parser — aggregation logic only.
4. **Single-folder drop target.** No library / no persisted scan history in v1.
5. **CSV + JSON export in v1.** Both formats — CSV for humans, JSON for scripts.
6. **`.mdb`/`.pmr` parsing is a parallel research spike.** App shell + grouping + export do not block on it. Spike must resolve before v1 ships, but failure mode is a narrower v1 (browser + export without orphan detection), not a dead project.

## Reuse checklist (from P2toMXF)
Must-read when porting:
1. `P2toMXF/CLAUDE.md` — architecture, bundling pattern, Xcode gotchas (lib folder NOT in project navigator, Run Script ditto phase, `ENABLE_USER_SCRIPT_SANDBOXING=NO`)
2. `P2toMXF/APP/P2toMXF/Services/BMXWrapper.swift` — `mxf2raw` invocation pattern; extend with `--info` parsing
3. `P2toMXF/APP/P2toMXF/Services/VerificationService.swift` — "inspect MXF without converting" model
4. `P2toMXF/APP/P2toMXF/Services/P2CardParser.swift` → `discoverP2Cards(in:)` — parallel directory-scan template
5. `P2toMXF/bundle-ffmpeg.sh` + `sign-bundled-binaries.sh` — toolchain bundling + codesigning

**Skip (not needed):** `FFmpegWrapper.swift` concat pipeline, `SpeedTracker`, `QueueManager` persistence.

## v1 scope
Single-folder drop target → scan `.mxf` → cluster by `MaterialPackageUID` → parse `.mdb`/`.pmr` for references → show browser with clip name, UMID, duration, tracks, project, size, orphan flag → export CSV + JSON audit report.

**Deferred (v2+):** Preview/playback, writes (delete/move/re-link), Avid project integration, multi-folder library with persisted scan history.

## Parallel research track: `.mdb` / `.pmr` spike
Must resolve before v1 ships. Starts alongside app-shell work, not blocking it. See `docs/decisions.md` "2026-04-20 - `.mdb` / `.pmr` parsing runs as a parallel research spike" for the plan. Survey MDVx, `mdbtool`, forum write-ups; capture sample DBs from a known-state MediaFiles folder; hex-inspect for record structure.

## Documentation
- `docs/00_base.md` — Directions framework index
- `docs/PROJECT_STATE.md` — current phase, focus, blockers (keep <100 lines)
- `docs/decisions.md` — why behind each architectural choice
- `docs/sessions/` — daily session logs

## Session-start hint
`/status` shows current position. All v1-scoping questions resolved 2026-04-20. Next session: read `docs/cookbook/00-app-shell.md` (mandatory), then create the Xcode project in `01_Project/AvidMXFPeek.xcodeproj`.
