# Swift/SwiftUI Patterns Cookbook

**Extracted from working production code across 15+ projects.**
**Last updated: 2026-04-21 (added #45 macos-firmlink-canonical-path; #44 inherited-project-dead-code-sweep; #43 subprocess-fire-and-collect)**

---

> **MANDATORY STANDARD — READ FIRST**
>
> Every macOS app MUST use the **App Shell Standard** below. This means:
> - `HSplitView` for panes (NOT `NavigationSplitView` — no Tahoe frosted sidebars)
> - `FCPToolbarButtonStyle` for toolbar buttons (NOT default round/capsule buttons)
> - `.windowStyle(.hiddenTitleBar)` + `.preferredColorScheme(.dark)` + `.toolbarRole(.editor)`
> - Custom dark `Theme` struct for consistent colors
>
> **Existing apps not using this pattern should be migrated.** When starting work on
> any macOS app, check whether it follows the App Shell Standard. If it doesn't,
> migrating to this standard is a prerequisite before adding new features.
>
> Reference implementation: `1-macOS/Penumbra/` (pre-Tahoe SDK toolbar)
> Titlebar injection reference: `1-macOS/VAM/` (macOS 26 SDK — no system chrome)

---

## Patterns Index

Each pattern lives in `docs/cookbook/`. Read the relevant file when a pattern is needed.

| # | File | What's Inside |
|---|------|---------------|
| 0 | [00-app-shell.md](docs/cookbook/00-app-shell.md) | **MANDATORY** — Entry point, Theme, FCPToolbarButtonStyle, HSplitView panes, migration checklist |
| 1 | [01-window-layouts.md](docs/cookbook/01-window-layouts.md) | NavigationSplitView, HSplitView variants, multi-window, autosave dividers, NSTableView |
| 2 | [02-layout-templates.md](docs/cookbook/02-layout-templates.md) | 5 archetypes: Browser, Editor, Organizer, Dual Viewer, Workspace |
| 3 | [03-appkit-controls.md](docs/cookbook/03-appkit-controls.md) | NSButton, NSCheckbox, NSPopUpButton, NSSegmentedControl, NSSlider, NSTextField wrappers |
| 4 | [04-swiftui-performance.md](docs/cookbook/04-swiftui-performance.md) | Diffing checkpoints, @ViewBuilder anti-pattern, .equatable(), image cache flash fix |
| 5 | [05-export-file-dialogs.md](docs/cookbook/05-export-file-dialogs.md) | NSSavePanel, NSOpenPanel, async panels, progress tracking, security-scoped bookmarks, .fileImporter |
| 6 | [06-app-lifecycle.md](docs/cookbook/06-app-lifecycle.md) | @main entry, .task init order, scenePhase, Manager.configure(), FolderManager |
| 7 | [07-timecode-typography.md](docs/cookbook/07-timecode-typography.md) | SF Pro .monospacedDigit() for timecode displays, weight hierarchy |
| 8 | [08-keyboard-shortcuts.md](docs/cookbook/08-keyboard-shortcuts.md) | 4 tiers: SwiftUI Commands → .onKeyPress → NSEvent monitor → custom manager |
| 9 | [09-context-menus.md](docs/cookbook/09-context-menus.md) | Basic, conditional, extracted @ViewBuilder, NSMenuDelegate for NSTableView |
| 10 | [10-selection-models.md](docs/cookbook/10-selection-models.md) | Single, multi Set\<ID\>, grid, NSTableView sync, cross-pane, two-level |
| 11 | [11-drag-drop.md](docs/cookbook/11-drag-drop.md) | .onDrop, typed handler, concurrent TaskGroup, internal reorder, NSTableView, NSView |
| 12 | [12-activity-progress.md](docs/cookbook/12-activity-progress.md) | Status bar, inline progress, determinate+cancel, multi-level, metrics panel, floating, phases |
| 13 | [13-workspace-switching.md](docs/cookbook/13-workspace-switching.md) | View mode toggle, tool picker, sidebar-driven, @AppStorage persist, nested sub-modes |
| 14 | [14-subprocess-url.md](docs/cookbook/14-subprocess-url.md) | URL.path() pitfall, security-scoped access across async pipelines |
| 15 | [15-native-video-analysis.md](docs/cookbook/15-native-video-analysis.md) | Shot/scene detection (Y-plane histogram), motion scoring (frame differencing) |
| 16 | [16-sparkle-auto-updates.md](docs/cookbook/16-sparkle-auto-updates.md) | Integration checklist, INFOPLIST_KEY_ gotcha, empty appcast fix, minimal updater |
| 17 | [17-thread-safe-rendering.md](docs/cookbook/17-thread-safe-rendering.md) | NSBitmapImageRep for TaskGroup offscreen rendering |
| 18 | [18-pipeline-extraction.md](docs/cookbook/18-pipeline-extraction.md) | Shared processing logic, caller-owned I/O |
| 19 | [19-swift6-concurrency.md](docs/cookbook/19-swift6-concurrency.md) | @MainActor + @Observable — enforce main-thread mutation at class level |
| 20 | [20-actor-reentrancy.md](docs/cookbook/20-actor-reentrancy.md) | When TOCTOU is NOT possible — synchronous sequences can't race |
| 21 | [21-anti-patterns.md](docs/cookbook/21-anti-patterns.md) | Common mistakes to avoid |
| 22 | [22-debounced-cifilter.md](docs/cookbook/22-debounced-cifilter.md) | Live filter preview with SwiftUI fallback cache |
| 23 | [23-z-order-overlay.md](docs/cookbook/23-z-order-overlay.md) | Out-of-bounds visual feedback without badges |
| 24 | [24-web-dev-patterns.md](docs/cookbook/24-web-dev-patterns.md) | Jinja2 data injection, ES module DI, shared state module |
| 25 | [25-extension-file-splitting.md](docs/cookbook/25-extension-file-splitting.md) | Split large files via extensions, access level fixes, strategy by file type |
| 26 | [26-launchd-node-service.md](docs/cookbook/26-launchd-node-service.md) | KeepAlive server, scheduled tasks, install/uninstall, Apple Silicon PATH gotcha |
| 27 | [27-timelineview-elapsed.md](docs/cookbook/27-timelineview-elapsed.md) | TimelineView(.periodic) for elapsed/remaining readouts, replaces Timer + objectWillChange |
| 28 | [28-commandgroup-observation.md](docs/cookbook/28-commandgroup-observation.md) | Commands struct with @ObservedObject — makes menu items update from @Published state |
| 29 | [29-disk-space-preflight.md](docs/cookbook/29-disk-space-preflight.md) | URLResourceKey volume APIs, preflight check, same-volume detection, named-volume errors |
| 30 | [30-volume-custom-icons.md](docs/cookbook/30-volume-custom-icons.md) | **Two-step write** (`.VolumeIcon.icns` + `com.apple.FinderInfo` xattr + `utimes`) because `NSWorkspace.setIcon` is broken on volume roots since macOS 13.1 |
| 31 | [31-volume-enumeration.md](docs/cookbook/31-volume-enumeration.md) | "External drive" heuristic — why `volumeIsRemovableKey` is misleading; correct filter is `!isInternal && !isRootFileSystem && !isLikelyDiskImage` |
| 32 | [32-nsworkspace-asyncstream.md](docs/cookbook/32-nsworkspace-asyncstream.md) | Bridge `NSWorkspace` mount/unmount notifications to `AsyncStream<MountEvent>` inside an actor; observer ownership + termination cleanup |
| 33 | [33-managed-developer-id.md](docs/cookbook/33-managed-developer-id.md) | Xcode Archive → Direct Distribution with a server-side managed Developer ID cert; CLI `notarytool` pipeline as an appendix |
| 34 | [34-xcodeproj-clone-rename.md](docs/cookbook/34-xcodeproj-clone-rename.md) | Clone an existing `.xcodeproj` when a new app needs the same toolchain bundling / entitlements / build phases — `cp -R` + sed recipe with macOS sed, display-name-with-spaces, and xcuserdata gotchas |
| 35 | [35-asyncstream-bounded-fanout.md](docs/cookbook/35-asyncstream-bounded-fanout.md) | `withTaskGroup` drain-and-refill pattern for streaming results from thousands of async operations with a bounded concurrency cap; why the naive `for url in files { group.addTask }` version is wrong |
| 36 | [36-fast-preview-heavy-commit.md](docs/cookbook/36-fast-preview-heavy-commit.md) | Split render API into `preview(…) throws -> NSImage` (in-memory, sync, ~15 ms) vs `render(…) async throws -> Data` (full pipeline with subprocess, ~300 ms). Synchronous `.onChange` wiring for live slider feedback; no Task/cancel gymnastics. |
| 37 | [37-effective-source-fallback.md](docs/cookbook/37-effective-source-fallback.md) | `pending ?? cached` editor binding so settings can be tweaked on a previously-saved asset without re-importing. Includes dirty-detection for the commit gate and self-healing for disappeared cache files. |
| 38 | [38-destructive-copy-guard.md](docs/cookbook/38-destructive-copy-guard.md) | `sourceURL.standardizedFileURL == destURL.standardizedFileURL` early-return before `removeItem → copyItem` — avoids deleting the file you're about to read when `src == dest`. |
| 39 | [39-design-tokens.md](docs/cookbook/39-design-tokens.md) | **App-wide visual tokens** — typography scale (semantic, modular ratio), 8pt spacing grid with internal≤external rule, SF Symbol weight/scale conventions, corner radii, CSS `clamp()` fluid translation for web projects |
| 40 | [40-spaces-plist-backend.md](docs/cookbook/40-spaces-plist-backend.md) | **Public Spaces backend via `com.apple.spaces`** — parse the documented-format-undocumented-semantics plist to get real Space UUIDs + current-Space per monitor without private CGS SPI. Handles `spans-displays=0`/`1` modes correctly. Includes Swift 6 reader, AsyncStream wiring with 120ms settle delay, v1→v2 migration strategy, and known limits |
| 41 | [41-web-hero-floating-icons.md](docs/cookbook/41-web-hero-floating-icons.md) | **Web landing-hero composition** — fill empty hero space with the product's own app icons scattered at gentle angles around the centered headline. `.hero-stage` wrapper + 3× `.float-icon` (absolute, rotated, drop-shadow stacks, staggered drift animations 7s/8s/9s, hidden under 820px). Why `filter: drop-shadow` not `box-shadow`; why coprime animation periods; accessibility (`alt=""` + `aria-hidden`). |
| 42 | [42-web-native-dialog-lightbox.md](docs/cookbook/42-web-native-dialog-lightbox.md) | **Web image lightbox via native `<dialog>`** — click any thumbnail to enlarge it in a fullscreen overlay (GitHub-style). Single shared `<dialog>` per page, JS swaps `img.src`. Free focus trap + ESC-close + `::backdrop` pseudo-element; backdrop-filter blur; click-anywhere-to-close. `.shot` a11y attrs (`tabindex`/`role`/`aria-label`/keydown) added at runtime, not in HTML. Variations for next/prev nav, captions inside dialog, pinch-zoom alternatives. |
| 43 | [43-subprocess-fire-and-collect.md](docs/cookbook/43-subprocess-fire-and-collect.md) | **Short-lived subprocess → single stdout blob** — `waitUntilExit() + readDataToEndOfFile()` inside `Task.detached` instead of `readabilityHandler`. Avoids the tail-byte race at child-termination, kills 30 lines of handler-cleanup boilerplate, same performance for bounded outputs. Right for `ffprobe`/`exiftool`/`shasum`/`git rev-parse`; wrong for long-running processes with streamed progress (use `readabilityHandler` there). Covers stderr always-drain rule, `Task.detached` rationale, per-call cancellation trade-off. |
| 44 | [44-inherited-project-dead-code-sweep.md](docs/cookbook/44-inherited-project-dead-code-sweep.md) | **Bulk-remove dead Swift code from forked Xcode project** — `sed -i '' "/filename.swift/d" project.pbxproj` per dead file removes all 4 pbxproj references at once (works because Xcode-generated pbxproj puts filename in every `/* comment */`). Combine with disk `rm`, in-place trim for partially-dead files via `sed -n "${N},\$p"`, safety-net unit tests. AvidMXFPeek sweep: 30 files deleted, 5 files trimmed, ~4500 → 1507 LOC in ~20 min. Gotchas: escape regex metachars in filenames, close Xcode first, watch for prefix-name collisions, PBXFileSystemSynchronizedRootGroup exempts contents from pbxproj file refs. |
| 45 | [45-macos-firmlink-canonical-path.md](docs/cookbook/45-macos-firmlink-canonical-path.md) | **macOS firmlink / `/var` vs `/private/var` URL-equality gotcha** — `URL.resolvingSymlinksInPath()` is a **no-op on APFS firmlinks** (Catalina+), but `FileManager`'s enumerator returns firmlink-resolved URLs. Result: hand-built `/var/folders/...` URLs fail `==` against enumerator-returned `/private/var/folders/...` URLs. Fix: `URLResourceValues.canonicalPath` (requires path to exist — canonicalize the parent, then `appendingPathComponent` the leaf). Covers when this bites (test fixtures, Sets of URLs, path-based dedup), what doesn't work (resolvingSymlinksInPath/standardized/NSString variants), diagnostic approach via xcresult assertion diffs. |
| 126 | [126-closure-struct-dependency-injection.md](cookbook/126-closure-struct-dependency-injection.md) | **Closure-struct dependency injection — `.live`/`.inert` for system side-effects** — every side-effecting syscall (`open`, `reveal`, `moveToTrash`, `fullDiskAccessStatus`, `presentOpenPanel`, volume capacity) is a **closure field on a plain struct**, not a singleton method and not behind a protocol; the struct ships `.live` (wires real `SystemIntegration` calls) and `.inert` (every closure a safe no-op / fixed return). The ViewModel takes one in `init(system: AppSystemActions = .live)` and never touches `NSWorkspace`/`FileManager`/`NSOpenPanel`/TCC directly. **Why a struct of closures, not a protocol:** protocol-witness without the boilerplate — no live class + mock class per test; a test mutates the **single field** it cares about (`var sys = .inert; sys.moveToTrash = { _ in throw … }`), a surgical swap a class mock can't do. **`.inert` does double duty as the SwiftUI `#Preview` environment** — previews built with `.inert` never fire `NSOpenPanel`, open System Settings, or trash files (name it `.inert`/`.disabled`, not `.mock`). For blocking work add an **optional** async sibling + capability flag (`asyncFullDiskAccessStatus: (@Sendable () async -> …)?` wrapping `Task.detached(.utility)`) so callers hop off-main without forcing everyone async; `.inert` leaves it `nil` → previews stay sync. **Altitude:** overkill for a ~200-line menu-bar utility with no ViewModel — earns its keep once there's logic worth testing between UI and syscall. Source: external study, github.com/colinvkim/Radix (`AppSystemActions.swift`). Pairs with **#00** (app shell), #06 (where `.live` is injected at `@main`), #19 (`@MainActor` struct), #127 (testable destructive-op branches). |
| 127 | [127-toctou-identity-verify-before-destructive-op.md](cookbook/127-toctou-identity-verify-before-destructive-op.md) | **Verify file identity before a destructive op — close the scan→act TOCTOU gap** — a scan/listing is a *snapshot*; the user acts on a row seconds/minutes later, by which time the path may resolve to a **different file** (replaced, rotated, moved-and-recreated, symlink retargeted) → the wrong file gets trashed. A path string carries no identity. **Fix:** capture `(st_dev, st_ino)` via **`lstat`** (not `stat` — identify the symlink, don't chase it) **at scan time**, store it on the node, re-check **immediately before** the op; classify the outcome (`matches`/`mismatch`/`missingNow`/`unverifiable`) into distinct actions — never a lossy bool (same discipline as #61). `mismatch` → refuse; `missingNow` (ENOENT/ENOTDIR) → no-op, not an error. **Two layered guardrails, order matters:** static **block-list first** (`TrashSafetyPolicy` refuses `/`, `/System`, `~/Library`, volume roots — catches fat-fingered targets), **identity check second** (refuses stale references to safe targets). `fileResourceIdentifierKey` is the inode-reuse fallback. **Skip when** you stat-and-act in the same synchronous breath with no user interaction/`await` between. Source: external study, github.com/colinvkim/Radix (`verifyTrashIdentity`). Destructive-op sibling of **#38** (copy guard) and **#52** (path≠file identity); classification discipline from **#61**. |

---

## Quick Reference Table

| Pattern | Source Project | Use Case |
|---------|---------------|----------|
| **App Shell Standard** | **Penumbra** | **MANDATORY — base for all macOS apps** |
| FCPToolbarButtonStyle | Penumbra | Flat 4px toolbar buttons, replaces round |
| PaneToggleButton | Penumbra | Toolbar toggle with FCPToolbarButtonStyle |
| Theme struct | Penumbra | Dark color palette (0.10/0.15 grays) |
| .hiddenTitleBar + .dark | Penumbra | No system chrome, forced dark mode |
| .toolbarRole(.editor) | Penumbra | Editor toolbar, no nav chrome |
| HSplitView + @AppStorage | Penumbra | Togglable panes with persisted visibility |
| InfoStripView | Penumbra | Contextual bar below toolbar |
| Separate view structs | swiftdifferently.com | Performance (diffing checkpoints) |
| .equatable() modifier | swiftdifferently.com | Views with closures |
| debugRender() extension | swiftdifferently.com | Visualize re-renders |
| NavigationSplitView | Directions | Sidebar navigation |
| HSplitView (simple) | TextScanner | 2-pane layouts |
| HSplitView (complex) | Phosphor | Preview + timeline |
| HSplitView (3-section) | AppUpdater | Sidebar with header/footer |
| Multi-window + Menu Bar | WindowMind | Background utilities |
| Autosave dividers | Penumbra, VCR | Remember pane sizes |
| NSTableView in SwiftUI | VCR | Column headers, cell reuse, native table |
| AppKitButton | Convention | Native NSButton, replaces SwiftUI Button |
| AppKitCheckbox | Convention | Native checkbox toggle |
| AppKitPopup | Convention | Native NSPopUpButton dropdown |
| AppKitSegmented | Convention | Native segmented control |
| AppKitSlider | Convention | Native NSSlider |
| AppKitTextField | Convention | Native NSTextField input |
| AppKitToolbarButtonStyle | Penumbra | Native look in SwiftUI .toolbar |
| NSSavePanel + progress | Phosphor | File export |
| NSOpenPanel (folder) | Directions | Folder selection |
| Security-scoped bookmarks | Directions | Persistent folder access |
| .fileImporter + drag/drop | CropBatch | Image picking |
| @main + .task init | MusicClient | Service initialization |
| Scene phase handling | Group Alarms | iOS lifecycle |
| Manager.configure() | MusicClient | Dependency injection |
| FolderManager | MusicServer | Bookmark restoration |
| **Layout Template A: Browser** | **FCP, Penumbra** | **Sidebar + grid + inspector** |
| **Layout Template B: Editor** | **FCP, Phosphor** | **Viewer + timeline + sidebar** |
| **Layout Template C: Organizer** | **AppUpdater** | **Source list + full detail** |
| **Layout Template D: Dual Viewer** | **FCP compare** | **Side-by-side / overlay / wipe** |
| **Layout Template E: Workspace** | **FCP tabs** | **Tab-switched distinct layouts** |
| KB Tier 1: SwiftUI Commands | VideoScout, Penumbra | Menu-bar shortcuts (Cmd+key) |
| KB Tier 2: .onKeyPress | QuickMotion, VideoScout | View-level JKL, arrows, space |
| KB Tier 3: NSEvent local monitor | Penumbra, VideoWallpaper | App-wide single-key, consume events |
| KB Tier 4: KeyboardShortcutManager | Penumbra | User-customizable, recordable |
| Context menu: basic | ClipSmart | Simple action list on rows |
| Context menu: conditional | VAM | State-driven items |
| Context menu: extracted + submenus | VideoWallpaper, FileManagement | Reusable, nested menus |
| Context menu: NSMenuDelegate | VCR | NSTableView row menus |
| Selection: single `@Binding` | VideoScout | `List(selection:)` + `.tag()` |
| Selection: multi `Set<ID>` | Penumbra | `Table(selection:)`, batch ops |
| Selection: grid + keyboard nav | VideoScout | `LazyVGrid` + arrow keys |
| Selection: NSTableView sync | VCR | `isUpdatingSelection` loop guard |
| Selection: cross-pane observable | Penumbra | `@Observable` shared model |
| Selection: two-level | VAM | Sidebar category + item binding |
| Drop: basic `.onDrop` | CropBatch | File drop zone + highlight |
| Drop: typed handler utility | QuickMotion | Reusable `VideoDropHandler` |
| Drop: concurrent TaskGroup | Penumbra | Bulk multi-file import |
| Drop: internal reordering | Phosphor | `.draggable` + `.dropDestination` |
| Drop: NSTableView | VCR | `registerForDraggedTypes` + delegate |
| Drop: AppKit NSView subclass | TimeCodeEditor | `NSDraggingDestination` override |
| Progress: status bar | VCR | `.safeAreaInset` bottom bar |
| Progress: inline in bar | Penumbra, VAM | Spinner + text when busy |
| Progress: determinate + cancel | Phosphor, CutSnaps | Export bar + % + cancel |
| Progress: multi-level | VideoScout | Overall + per-item bars |
| Progress: metrics panel | P2toMXF | Elapsed / ETA / speed chips |
| Progress: floating overlay | VideoScout | Slide-up `.bottomTrailing` |
| Progress: phase indicator | VOLTLAS, VCR | Color-coded stage icons |
| Progress: footer swap | P2toMXF | Normal actions → progress+stop |
| Workspace: view mode toggle | Penumbra | Grid/list/single via toolbar |
| Workspace: tool mode picker | CropBatch | `.segmented` picker, controls swap |
| Workspace: sidebar-driven | VOLTLAS | `@ViewBuilder switch` on enum |
| Workspace: @AppStorage persist | VideoScout | Mode survives relaunch |
| Workspace: nested sub-modes | VOLTLAS | Outer phase + inner variant |
| TC font: SF Pro .monospacedDigit() | Penumbra | Timecode without slashed zeros (FCP-style) |
| Jinja2 data injection | PDF2Calendar | Server→client data passing |
| ES Module DI | PDF2Calendar | Avoid circular imports in JS modules |
| Shared State Module | PDF2Calendar | Centralized state for vanilla JS apps |
| launchd KeepAlive server | X-STATUS | Node.js server auto-start + auto-restart |
| launchd scheduled task | X-STATUS | Daily data collection (cron replacement) |
| Install/uninstall scripts | X-STATUS | Idempotent launchd agent management |
| **Volume custom icons (two-step write)** | **Sigil** | **`.VolumeIcon.icns` + FinderInfo xattr** |
| **VolumeEnumerator + external heuristic** | **Sigil** | **`!isInternal && !DMG` filter** |
| **NSWorkspace → AsyncStream bridge** | **Sigil** | **Mount/unmount events via structured concurrency** |
| **Managed Developer ID GUI workflow** | **Sigil** | **Archive → Direct Distribution, no local cert** |
