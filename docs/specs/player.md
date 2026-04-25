# Player (v1.2) — Specification

**Status:** Draft
**Created:** 2026-04-21
**Last Updated:** 2026-04-21
**Related decisions:** `2026-04-20-C` (ffprobe pivot) — this spec proposes reintroducing `ffmpeg` alongside `ffprobe`, reversing part of Wave 4.6-A's bundle diet.

---

## Problem Statement

### What problem does this solve?
AvidMXFPeek v1 shows users what's in their `MediaFiles/MXF/` folders — but not what any given clip *contains*. To confirm a clip's identity they currently have to:
- Note the filename, switch to Finder, drag the OP-Atom files into a scratch Avid bin → wait → preview
- OR drag into Resolve's Media page (works but is a whole DAW for a glance)
- OR give up and delete based on filename guesswork

The Reddit thread that motivated this project (`r/Avid`, 2026-04-20) called this out explicitly — the OP praised Kyno for "opening everything" and noted that MDVx's key weakness is it can't preview media files. **Preview is the feature that separates "a better Finder" from "a Kyno replacement."**

### Who has this problem?
Assistant editors and editors auditing MediaFiles folders between projects. They already have the app surfacing metadata — what they lack is a fast sanity-check: *is this the clip I think it is?*

### How do they solve it today?
- Drag into Avid scratch bin (slow, pollutes the project)
- Open in Resolve Media page (works, but overkill)
- Rely on filenames + duration + duration arithmetic (error-prone)

---

## Proposed Solution

### One-Liner
Select a clip in the browser and get a scrubbable video+audio preview in the inspector pane, with audio-track-pair selection when the clip has more than one pair of audio stems.

### Key Capabilities
1. **Play a clip in-app** — video + synchronized stereo audio, matching the source duration
2. **Scrub arbitrarily** — seek to any point via native AVPlayer chrome (timeline, time display, keyboard shortcuts)
3. **Pick an audio pair** — when a clip has multiple audio stems (e.g. 4 stems → 2 pairs), user chooses which pair feeds the stereo output
4. **Degrade gracefully** — clips with parse errors, missing stems, or unreadable files surface a clear error state, not a crash

### User Flow
1. User selects a clip in the `ClipTableView`
2. Inspector pane (right) shows the player above the existing metadata fields
3. On first selection, app kicks off a background transcode of the clip's MXF stems → cached proxy `.mov`
4. Player displays a spinner + "Preparing preview…" with elapsed time while the transcode runs
5. When ready, `AVPlayer` loads the proxy and presents it in `AVPlayerView` — user can hit space to play, drag the scrubber, etc.
6. If the clip has >1 audio pair, a Picker above the player lets the user switch pair; changing the pair regenerates the proxy (or swaps the AVPlayerItem audio selection, depending on implementation — see Open Questions)
7. Selecting a different clip cancels any in-flight transcode and starts a new one

---

## Acceptance Criteria

### Core Functionality

- [ ] **Given** a clip with 1 video stem + 2 audio stems (typical YouTube/Premiere import), **when** selected in the Table, **then** within ~20 seconds a playable video appears in the inspector with synchronized stereo audio.
- [ ] **Given** a clip is playing, **when** the user drags the scrubber, **then** playback seeks to the drag position within 500 ms with no audio/video desync.
- [ ] **Given** a playing clip, **when** the user presses space, **then** playback toggles between play and pause.
- [ ] **Given** a clip with 4 audio stems (two pairs), **when** the user chooses "Pair 2" from the audio picker, **then** audio output switches to stems A03+A04 without restarting video playback from zero.
- [ ] **Given** a clip with 1 video stem + 0 audio stems (camera-native), **when** selected, **then** video plays silent; audio picker shows "No audio" and is disabled.
- [ ] **Given** a clip selected and transcode in progress, **when** the user selects a different clip, **then** the previous transcode is cancelled and the new one begins immediately.

### Edge Cases

