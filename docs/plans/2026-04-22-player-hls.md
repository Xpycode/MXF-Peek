# Plan: v1.2 Player via HLS live-mux + localhost loopback server

**Drafted:** 2026-04-21 (evening) for execution 2026-04-22+
**Status:** ready to execute, awaiting user go-ahead
**Estimated effort:** P1 spike ~4 h · P2–P8 total ~18–22 h across 3–4 sessions
**Spec:** `docs/specs/player.md` (Draft until P1 spike lands)
**Supersedes:** backlog entry "v1.2 preview candidate — AVPlayer with AVComposition stitching"
**Depends on:** decision 2026-04-20-C (ffprobe-only bundle) — this plan **reintroduces ffmpeg** to the bundle; not a reversal, a controlled addition

---

## 1. Why this plan exists

AVFoundation cannot open Avid OP-Atom MXF. Verified 2026-04-21 via direct `swift` probe against user's real stems:

```
AVFoundationErrorDomain Code=-11828 "Cannot Open"
  underlying NSOSStatusErrorDomain Code=-12847
  "This media format is not supported"
```

Both video (DNxHD) and audio (PCM mono) stems fail at container level — macOS has no MXF format reader. This kills the original backlog plan ("30 lines of AVComposition stitching"). See `docs/specs/player.md` §"Technical Considerations / Dependencies" for the decision cascade.

