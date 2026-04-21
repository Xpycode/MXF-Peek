# Tasks

> **Persistent task tracker.** Lives in `docs/`. Progress syncs to PROJECT_STATE.md.

## Backlog
<!-- Ideas and future work. Added by /interview, user input, or discovered during development. -->
<!-- Priority: top = highest, bottom = lowest -->

- [ ] Known issue #2 — in-flight `ffprobe` subprocesses leak on scan cancellation (scan Task.cancel doesn't propagate to the launched subprocess; inherited from original BMXWrapper design). Low-priority: per-file probes are ~50 ms, so leak window is short; at 10k files × 8 concurrent the worst case is 8 orphan ffprobe processes completing naturally within a second of cancel.
- [ ] v1.1 research spike — OMFI/Bento parsing for `.mdb`/`.pmr` orphan detection. Sample files are now available at `/Volumes/1TB extra/Avid MediaFiles/MXF/1/` (`msmMMOB.mdb`, `msmFMID.pmr`). Spike plan in `docs/IMPLEMENTATION_PLAN.md` "Parallel research track" section.
- [ ] v1.1 preview candidate (cheap win) — context-menu "Open original source in QuickTime" via `NSWorkspace.shared.open` on `comment_UNC Path` from ffprobe. Covers YouTube/Premiere-import workflows (which have a UNC path); camera-native clips fall through to "Reveal in Finder". Zero playback code.
- [ ] v1.2 preview candidate — real in-app AVPlayer with AVComposition stitching V01 + selected A0n stems. ~30 lines including track-picker UI. DNxHD decode native on macOS 12+ via VideoToolbox, PCM audio free.
- [ ] Cosmetic: `BMXWrapper` → `MXFProber` / `FFProbeService` type rename; `Services/P2CardParser.swift` → `Services/MXFFolderScanner.swift` file rename. Each needs pbxproj edit (4 places) + Swift rename-symbol. Low value, easy to batch.
- [ ] Sidebar content — currently empty `SidebarPlaceholder`. Candidates: folder tree (filter by numbered subfolder when scanning a whole MXF/ parent), project filter (list distinct `project_name` values), summary stats panel (total bytes / clip count / parse-error count). Not in v1 scope per the "single folder drop target, no library" decision.

## Current Sprint
<!-- Active work. 2026-04-21: P5 + 5.3 (cases 1-3) + 5.2b archived; 1 pending for v1 completion. -->

- [ ] **5.3-case-4** 10k-file synthetic folder — manual perf/smoke run: `for i in {1..10000}; do dd if=/dev/urandom of=/tmp/stress/file_$i.mxf bs=1k count=1; done`, scan from the app, watch Activity Monitor for CPU/memory shape and ffprobe fan-out behavior under the 8-concurrent cap. Not Swift-testable at this volume (ffprobe startup cost × 10k would blow the unit-test budget).

---

## Progress Calculation

```
Sprint Progress = checked in Current Sprint / total in Current Sprint
Overall Progress = (archived count + checked) / (backlog + current + archived)
```

Archived task count is read from `tasks-archive.md` header.

## Workflow Integration

| Command | Action |
|---------|--------|
| `/interview` | Adds tasks to Backlog |
| `/plan` | Moves Backlog → Current Sprint |
| `/execute` | Checks off tasks as waves complete |
| `/log` | Archives checked tasks, updates PROJECT_STATE.md progress bar |
| `/status` | Reports progress from checkbox counts |

---
*Location: `docs/TASKS.md`. Parsed by Directions app.*