- [ ] **Given** a clip with 1 audio stem (mono), **when** selected, **then** the single stem plays on both left and right channels (not silent on one side).
- [ ] **Given** a clip with odd-numbered audio stems (3 or 5), **when** selected, **then** the audio picker shows N/2 rounded down stereo pairs plus a "mono only" option for the last stem.
- [ ] **Given** the user quits the app mid-transcode, **when** the app reopens, **then** no orphan ffmpeg processes remain AND the temp cache is cleaned to stay under the disk budget.
- [ ] **Given** a long clip (>30 min), **when** transcoding for preview, **then** the UI remains responsive (scrolling, selection, sidebar toggle all work during transcode).
- [ ] **Given** the same clip is re-selected within a session, **when** the second selection happens, **then** the cached proxy is reused — no second transcode.

### Error States

- [ ] **Given** a clip with a parseError stem, **when** selected, **then** a warning banner appears above the player explaining which stem is unreadable; video/audio plays if the remaining stems are sufficient.
- [ ] **Given** ffmpeg is missing from the bundle AND from Homebrew fallback, **when** a clip is selected, **then** the inspector shows "Preview unavailable — ffmpeg not found" with no crash.
- [ ] **Given** the transcode fails (ffmpeg non-zero exit), **when** it fails, **then** stderr's last line is shown to the user as a diagnostic.
- [ ] **Given** disk is <1 GB free when a transcode starts, **when** the preflight runs, **then** the transcode is aborted with "Insufficient disk space for preview cache."

---

## Technical Considerations

### Dependencies

**New runtime dependency:**
- `ffmpeg` bundled in `Resources/`. The same martin-riedl.de static arm64 build that provides ffprobe also ships ffmpeg (~90 MB). Would bring `.app` from 74 MB → ~165 MB.

**Existing:**
- `ffprobe` already bundled — continues to be the sole metadata reader for scanning
- AVFoundation / AVKit — for playback chrome
- The `AVPlayerView` (macOS) is a one-liner for standard chrome; `AVPlayerViewController` is iOS-only

**Not useable:**
- `AVMutableComposition` — my original mental model. Dead on arrival because it requires `AVURLAsset(url: mxf)` to succeed, and **AVFoundation has no MXF format reader** (verified 2026-04-21: `AVFoundationErrorDomain Code=-11828 "Cannot Open"`, underlying `NSOSStatusErrorDomain Code=-12847`, "This media format is not supported" — on both DNxHD video stems and PCM audio stems). This is container-level, not codec-level: macOS simply cannot read Avid OP-Atom MXF natively.

### Architecture Notes

**Pipeline:**
```
Clip selection
  → PreviewCache.lookup(clipID)
      → hit? return cached URL
      → miss? spawn PreviewTranscoder
          → ffmpeg remux (−c copy) for short/small clips
          → ffmpeg transcode (DNxHR LB proxy) for long clips
          → output → tmp .mov in cache dir
  → AVPlayerItem(url: cached.mov) → AVPlayer → AVPlayerView
```

**New Swift types:**
- `Services/PreviewTranscoder.swift` — wraps an `ffmpeg` subprocess, async/await interface, cancellation support via `Process.terminate`. Inherits the fire-and-collect pattern from `BMXWrapper.runAndCollect` but adds a progress readback via ffmpeg's `-progress pipe:1` option.
- `Services/PreviewCache.swift` — on-disk LRU keyed by `(clipID, audioPairIndex)`. Default budget 10 GB. Lives in `~/Library/Caches/com.lucesumbrarum.AvidMXFPeek/previews/` (per Apple HIG; user-deletable without affecting behavior).
- `Models/PlaybackState.swift` — `@Observable` wrapper around `AVPlayer` + current clip + audio pair selection + error state.
- `Views/PlayerView.swift` — `AVPlayerView` (via `NSViewRepresentable`) + picker + error banner. Lives inside `ClipInspectorView`.

**Transcode command skeleton:**
```bash
ffmpeg -y -loglevel error -progress pipe:1 \
  -i V01.mxf -i A01.mxf -i A02.mxf \
  -c:v dnxhd -profile:v dnxhr_lb \
  -c:a pcm_s16le \
  -map 0:v -map 1:a -map 2:a \
  /cache/<clipID>-pair0.mov
```

For clips under a size threshold (e.g. duration × video bitrate < 500 MB), skip the proxy encode and do `-c copy` remux instead — faster and perfectly proxy-quality by definition.

**Audio pair selection — two implementations considered:**
1. **Regenerate per pair** — when user switches pair, respawn ffmpeg with different `-map` args, replace AVPlayerItem. Simple, correct, but adds a 30-40 s wait per switch.
2. **Include all pairs, select via AVPlayerItem** — transcode ONCE with all audio stems as separate stereo-labeled tracks in the .mov, let AVPlayer switch tracks via `AVMediaSelectionGroup`. Seamless switch, one transcode. **Preferred** — matches AVKit's native media-selection UX.