After evaluating 7 alternative designs (full options matrix in the spec's research trail), **Option 2 — ffmpeg HLS live-mux + localhost loopback HTTP server + AVPlayer** wins because:

1. **Uniform ~0.5–2 s startup** regardless of clip length. The 38-minute Kowloon clip starts as fast as a 30-second YouTube-import clip. Option 1 (cached full-file transcode) can't solve this — its startup is linear in clip duration.
2. **Audio-pair switching via `AVMediaSelectionGroup`** is native AVKit — instant swap, no retranscode.
3. **HTTP server is invisible** to the user. Bound to `127.0.0.1` only: no Local Network prompt (that's for multicast/Bonjour), no firewall prompt (loopback doesn't transit the firewall stack), no credentials, no port UX.
4. **Incremental over Option 1.** The HTTP server is ~80 LOC (NWListener), the ffmpeg command swaps HLS flags for MOV flags, the rest of the pipeline (cache, model, UI) is identical.

**Not chosen, and why:**
- Option 4 (AVAssetResourceLoaderDelegate + fragmented MP4) — viable alternative to the server, but more code for the same outcome and a less-beaten path. Consolation prize if the server proves problematic.
- Option 5 (custom `AVSampleBufferDisplayLayer` + `libavformat`) — the pure NLE architecture, 500–800 LOC, v2 ambition. Free audio switching, zero cache. Worth revisiting after v1.2 ships and we understand real usage.
- Option 6 (KSPlayer) — GPL license blocks distribution.
- Option 7 (VLCKit) — `--input-slave` multi-stem sync is experimental/broken; pays framework cost without solving the hard part.

---

## 2. Design overview

### 2.1 Pipeline

```
┌──────────────────┐
│  Clip selected   │ (from ScanModel.selectedClipID)
└────────┬─────────┘
         │
         ▼
┌──────────────────────────────────────────┐
│  PlaybackCoordinator (@Observable)       │
│                                          │
│  Cache miss?                             │
│   ├─► spawn PreviewTranscoder            │
│   │     ffmpeg → HLS fMP4 segments       │
│   │     in ~/Library/Caches/.../<clipID>/│
│   │                                      │
│   │  FSEvents watches cache dir,         │
│   │  fires firstSegmentReady when        │
│   │  playlist.m3u8 + seg_000.m4s exist   │
│   │                                      │
│   └─► once firstSegmentReady:            │
│         open AVPlayerItem(url:           │
│           http://127.0.0.1:PORT/         │
│             <clipID>/playlist.m3u8)      │
│                                          │
│  Cache hit?                              │
│   └─► straight to AVPlayerItem open      │
└────────┬─────────────────────────────────┘
         │
         ▼
┌──────────────────┐          ┌──────────────────────┐
│  AVPlayerView    │  ◄────── │  PreviewHTTPServer   │
│  (inside         │          │  NWListener on       │
│  ClipInspector)  │          │  127.0.0.1:any       │
│                  │          │  serves cache root   │
└──────────────────┘          └──────────────────────┘
```

### 2.2 The verified ffmpeg HLS command

Probed 2026-04-21 against user's real MXF (30 s sample of 13-min DNxHD clip):

```bash
ffmpeg -y -loglevel error \
  -i V01.mxf \
  -i A01.mxf -i A02.mxf \
  -filter_complex "[1:a:0][2:a:0]join=inputs=2:channel_layout=stereo[pair0]" \
  -map 0:v:0 -c:v h264_videotoolbox -b:v 4M -pix_fmt yuv420p \
  -map "[pair0]" -c:a aac -b:a 192k \
  -f hls -hls_time 4 -hls_playlist_type event \
  -hls_flags independent_segments+append_list \
  -hls_segment_type fmp4 \
  -hls_segment_filename <cache>/<clipID>/seg_%03d.m4s \
  <cache>/<clipID>/playlist.m3u8
```

**Verified:**
- VideoToolbox H.264 encode runs at ~9× realtime on this machine → full 13-min clip = ~86 s full encode, but first segment lands in <1 s wall time
- Output: ~15 MB/min at 1080p25 4Mbit/s H.264 + 192kbps AAC → full 13-min ≈ 200 MB
- Valid HLS playlist structure (`EXT-X-VERSION:7`, `EXT-X-MAP: init.mp4`, fMP4 segments)

**Differences from the probe:**
- Probe used `-hls_playlist_type vod` (closed-ended, written at end only); the real command uses `event` + `append_list` so the playlist grows as segments land and AVPlayer can reread it
- `independent_segments` flag ensures each segment is self-contained (important for scrubbing)

**Multi-pair audio (4, 6, or 8 stems):** extend the filter graph + `-var_stream_map` — unverified, handled in Wave P1 spike:

```bash
# Skeleton for 4 stems (2 pairs):
-filter_complex "[1:a][2:a]join=inputs=2:channel_layout=stereo[pair0]; \
                 [3:a][4:a]join=inputs=2:channel_layout=stereo[pair1]" \
-map 0:v -c:v h264_videotoolbox -b:v 4M \
-map [pair0] -c:a aac -b:a 192k \
-map [pair1] -c:a aac -b:a 192k \
-var_stream_map "v:0,agroup:aud a:0,agroup:aud,language:en,name:Pair1,default:yes a:1,agroup:aud,language:en,name:Pair2" \
-master_pl_name master.m3u8 \
...
```

### 2.3 The HTTP server

Swift Network framework `NWListener`, bound to loopback only:

```swift
let params = NWParameters.tcp
params.allowLocalEndpointReuse = true
params.requiredLocalEndpoint = NWEndpoint.hostPort(
    host: .ipv4(.loopback),  // 127.0.0.1
    port: .any               // kernel picks
)
let listener = try NWListener(using: params)
listener.stateUpdateHandler = { state in
    if case .ready = state, let port = listener.port {
        // assigned port available here
    }
}
listener.newConnectionHandler = { conn in ... }
listener.start(queue: .main)
```

Handler: parse HTTP/1.1 GET, map path to a file under cache root, reply with `Content-Type`, `Content-Length`, `Accept-Ranges: bytes`, body. Handle `Range:` requests for byte-range (AVPlayer occasionally uses these; fMP4 segment serving should not need them but supporting costs ~15 LOC).

Content-Type rules:
- `.m3u8` → `application/vnd.apple.mpegurl`
- `.m4s` / `.mp4` → `video/mp4` (or `video/iso.segment` — both work)
- anything else → `application/octet-stream` (defensive; should not occur)

### 2.4 Cache strategy

`~/Library/Caches/com.lucesumbrarum.AvidMXFPeek/previews/<hashKey>/`

`hashKey = SHA-256(clip.materialKey | sorted(clip.files.map { $0.fileURL.path + $0.fileSize }))[:16]`

Including file path + size in the hash means a rescan that finds the *same* files at the *same* sizes reuses the cache. Moving or replacing a file invalidates.

Per-entry directory layout:
```
<hashKey>/
├── playlist.m3u8       (or master.m3u8 + per-rendition playlists for multi-pair)
├── init.mp4
├── seg_000.m4s
├── seg_001.m4s
├── ...
└── .transcode-state    (JSON: {"status": "running"|"complete"|"failed", "pid": …, "startedAt": …})
```

**LRU:** track `accessedAt` via `URLResourceValues.contentAccessDateKey` on the directory. On new transcode start, if total cache size > 10 GB, remove oldest entries until under 80% of budget (8 GB). Evict only entries where `.transcode-state.status == "complete"` — don't delete in-flight.

### 2.5 AVPlayer wiring

```swift
let url = server.baseURL.appendingPathComponent("\(hashKey)/playlist.m3u8")
let asset = AVURLAsset(url: url)
let item = AVPlayerItem(asset: asset)
player.replaceCurrentItem(with: item)

// Audio-pair switching:
let group = try await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)
if let audibleGroup = try await asset.loadMediaSelectionGroup(for: .audible) {
    let options = audibleGroup.options
    // Present as Picker; on user select:
    item.select(option, in: audibleGroup)
}
```

---

## 3. Waves

### Wave P1 — De-risking spike (timeboxed 4 h) ✅ **COMPLETE 2026-04-21**

**Goal:** answer the remaining unknowns before committing to waves P2+. Throwaway code, not production — validates the design.

Test clip: `/Volumes/1TB extra/Avid MediaFiles/MXF/20260421/V01.E60D568D_8BA778BA77F7EV.mxf` (14 min DNxHD 1080p25 "Building a Brutalist Dresser.mp4", plus A01/A02 siblings).

- [x] **P1.1** Full 14-min VOD HLS transcode → 211 segments + init.mp4, 415 MB total, encode wall time 89 s (9.46× realtime, matches plan estimate). Benign `dnxhd: unknown header 0x00 0x00 0x00 0x00 0x00` on final 12 frames (<0.1%) — MXF tail padding artifact, segments still clean.
- [x] **P1.2** Live-mux (`event + append_list`) → playlist grows during encode (4 → 8 → 13 → 18 → 23 seg-refs over 10 s of wall time), no ENDLIST until ffmpeg exits. SIGTERM flushes ENDLIST + an unexpected leading `#EXT-X-DISCONTINUITY` — cosmetic only, production path uses natural completion.
- [x] **P1.3** Throwaway `NWListener` server (`/tmp/avid-spike/p1.3-server.swift`) binds `127.0.0.1:.any`, serves files with correct Content-Types (`.m3u8` → `application/vnd.apple.mpegurl`, `.m4s/.mp4` → `video/mp4`). Verified 200 on playlist, 200 on binary init segment (byte-exact), 404 on missing path, 8 concurrent GETs in 22 ms.
- [x] **P1.4** AVPlayer opens the http URL while ffmpeg still running → **video visibly plays** (user-confirmed). Server log shows AVPlayer polling playlist (2245B → 5095B across rereads) and fetching segments in playback order — live-mux validated end-to-end.
- [x] **P1.5** End-to-end latency measured: ffmpeg start → first seg on disk = **0.76 s**; server up = 1.28 s; AVPlayer `.readyToPlay` = +0.43 s after URL handoff. **Total ≈ 2.5 s** (target was <5 s). ✅
- [x] **P1.6** Multi-pair HLS with `-var_stream_map` → master.m3u8 + 3 rendition playlists (stream_0/video, stream_PairA/audio, stream_PairB/audio). `AVMediaSelectionGroup(.audible)` returns 2 options ("English", "audio_2 - English"). Programmatic `item.select(option, in: group)` verified: selection changes, `currentTime` continues advancing (no player reset). **`AVPlayerView`'s floating controls do NOT expose the audio menu** — confirms §P7.1 must provide a custom Picker.
- [x] **P1.7** Scrub across full clip → works (user-confirmed "I could scrub and it was reactive").
- [x] **P1.8** Open http URL before playlist exists → AVPlayer transitions to `.failed` (status=2), UI shows ghost play button + `—:—` timeline, no crash / no hang. Confirms production code must gate `replaceCurrentItem` on `firstSegmentReady` (§2.1 guard is correctly specified).
- [x] **P1.9** ffmpeg 8.1 arm64 static from martin-riedl.de = **60 MB** (26 MB zipped). `otool -L` shows system-frameworks-only (VideoToolbox, AudioToolbox, AVFoundation present). Projected final .app = **~134 MB** (plan projected 165 — ~30 MB headroom vs. estimate).

**Exit criteria:**
- P1.4, P1.5, P1.6, P1.7 all green → promote spec to Approved, proceed to Wave P2
- Any fail → revise plan: likely fall back to Option 1 (cached full-file transcode) OR bump to Option 4 (delegate + fMP4). Do **not** begin Waves P2+ on shaky spike.

**Verdict:** all four gating criteria GREEN. **Cleared to proceed to Wave P2.** Spike scratch artifacts at `/tmp/avid-spike/` (discardable).

### Wave P2 — ffmpeg bundling (depends on P1 pass) ✅ **COMPLETE 2026-04-22**

> **Note:** P2.3 / P2.4 revised per §10.1 post-spike correction — pbxproj uses legacy PBXGroup + shell-script build phase, not a synchronized folder.

- [x] **P2.1** ffmpeg 8.1 arm64 static from martin-riedl.de, 26 MB zipped → 60 MB unzipped. `otool -L` confirms system-frameworks only (AVFoundation, VideoToolbox, AudioToolbox, libSystem, libc++, libbz2, libiconv). No third-party dylibs.
- [x] **P2.2** `bundle-ffprobe.sh` → `bundle-toolchain.sh`. New CLI: `./bundle-toolchain.sh ffprobe=<path> ffmpeg=<path>` (either can be omitted). Kept the existing `otool -L | grep -vE '^(/usr/lib/|/System/)'` reject-on-non-system check, now applied per-binary. Idempotent self-copy guard preserved.
- [x] **P2.3** `cp /tmp/p2-bundling/ffmpeg → 01_Project/AvidMXFPeek/Resources/ffmpeg` (chmod +x).
- [x] **P2.4** pbxproj line 263 shell-script build phase: appended second `ditto` for ffmpeg alongside ffprobe. Comment updated: `# Copy bundled toolchain: ffprobe (MXF read-path) + ffmpeg (HLS preview transcoder; see docs/plans/2026-04-22-player-hls.md)`.
- [x] **P2.5** `sign-bundled-binaries.sh` refactored to loop over `BINARIES=(ffprobe ffmpeg)`. Same cert SHA-1 `2D26CB12...`, same entitlements plist (unsigned-memory + disable-library-validation). Verified: `flags=0x10000(runtime) team=FDMSRXXN73` for both.
- [x] **P2.6** `BundledTool` enum: added `case ffmpeg` with `displayName = "FFmpeg"`. Doc comment updated to describe both binaries and their roles.
- [x] **P2.7** Clean build succeeded. Final `.app` size = **133 MB** (projected 134 — spot on). Both binaries present in `.app/Contents/Resources/`, both codesigned with hardened runtime, both run from the bundle and report `ffmpeg version 8.1-https://www.martin-riedl.de`. Launch smoke test passed (app opens, clean exit).

### Wave P3 — HTTP server (`PreviewHTTPServer`) ✅ **COMPLETE 2026-04-22**

- [x] **P3.1** `01_Project/AvidMXFPeek/Services/PreviewHTTPServer.swift` — ~270 LOC actor wrapping NWListener. Loopback-only (`requiredLocalEndpoint = .hostPort(.ipv4(.loopback), .any)`), dynamic port, GET-only. HTTP/1.1 header parser (case-insensitive, lowercases header names; 16 KB cap), path resolution defends against `..` traversal via `standardizedFileURL.hasPrefix(rootDir + "/")`. MIME dispatch: `.m3u8 → application/vnd.apple.mpegurl`, `.m4s/.mp4 → video/mp4`, `.ts → video/mp2t`. **Range support** (required per §10.2): single-range `bytes=START-END` / `bytes=START-` → `206 Partial Content` + `Content-Range`, multi-range (comma-separated) → `501`, out-of-bounds → `416` with `Content-Range: bytes */TOTAL`. All responses include `Accept-Ranges: bytes`, `Cache-Control: no-cache`, `Connection: close`. Connection handling is `nonisolated static` — many concurrent connections don't serialize through the actor; only state transitions (listener ready/failed, baseURL) touch actor-isolated state.
- [x] **P3.2** `01_Project/AvidMXFPeekTests/PreviewHTTPServerTests.swift` — 11 tests, all green (0.23 s wall time total):
  - `startReturnsLoopbackBaseURL` — host=127.0.0.1, scheme=http, port>0
  - `startThrowsOnMissingRoot` — invalid directory rejected at init
  - `startIsIdempotent` — double-start returns cached URL
  - `servesPlaylistWithHLSMimeType` — Content-Type + body round-trip
  - `servesFMP4WithVideoMP4MimeType` — 2 KB binary, byte-exact
  - `missingFileReturns404`
  - `pathTraversalReturns403` — `/..%2Fsecrets.txt` blocked
  - `rangeRequestReturns206WithContentRange` — `bytes=100-199` → slice matches, Content-Range + Content-Length correct
  - `openEndedRangeClampsToFileEnd` — `bytes=900-` → 900-999/1000
  - `outOfBoundsRangeReturns416` — `bytes=500-600` on 100-byte file → `Content-Range: bytes */100`
  - `multiRangeReturns501` — `bytes=0-99,200-299`
  - `concurrentGETsDoNotDeadlock` — 10 parallel GETs via `withThrowingTaskGroup`, all 200, 0.030 s total
  - `stopAndRestartReassignsPort` — verifies lifecycle loop
- [x] **P3.3** Lifecycle contract in place via actor API: `init(rootDir:) throws`, `func start() async throws -> URL` (idempotent), `func stop()`, `var baseURL: URL?`. The caller-side wiring (one instance owned by `PlaybackCoordinator`, lazy-started on first clip selection, stopped at app quit) lands in Wave P6.

**pbxproj:** 4 edits to register `Services/PreviewHTTPServer.swift` (legacy PBXGroup pattern — PBXBuildFile `A0100002C` + PBXFileReference `A0200002C` + Services group children + PBXSourcesBuildPhase files). Test file auto-picked-up via test target's synchronized folder.

### Wave P4 — Transcoder (`PreviewTranscoder`) ✅ **COMPLETE 2026-04-22**

- [x] **P4.1** `Services/PreviewTranscoder.swift` (~260 LOC) — struct with a single `transcode(videoStemURL:audioPairs:durationSeconds:outputDir:) -> AsyncStream<TranscodeEvent>` entry point. Events: `.started(pid:)` / `.firstSegmentReady` / `.progress(fraction:)` / `.completed` / `.failed(reason:)`. Raw `Process` + two `readabilityHandler`s (stdout for `-progress pipe:1`, stderr accumulated into a lock-protected `StderrBuffer` for `failed()` reason). `continuation.onTermination` runs `process.terminate()` on consumer cancel, and schedules `SIGKILL` via `DispatchQueue.global.asyncAfter(2.0)` if the process is still alive after the grace window. FirstSegmentReady via 100 ms poll (per §10.4 correction; the `DispatchSource.makeFileSystemObjectSource` original plan was dropped).
- [x] **P4.2** `Models/AudioPair.swift` (~70 LOC) — `AudioPair.pairsFromClip(_ clip: Clip) -> [AudioPair]`. Sorts audio stems by filename (A01, A02, …), groups two-at-a-time, odd count → mono pair (same URL both channels), video stems filtered by `videoTrackCount > 0`. Label format `"A01_A02"` (underscore, not `+`, for clean use in `-var_stream_map name:…`) or `"A05_mono"`.
- [x] **P4.3** Tests (18 new, all green):
  - `AudioPairTests.swift` (7): `videoOnlyClipProducesNoPairs`, `clipWithNoFilesProducesNoPairs`, `twoAudioStemsProduceOneStereoPair`, `fourAudioStemsProduceTwoPairs`, `oddAudioStemCountProducesFinalMonoPair`, `singleAudioStemBecomesMonoPair`, `audioStemsAreSortedByFilenameBeforePairing`.
  - `PreviewTranscoderTests.swift` (11): `parseOutTime` well-formed + malformed; `buildArgs` video-only / single-pair / multi-pair / mono-pair (verifies `[1:a:0][1:a:0]join` reuses same input); `isFirstSegmentReady` empty / single-rendition-ready / single-partial / multi-rendition-ready / multi-rendition-missing-seg.
  - Rationale for not running real ffmpeg in tests: the process-orchestration surface (cancellation, pipe handlers, termination) depends on timing + signal semantics that are flaky in unit tests. Wave P6 integration tests will exercise it end-to-end against the bundled ffmpeg.

**pbxproj:** 5 edits — 2 `PBXBuildFile`, 2 `PBXFileReference`, plus 2 group-children insertions (Models gains AudioPair, Services gains PreviewTranscoder) and 2 `PBXSourcesBuildPhase` entries. Test files auto-picked-up.

**Full test suite: 63 @Test functions, 0 failures.**

### Wave P5 — Cache (`PreviewCache`)

- [ ] **P5.1** New file `Services/PreviewCache.swift` — actor
  - `func pathIfCached(for clip: Clip) -> URL?` (hash-keyed lookup)
  - `func prepareOutputDir(for clip: Clip) throws -> URL` (creates + returns; touches `.transcode-state`)
  - `func markComplete(for clip: Clip)` (writes state, updates access time)
  - `func evictToFit(budgetBytes: Int64)` — LRU sweep
  - Hash function as described in §2.4
- [ ] **P5.2** Unit tests:
  - Hash identical for identical inputs, different for changed file sizes
  - Eviction: fill cache past budget, call evictToFit, verify oldest entries gone, newest retained
  - Doesn't evict entries in `.transcode-state == "running"`
  - Preflight: if free disk < 1 GB, `prepareOutputDir` throws

### Wave P6 — Coordinator (`PlaybackCoordinator` + `PlaybackState`)

- [ ] **P6.1** New file `Models/PlaybackState.swift` — `@Observable`:
  ```swift
  @Observable final class PlaybackState {
      enum Phase {
          case idle
          case preparing(elapsed: Date, progress: Double?)
          case playing
          case failed(String)
      }
      var phase: Phase = .idle
      var player: AVPlayer?
      var currentClipID: Clip.ID?
      var audioPairs: [AudioPair] = []
      var selectedPair: AudioPair?
      var audibleGroup: AVMediaSelectionGroup?
  }
  ```
- [ ] **P6.2** New file `Services/PlaybackCoordinator.swift`:
  - Observes `ScanModel.selectedClipID`
  - On change: cancel in-flight transcode, look up in cache, spawn transcoder if miss, wire events to `PlaybackState.phase`
  - Pair switch: call `playerItem.select(option, in: audibleGroup)` — no transcode if all pairs already in the HLS output
- [ ] **P6.3** Unit tests (mock cache + mock transcoder):
  - Clip selection transitions phase correctly
  - Rapid selection changes cancel previous transcode
  - Pair change with cache hit doesn't respawn ffmpeg

### Wave P7 — UI (`PlayerView`)

- [ ] **P7.1** New file `Views/PlayerView.swift`:
  - `NSViewRepresentable` wrapping `AVPlayerView` (macOS); pass in `playbackState.player`
  - SwiftUI overlay for preparing/failed states (spinner + elapsed, error + retry)
  - Audio pair `Picker` above the player, disabled when `audioPairs.count < 2`
- [ ] **P7.2** Integrate into `ClipInspectorView`:
  - Top: `PlayerView` (fixed min-height 240)
  - Divider
  - Existing metadata grid below
- [ ] **P7.3** Inspector-toggle still works (hide inspector → stop playback, free resources)
- [ ] **P7.4** Build + launch, test against a YouTube-import clip (e.g. Fookls "Your Time Machine") and a camera-native clip

### Wave P8 — Adversarial + polish

- [ ] **P8.1** Add to `MXFFolderScannerTests` style adversarial tests in new `PlayerPipelineTests.swift`:
  - Clip with 0 audio stems → player shows video silent, picker disabled
  - Clip with odd audio stem count → mono-pair handling
  - Missing ffmpeg at runtime → "Preview unavailable" banner, no crash
  - Disk preflight (<1 GB free) → clear error
  - Rapid clip switching (simulate 5 selection changes in 1s) → final selection wins, no zombie ffmpeg
- [ ] **P8.2** Manual QA against real data: switch between clips of widely different lengths, confirm startup latency target
- [ ] **P8.3** Memory: instrumented run scrubbing a long clip, confirm AVPlayer item / CVPixelBuffer churn stays bounded
- [ ] **P8.4** Cleanup: app quit mid-transcode leaves no zombie ffmpegs (register `atexit` handler or use `Process.interruptionHandler`)

---

## 4. Dependencies / Blockers

| Item | Who resolves | Why it matters |
|------|--------------|----------------|
| ffmpeg 8.1 arm64 static build from martin-riedl.de | User download (or me via curl in Wave P2) | Required bundle addition |
| User go-ahead after spec + plan review | User | Spec status gates `/execute` start |
| A clip with **4+ audio stems** for multi-pair testing | User if available, otherwise manufactured via `ffmpeg -i V01.mxf -i A01.mxf -i A01.mxf -i A02.mxf -i A02.mxf` faking pairs | Wave P1.6 + P8.1 |

---

## 5. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| HLS live-mux with `append_list` writes an incomplete playlist that AVPlayer rejects until endlist | Medium | High (kills the fast-startup promise) | P1.2 + P1.4 validate this first; fallback = poll until playlist has ≥ 1 segment before telling AVPlayer to open |
| `AVMediaSelectionGroup` doesn't cleanly switch among multiple audio-only HLS renditions | Low-Medium | Medium (audio-pair switch needs retranscode instead) | P1.6 validates; fallback = per-pair transcode with cache keyed on pair index |
| AVPlayer caches playlist content during live-mux → doesn't see appended segments | Low-Medium | Medium | HTTP headers: `Cache-Control: no-cache`; on playlist reread, set short `Last-Modified`. AVPlayer has been OK with this pattern historically. |
| H.264 hardware encode artifacts on Avid's non-standard DNxHD progressive output | Low | Low (quality, not correctness) | DNxHR LB fallback if H.264 produces visual glitches |
| Loopback port grab fails in a locked-down enterprise setting | Very low | Low | Unlikely for user's single-user Mac; if it happens, clear error + retry |
| Bundle size hitting 165 MB causes GitHub LFS warnings to multiply | Low | Low (cosmetic) | Already over the 50 MB soft warning with ffprobe; ffmpeg adds another file in the same warning class. Non-blocker. |

---

## 6. File inventory

### New files

```
01_Project/AvidMXFPeek/Services/PreviewHTTPServer.swift      (~200 LOC)
01_Project/AvidMXFPeek/Services/PreviewTranscoder.swift      (~250 LOC)
01_Project/AvidMXFPeek/Services/PreviewCache.swift           (~180 LOC)
01_Project/AvidMXFPeek/Services/PlaybackCoordinator.swift    (~150 LOC)
01_Project/AvidMXFPeek/Models/AudioPair.swift                (~60 LOC)
01_Project/AvidMXFPeek/Models/PlaybackState.swift            (~80 LOC)
01_Project/AvidMXFPeek/Views/PlayerView.swift                (~150 LOC)
01_Project/AvidMXFPeekTests/PreviewHTTPServerTests.swift     (~120 LOC)
01_Project/AvidMXFPeekTests/PreviewTranscoderTests.swift     (~100 LOC)
01_Project/AvidMXFPeekTests/PreviewCacheTests.swift          (~100 LOC)
01_Project/AvidMXFPeekTests/AudioPairTests.swift             (~80 LOC)
01_Project/AvidMXFPeekTests/PlayerPipelineTests.swift        (~150 LOC)
01_Project/AvidMXFPeek/Resources/ffmpeg                      (~90 MB binary)
bundle-toolchain.sh                                          (rename of bundle-ffprobe.sh, ~80 LOC)
```

Total new Swift: ~1,620 LOC + bundled binary.

### Modified files

```
01_Project/AvidMXFPeek/Services/BundledToolResolver.swift    (+5 LOC: .ffmpeg case)
01_Project/AvidMXFPeek/ContentView.swift                     (ClipInspectorView integration, ~20 LOC)
01_Project/AvidMXFPeek.xcodeproj/project.pbxproj             (target bundle Resources entry for ffmpeg)
sign-bundled-binaries.sh                                     (sign ffmpeg alongside ffprobe, +10 LOC)
docs/TASKS.md                                                (move v1.2 backlog → Current Sprint)
docs/specs/player.md                                         (promote Draft → Approved post-P1)
```

### Deleted

```
bundle-ffprobe.sh  (renamed, not deleted — content moves into bundle-toolchain.sh)
```

---

## 7. Operational Learnings

- **Cache budget math was 2× optimistic.** §2.4 said 15 MB/min; real output at 4 Mbps H.264 + 192 kbps AAC = 30 MB/min. 10 GB ceiling → ~33 clip-minutes cached, not 50+. Revise §2.4 before Wave P5 (cache) lands, and/or drop bitrate to 2 Mbps for a quality-vs-capacity trade.
- **`AVPlayerView` floating HUD does not surface `AVMediaSelectionGroup` audio options automatically.** Even with 2 valid audio renditions, no speech-bubble menu appears in the default controls. §P7.1's custom audio-pair Picker is load-bearing, not a nice-to-have.
- **AVPlayer honors `Cache-Control: no-cache` on HLS playlists.** Empirically confirmed: during P1.4 live-mux, AVPlayer re-fetched `playlist.m3u8` repeatedly as it grew. No special header gymnastics needed beyond the single header the P1.3 server already sets.
- **`automaticallyWaitsToMinimizeStalling = false`** is appropriate for our use case — playback starts as soon as `readyToPlay` fires, without AVPlayer waiting for extra buffering. Keep this default in production.
- **ffmpeg tail-of-clip decode warning is benign.** `dnxhd: unknown header 0x00 0x00 0x00 0x00 0x00` on the final ~12 frames of a 21000-frame clip is MXF padding; segments render clean. Don't log-parse for this as a failure indicator.
- **Binary is cleanly static.** `otool -L` on the martin-riedl.de ffmpeg 8.1 arm64 build shows only system frameworks (`/System/Library`, `/usr/lib/libSystem`, `libc++`, `libbz2`, `libiconv`). No `@executable_path/...` dylib paths to rewrite — unlike the old libbmx era. Wave P2 bundling is strictly "copy file + codesign".

## 8. Blocked Tasks

*Populated when tasks block.*

---

## 9. Execution Log

| Wave | Started | Completed | Commits | Notes |
|------|---------|-----------|---------|-------|
| P1 spike | 2026-04-21 evening | 2026-04-21 evening | 92453f6 + 4c2e8f7 (corrections) | All 9 tasks ✓. End-to-end latency 2.5 s (<5 s target). Audio-pair switching verified. Bundle projection 134 MB. Cleared to P2. |
| P2 bundling | 2026-04-22 | 2026-04-22 | df079f7 | Final .app = 133 MB (projection 134 was spot on). bundle-ffprobe.sh → bundle-toolchain.sh (multi-binary). sign-bundled-binaries.sh loops over BINARIES array. pbxproj shell phase appended 2nd `ditto`. BundledTool enum + .ffmpeg. Build + launch smoke-tested. |
| P3 server | 2026-04-22 | 2026-04-22 | 37a7bb5 | PreviewHTTPServer.swift ~270 LOC actor over NWListener, loopback-only, Range support per §10.2 (206/416/501). 11 new tests all green, full suite 45/45. pbxproj 4-edit for main target + auto-pickup in test target. |
| P4 transcoder | 2026-04-22 | 2026-04-22 | (pending Wave P4 commit) | PreviewTranscoder.swift ~260 LOC (Process + AsyncStream + 100 ms poll per §10.4) + AudioPair.swift ~70 LOC. 18 new tests (buildArgs shape for 4 scenarios, isFirstSegmentReady for 5, parseOutTime, pair grouping for 7 cases). Full suite 63/63. |
| P5 cache | | | | |
| P4 transcoder | | | | |
| P5 cache | | | | |
| P6 coordinator | | | | |
| P7 UI | | | | |
| P8 adversarial | | | | |

---

## 10. Post-P1 plan corrections (2026-04-21 evening)

Research after the spike (Apple docs MCP + existing-codebase audit + web search for HLS/AVPlayer production gotchas) surfaced five plan drifts that require correction **before Wave P2 begins**. None of these invalidate the design; they correct specific implementation details.

### 10.1 §P2.3 / §P2.4 — ffmpeg bundling is a one-line shell-phase edit

**What the plan assumed:** pbxproj uses `PBXFileSystemSynchronizedRootGroup` for main target, so dropping `Resources/ffmpeg` auto-includes it.

**Reality:** pbxproj line 247 has a **Shell Script Build Phase** that runs:
```bash
ditto "${SRCROOT}/AvidMXFPeek/Resources/ffprobe" \
      "${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/ffprobe"
```
The main target (`A05000003 /* Resources */` + `23438BF32F067F7400ACE31E /* ShellScript */`) is on the **legacy PBXGroup** pattern. `PBXFileSystemSynchronizedRootGroup` is used **only for the test target**. The binary is copied at build time by the shell-script phase, not by a file reference.

**Revised P2.3–P2.4:**
- [ ] **P2.3** Drop `ffmpeg` binary into `01_Project/AvidMXFPeek/Resources/ffmpeg` (same dir as ffprobe).
- [ ] **P2.4** Edit pbxproj line 263: append a second `ditto` line to the existing `shellScript = "..."` string:
  ```
  shellScript = "  # Copy ffprobe (sole bundled read-path binary post 2026-04-20-C pivot)
    ditto \"${SRCROOT}/AvidMXFPeek/Resources/ffprobe\" \"${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/ffprobe\"
    ditto \"${SRCROOT}/AvidMXFPeek/Resources/ffmpeg\" \"${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/ffmpeg\"
  ";
  ```
  Also update the block's comment from "Copy ffprobe (sole bundled read-path binary...)" to "Copy ffprobe + ffmpeg (read-path + preview-transcode binaries; see 2026-04-22 player plan)".

No `PBXFileReference` / `PBXBuildFile` entries needed. Build-phase `ditto` copies at build time, hardened runtime signing handled by `sign-bundled-binaries.sh`.

### 10.2 §2.3 — HTTP Range support is NOT optional

**What the plan assumed:** `Range:` support is a nice-to-have, skip if P1.7 doesn't indicate AVPlayer uses them.

**Reality:** AVPlayer uses byte-range requests for **duration calculation** during HLS init, independently of segment fetching. The P1 server omitted Range support and P1.4 worked, but this is fragile — RFC 7233 specifies that servers returning `Accept-Ranges: bytes` MUST respond with `206 Partial Content` and `Content-Range: bytes START-END/TOTAL` when the request includes a valid `Range: bytes=START-END`. Unsupported ranges should return `501`.

**Revised P3.1:** `PreviewHTTPServer.swift` **must** parse `Range:` headers and emit 206 responses. ~30 LOC addition:

```swift
if let rangeHeader = request.headers["Range"], rangeHeader.hasPrefix("bytes=") {
    let spec = rangeHeader.dropFirst("bytes=".count)
    // Parse "START-END" or "START-" forms
    let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard let start = Int(parts[0]) else { /* 400 */ }
    let end = parts.count == 2 ? Int(parts[1]) ?? (fileSize - 1) : fileSize - 1
    let slice = body.subdata(in: start..<min(end + 1, fileSize))
    reply.append(header: "HTTP/1.1 206 Partial Content",
                 contentRange: "bytes \(start)-\(end)/\(fileSize)",
                 contentLength: slice.count)
    reply.append(slice)
}
```

Single-range form only (no multipart/byteranges) — AVPlayer doesn't issue multi-range requests for HLS fMP4. Multi-range returns 501.

### 10.3 §2.4 — Cache budget: 30 MB/min, not 15

**Corrected arithmetic:** 4 Mbps video + 192 kbps audio ≈ 525 kB/s ≈ 30 MB/min. Already noted in §7; making it §2.4 canonical. A 10 GB cache holds ~33 clip-minutes, not 50+.

**Recommendation for Wave P5 design:** either (a) raise default cache budget to 20 GB, (b) drop video bitrate to 2 Mbps (quality vs capacity trade-off — 2 Mbps H.264 of transcode-preview quality is still fine for editorial review), or (c) keep 10 GB and make budget user-configurable. Pick at P5 design time.

### 10.4 §P4.1 — firstSegmentReady: prefer polling over DispatchSource

**What the plan assumed:** `DispatchSource.makeFileSystemObjectSource` watches the output directory, fires when `playlist.m3u8` + `seg_000.m4s` both exist.

**Reality:** `DispatchSource.makeFileSystemObjectSource(fileDescriptor:)` monitors a **single fd** with an event mask (`.write`, `.rename`, `.delete`, etc.). For watching a *directory* for new files appearing, you'd open the directory fd and listen for `.write` — but this fires on the directory's mtime change (which happens when *any* entry is added/removed), requiring you to re-enumerate the dir contents every callback. Race-prone and overkill for our case.

**Revised P4.1:** replace with a simple 100 ms polling loop inside the transcoder task:
```swift
while !cancelled {
    let playlist = outputDir.appendingPathComponent("playlist.m3u8")
    let firstSeg = outputDir.appendingPathComponent("seg_000.m4s")
    if FileManager.default.fileExists(atPath: playlist.path)
       && FileManager.default.fileExists(atPath: firstSeg.path) {
        continuation.yield(.firstSegmentReady)
        break
    }
    try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
}
```
Fires within ~100 ms of both files existing (empirically P1.1 showed first segment in 0.76 s; polling adds <15 % latency to that). No fd lifecycle management, no race on dir re-enumeration. If we later need progress-granular signals (new-segment-per-4s), *then* consider DispatchSource / FSEvents.

### 10.5 §5 Risks — add first-play seek-past-transcode-horizon

New row:

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| On first-play of a clip, user scrubs forward past the not-yet-transcoded horizon → AVPlayer stalls or refuses | Medium | Low-Medium (UX surprise once per clip) | (a) After cache hit on subsequent plays, ENDLIST is present and seek is free everywhere. (b) For long clips, consider hinting the user via a subtle indicator on the scrubber showing "encoded to here". (c) Worst case: AVPlayer stalls silently until the segment appears — acceptable; not a crash. Verify with P8.2 manual QA on a 30-min clip. |

### 10.6 Tool-inventory reminder for Wave P2

Current `bundle-ffprobe.sh` has a clean `otool -L | grep -vE '^(/usr/lib/|/System/)'` non-system-dylib check — **lift this verbatim** into `bundle-toolchain.sh`, applied per-binary. `sign-bundled-binaries.sh` uses Apple Development cert SHA-1 `2D26CB1211F32FD4E3C6EF413EC1EDD6F30631AA` and writes an inline entitlements plist via heredoc; ffmpeg gets the **same** entitlements (`com.apple.security.cs.allow-unsigned-executable-memory` + `disable-library-validation`) as ffprobe.

---

*Delete when v1.2 ships. Archive to `sessions/` for reference. Plan document for future: `docs/plans/2026-05-NN-player-custom-engine.md` (Option 5, post-v1.2 ambition).*