### Performance

**Benchmarks from real data (user's 13-minute DNxHD 1080p25 clip, 2026-04-21):**
| Operation | Wall time | Output size |
|-----------|-----------|-------------|
| ffmpeg remux (`-c copy`) | 15 s | 11 GB |
| ffmpeg transcode DNxHR LB | 40 s (projected from 60s sample) | ~3.6 GB |
| AVAsset.load(.tracks) on cached .mov | ~0 s | — |

**Budget targets:**
- First-preview latency: **p95 < 30s for clips ≤ 10 min, < 60s for clips ≤ 30 min**
- Cached-preview latency: **p95 < 1s** (just AVPlayerItem construction)
- Scrub response: **p95 < 500 ms** (native AVPlayer, not under our control)
- Peak CPU during transcode: **< 9 cores** (VideoToolbox-accelerated DNxHR encode; observed ~911% on test machine)

**Disk:**
- Per clip at DNxHR LB: ~280 MB/minute
- Default cache: 10 GB → holds ~35 minutes of previewed content → ~3-5 clips in typical usage
- Eviction: LRU on cache write, evict until under 80% of budget

### Security

- Transcodes write to `~/Library/Caches/` — per HIG, fine without sandboxing.
- `ffmpeg` reads MXF via the same paths the user already granted access to (via `.fileImporter` → security-scoped URL at scan time).
- No network, no external subprocess beyond ffmpeg/ffprobe.
- ffmpeg must be signed with `allow-unsigned-executable-memory` + `disable-library-validation` entitlements — same pattern as ffprobe. Update `sign-bundled-binaries.sh` to cover both binaries (currently just ffprobe).

---

## Out of Scope

Explicitly excluded from v1.2:

- **Export of the proxy** as a distributable file — user wants a glance, not a deliverable
- **Trim / in-out points / clip composition** — this is a previewer, not an NLE
- **Multi-clip timeline playback** — one clip at a time
- **Audio waveform display** — AVPlayerView's built-in controls only
- **Frame-accurate scrubbing** via JKL keyboard controls — AVPlayerView's native scrub only; if frame accuracy is needed we'd add a custom scrub bar in v1.3
- **Re-export to ProRes / H.264** — DNxHR LB is the only proxy codec
- **Video effects / color correction preview** — reads the MXF as-is; no grading
- **Subtitle / caption track support** — Avid clips don't typically carry these in OP-Atom stems
- **Full-screen playback** — inspector-only for v1.2; "pop out to window" is v1.3

---

## Open Questions

| Question | Status | Answer / Next Step |
|----------|--------|--------------------|
| Does the remuxed/transcoded .mov play in AVPlayer despite `AVURLAsset.isPlayable = false`? | **Open — blocker** | Verified 2026-04-21: tracks load (vide/soun/soun) but `isPlayable` reports false. Must confirm with `AVPlayer` directly (may be metadata-only; `isPlayable` can under-report for DNxHD-in-MOV). Wave P1 spike task. |
| Proxy codec choice: DNxHR LB vs H.264 (hardware-encoded) vs ProRes Proxy? | Open | DNxHR LB is the obvious choice (family match with source); H.264 via VideoToolbox would be smaller and faster but introduces a codec family mismatch. Benchmark all three in the P1 spike; decide on quality-vs-speed for the user's content. |
| Cache budget — 10 GB fixed, user-configurable, or tied to free-disk heuristic? | Deferred | Default 10 GB fixed; `AppStorage` override hidden for now. Surface in Preferences if users complain. |
| When user quits app, delete cache or keep? | Deferred | Keep by default (LRU handles eviction across sessions). Menu → "Clear preview cache" as escape hatch. |
| Audio pair switching — regenerate vs AVMediaSelectionGroup? | Preferred = `AVMediaSelectionGroup` | Validates in P1 spike; if AVPlayer can't cleanly switch between stereo-labeled tracks in a single .mov, fall back to regenerate. |
| How to detect "stereo pair" vs "independent mono stems"? Avid naming (`A01`, `A02`, ...) implies ordering, but is A01+A02 always a stereo pair? | Open | Investigate: does Avid ever assign L/R via the `mcaChannelID` SMPTE audio metadata labeling? ffprobe output didn't surface it in 2026-04-21 sample — might need `-show_entries stream_tags` with specific keys. If absent, default to "consecutive pairs" convention, let user override via picker. |
| Where does the player go — inspector pane or separate window? | Resolved = inspector | Matches existing app shell, minimum new UI surface. "Pop out to window" deferred to v1.3. |
| What if the video stem is unreadable but audio stems are OK (or vice versa)? | Open | Fallback: audio-only playback with a "no video" placeholder; or video-only with silence. Decide in P1 spike. |

---

## Implementation Sequencing (for `/plan`)

Full task decomposition belongs in a separate `docs/plans/2026-04-22-player.md` after spec approval. Rough wave shape:

- **Wave P1 — Spike (timeboxed 4 hours).** Answer the top three open questions via a throwaway Swift playground or xcresult test: can AVPlayer play the .mov? Does AVMediaSelectionGroup swap audio cleanly? Does DNxHR LB look acceptable vs source? If any answer is "no", spec revises before Wave P2 starts.
- **Wave P2 — Infrastructure.** Bundle ffmpeg, update `sign-bundled-binaries.sh` + `bundle-ffprobe.sh` to `bundle-toolchain.sh`, wire `BundledTool.ffmpeg` into resolver, test signature chain.
- **Wave P3 — Transcoder service.** `PreviewTranscoder`, `PreviewCache`, unit tests for cache eviction + hash-keying, mock ffmpeg for tests.
- **Wave P4 — Model layer.** `PlaybackState` @Observable, wiring to `ScanModel.selectedClip`, lifecycle (spawn/cancel on selection change).
- **Wave P5 — UI.** `PlayerView` with `AVPlayerView`, audio-pair picker, progress/error states, inspector integration.
- **Wave P6 — Adversarial.** Error-state tests mirroring 5.3 (missing stem, corrupt stem, 0-audio camera clip, odd-stem counts, disk full, rapid clip switching).

Estimated effort: spike 4h, full build 10-15 hours spread across 2-3 sessions. Ship v1.2.

---

## Related

- **Decisions:** `docs/decisions.md` entry `2026-04-20-C` (ffprobe pivot — this spec's ffmpeg reintroduction is a complementary add, not a reversal)
- **Backlog entry it replaces:** `docs/TASKS.md` — "v1.2 preview candidate — real in-app AVPlayer with AVComposition stitching…" (the AVComposition part is dead; the goal is the same)
- **Alternative cheap path:** `docs/TASKS.md` — "v1.1 preview candidate — context-menu 'Open original source in QuickTime' via `NSWorkspace.shared.open` on `comment_UNC Path`". Still valuable as a sidecar; covers YouTube/Premiere workflows in zero code. Not a substitute for v1.2 — camera-native clips have no UNC Path.
- **Source project screenshots:** 2026-04-21 inspector view — `docs/sessions/2026-04-21.md` embedded media (post-player-state).
- **Cookbook patterns that apply:** `43-subprocess-fire-and-collect.md` (for the transcoder subprocess), `35-asyncstream-bounded-fanout.md` (if we ever batch-transcode multiple clips), `29-disk-space-preflight.md` (for the cache budget check).
- **Cookbook patterns this feature will create:** ffmpeg-remux-vs-transcode decision matrix; AVMediaSelectionGroup audio-pair switching; macOS-side-effect-cache lifecycle (LRU in ~/Library/Caches).

---

## Review Checklist

- [x] Problem statement is clear (Reddit-validated; competitors confirm gap)
- [x] Acceptance criteria testable (Given/When/Then)
- [x] Edge cases documented (mono, odd stems, long clips, missing binary)
- [x] Out of scope explicit (aggressive — trim, export, multi-clip, waveform all deferred)
- [ ] Open questions resolved — **no, 4 remain blocker-level; Wave P1 spike exists to resolve them**
- [x] Technical considerations cover dependencies (ffmpeg bundle, AVFoundation, disk)
- [x] Security implications considered (cache location, entitlements, no network)

**Status gate:** spec is Draft until Wave P1 spike completes. Post-spike, update this doc with concrete answers, promote to "Approved", then run `/plan` to produce the executable plan.
