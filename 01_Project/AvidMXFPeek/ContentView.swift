import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    let model: ScanModel
    let playbackState: PlaybackState
    let coordinator: PlaybackCoordinator?

    @AppStorage("showSidebar") private var showSidebar: Bool = true
    @AppStorage("showInspector") private var showInspector: Bool = false

    @State private var showFolderImporter = false

    var body: some View {
        @Bindable var model = model
        HSplitView {
            if showSidebar {
                SidebarPlaceholder()
                    .frame(minWidth: 220, idealWidth: 300, maxWidth: 500)
            }
            ScanMainView(model: model, selectedClipID: $model.selectedClipID)
                .frame(minWidth: 500)
            if showInspector {
                ClipInspectorView(
                    model: model,
                    selectedClipID: model.selectedClipID,
                    playbackState: playbackState,
                    onPairSelected: { pair in coordinator?.selectPair(pair) }
                )
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 500)
            }
        }
        .onChange(of: showInspector) { _, isShown in
            if !isShown {
                // Inspector hidden → stop playback, free AVPlayer / transcoder / server resources.
                // Clearing selection via the coordinator's .idle path is cleaner than calling stop():
                // selection=nil flows through handleSelectionChange which cancels the prep task AND
                // resets playbackState. coordinator.stop() is reserved for full shutdown.
                model.selectedClipID = nil
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                toolbarButton(icon: "folder.badge.plus", help: "Open MXF Folder") {
                    showFolderImporter = true
                }
                toolbarButton(
                    icon: "arrow.clockwise",
                    help: "Rescan",
                    enabled: model.currentFolder != nil
                ) { rescan() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarButton(
                    icon: "tablecells",
                    help: "Export CSV",
                    enabled: !model.clips.isEmpty
                ) { exportCSV() }
                toolbarButton(
                    icon: "curlybraces",
                    help: "Export JSON",
                    enabled: !model.clips.isEmpty
                ) { exportJSON() }
                PaneToggleButton(isOn: $showSidebar, iconName: "sidebar.leading", help: "Sidebar")
                PaneToggleButton(isOn: $showInspector, iconName: "sidebar.trailing", help: "Inspector")
            }
        }
        .toolbarRole(.editor)
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderPick
        )
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
            showFolderImporter = true
        }
    }

    // MARK: - Toolbar helper

    @ViewBuilder
    private func toolbarButton(
        icon: String, help: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        }
        .help(help)
        .buttonStyle(FCPToolbarButtonStyle(isOn: .constant(false)))
        .disabled(!enabled)
    }

    // MARK: - Actions (Wave 4.3)

    private func handleFolderPick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let folder = urls.first else { return }
            // Sandbox is OFF for this app (bundled toolchain); startAccessing...
            // is a no-op today but harmless and future-proof if sandboxing is
            // ever re-enabled. No matching stop — scan outlives this callback.
            _ = folder.startAccessingSecurityScopedResource()
            model.start(folder: folder)
        case .failure:
            break
        }
    }

    private func rescan() {
        guard let folder = model.currentFolder else { return }
        model.start(folder: folder)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = defaultExportName(ext: "csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AuditReportExporter.writeCSV(
                clips: model.clips, sourceFolder: model.currentFolder, to: url
            )
        } catch {
            presentError(error, context: "CSV export")
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultExportName(ext: "json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AuditReportExporter.writeJSON(
                clips: model.clips, sourceFolder: model.currentFolder, to: url
            )
        } catch {
            presentError(error, context: "JSON export")
        }
    }

    private func defaultExportName(ext: String) -> String {
        let base = model.currentFolder?.lastPathComponent ?? "audit-report"
        return "\(base).\(ext)"
    }

    private func presentError(_ error: Error, context: String) {
        let alert = NSAlert()
        alert.messageText = "\(context) failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private struct SidebarPlaceholder: View {
    var body: some View {
        VStack {
            Text("Sidebar")
                .foregroundColor(Theme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.primaryBackground)
    }
}

// MARK: - Wave 4.2 — Main pane, clip Table, inspector

private struct ScanMainView: View {
    let model: ScanModel
    @Binding var selectedClipID: Clip.ID?

    @State private var isDropTargeted = false

    var body: some View {
        Group {
            switch model.state {
            case .idle:
                ScanIdlePane()
            case .scanning(let scanned, let total):
                VStack(spacing: 0) {
                    ScanProgressBar(scanned: scanned, total: total, startedAt: model.scanStartedAt)
                    Divider()
                    ClipTableView(clips: model.clips, selection: $selectedClipID)
                }
            case .complete:
                VStack(spacing: 0) {
                    Divider()
                    ClipTableView(clips: model.clips, selection: $selectedClipID)
                }
            case .failed(let message):
                ScanFailedPane(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.secondaryBackground)
        .overlay(alignment: .center) {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true
            else { return false }
            model.start(folder: url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }
}

private struct ScanIdlePane: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass.circle")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .foregroundColor(Theme.secondaryText)
            Text("Avid MXF Peek")
                .font(.title)
                .foregroundColor(Theme.primaryText)
            Text("Open a MediaFiles/MXF folder to begin")
                .font(.callout)
                .foregroundColor(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanFailedPane: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .foregroundColor(.orange)
            Text("Scan failed")
                .font(.title2)
                .foregroundColor(Theme.primaryText)
            Text(message)
                .font(.callout)
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Progress strip: linear bar + scanned/total + live elapsed time.
/// Elapsed is driven by `TimelineView(.periodic)` so the timer updates
/// even when `mxf2raw` is stalling on a single slow file and no yields
/// are arriving to invalidate the surrounding view.
private struct ScanProgressBar: View {
    let scanned: Int
    let total: Int
    let startedAt: Date?

    private var fraction: Double {
        total > 0 ? Double(scanned) / Double(total) : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            HStack(spacing: 10) {
                Text("\(scanned) / \(total)")
                if let started = startedAt {
                    TimelineView(.periodic(from: started, by: 1.0)) { ctx in
                        Text(formatDuration(ctx.date.timeIntervalSince(started)))
                    }
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.primaryBackground)
    }
}

private struct ClipTableView: View {
    let clips: [Clip]
    @Binding var selection: Clip.ID?

    var body: some View {
        // `.clipped()` keeps the Table from drawing scroll content outside its own
        // frame — without it, rows can peek above the sticky column header when
        // scrolled near the bottom under `.windowStyle(.hiddenTitleBar)`.
        Table(clips, selection: $selection) {
            TableColumn("Name") { clip in
                HStack(spacing: 6) {
                    if clip.hasParseErrors {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .help("\(clip.parseErrorCount) file(s) failed to parse")
                    }
                    Text(clip.displayName)
                }
            }
            TableColumn("UMID") { clip in
                Text(shortUMID(clip))
                    .font(.caption.monospaced())
                    .foregroundColor(Theme.secondaryText)
            }
            TableColumn("Duration") { clip in
                Text(formatDuration(clip.durationSeconds))
                    .font(.caption.monospacedDigit())
            }
            TableColumn("V+A") { clip in
                Text("\(clip.videoTrackCount)+\(clip.audioTrackCount)")
                    .font(.caption.monospacedDigit())
            }
            TableColumn("Project") { clip in
                Text(clip.projectName ?? "—")
            }
            TableColumn("Size") { clip in
                Text(byteFormatter.string(fromByteCount: clip.totalSize))
                    .font(.caption.monospacedDigit())
            }
        }
        .clipped()
    }

    private func shortUMID(_ clip: Clip) -> String {
        guard let umid = clip.materialPackageUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !umid.isEmpty else { return clip.isUngroupable ? "—" : "?" }
        return umid.count >= 16 ? String(umid.suffix(16)) : umid
    }
}

private struct ClipInspectorView: View {
    let model: ScanModel
    let selectedClipID: Clip.ID?
    let playbackState: PlaybackState
    let onPairSelected: (AudioPair) -> Void

    private var selectedClip: Clip? {
        guard let id = selectedClipID else { return nil }
        return model.clips.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let clip = selectedClip {
                inspector(for: clip)
            } else {
                VStack {
                    Text("No clip selected")
                        .font(.callout)
                        .foregroundColor(Theme.secondaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.primaryBackground)
    }

    @ViewBuilder
    private func inspector(for clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PlayerView(playbackState: playbackState, onPairSelected: onPairSelected)
                .frame(minHeight: 240)
            Divider()
            ScrollView {
                metadataGrid(for: clip)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func metadataGrid(for clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clip.displayName)
                .font(.headline)
                .foregroundColor(Theme.primaryText)
                .lineLimit(2)

            if let umid = clip.materialPackageUID {
                VStack(alignment: .leading, spacing: 2) {
                    Text("UMID").font(.caption).foregroundColor(Theme.secondaryText)
                    Text(umid)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            if let project = clip.projectName { inspectorRow("Project", project) }
            if let tape = clip.tapeName { inspectorRow("Tape", tape) }
            inspectorRow("Tracks", "\(clip.videoTrackCount) video · \(clip.audioTrackCount) audio")
            inspectorRow("Size", byteFormatter.string(fromByteCount: clip.totalSize))
            inspectorRow("Duration", formatDuration(clip.durationSeconds))

            Divider().padding(.vertical, 4)

            Text("Files (\(clip.fileCount))")
                .font(.caption)
                .foregroundColor(Theme.secondaryText)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(clip.files) { file in
                    fileRow(file)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundColor(Theme.secondaryText)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundColor(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func fileRow(_ file: MXFHeaderInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.fileURL.lastPathComponent)
                .font(.caption.monospaced())
                .foregroundColor(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Text(byteFormatter.string(fromByteCount: file.fileSize))
                if file.videoTrackCount > 0 { Text("V×\(file.videoTrackCount)") }
                if file.audioTrackCount > 0 { Text("A×\(file.audioTrackCount)") }
                if file.parseError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .help(file.parseError ?? "")
                }
            }
            .font(.caption2)
            .foregroundColor(Theme.secondaryText)
        }
    }
}

// MARK: - Formatters (file-private; shared by table + inspector)

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.includesUnit = true
    return f
}()

private func formatDuration(_ seconds: Double?) -> String {
    guard let s = seconds, s.isFinite, s >= 0 else { return "—" }
    let total = Int(s.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let sec = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, sec)
        : String(format: "%d:%02d", m, sec)
}

struct FCPToolbarButtonStyle: ButtonStyle {
    @Binding var isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundColor(isOn ? .white : .primary)
            .background(
                ZStack {
                    if isOn {
                        Theme.accent
                    } else {
                        Color(nsColor: .gray.withAlphaComponent(0.2))
                    }
                    if configuration.isPressed {
                        Color.black.opacity(0.2)
                    }
                }
            )
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(0.2), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isOn)
    }
}

struct PaneToggleButton: View {
    @Binding var isOn: Bool
    let iconName: String
    let help: String

    var body: some View {
        Button(action: { withAnimation { isOn.toggle() } }) {
            Image(systemName: iconName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        }
        .help(help)
        .buttonStyle(FCPToolbarButtonStyle(isOn: $isOn))
    }
}

// MARK: - Wave 4.1 — ScanState + ScanModel
//
// Bridges `MXFFolderScanner`'s `AsyncStream<MXFHeaderInfo>` into SwiftUI state.
// Lives here to avoid pbxproj surgery; will move to `ViewModels/ScanModel.swift`
// in the end-of-Wave-4 sweep.
//
// Design (decided 2026-04-20):
// • **A1 — state shape**: single `ScanState` enum for control flow, `clips`
//   kept *outside* the enum so a rescan doesn't strobe the table empty while
//   the new scan is in flight.
// • **B3 — aggregation cadence**: re-aggregate every 50 yields OR every 250 ms,
//   whichever fires first. Smooth feel on small scans, bounded cost at 10k+.

/// High-level scan lifecycle. View layer pattern-matches on this for rendering.
enum ScanState: Equatable {
    case idle
    case scanning(scanned: Int, total: Int)
    case complete
    case failed(String)
}

@MainActor
@Observable
final class ScanModel {

    // MARK: - Observable state

    private(set) var state: ScanState = .idle
    var clips: [Clip] = []
    private(set) var currentFolder: URL?

    /// The clip row selected in `ClipTableView`. Lives here (not in ContentView @State)
    /// so `PlaybackCoordinator` can observe it via `withObservationTracking` —
    /// the Observation framework only tracks reads on @Observable types.
    var selectedClipID: Clip.ID?

    /// Wall-clock start of the in-progress scan. Cleared on cancel; left stale
    /// after completion (overwritten on next `start`). Read only while
    /// `state == .scanning` by the progress UI.
    private(set) var scanStartedAt: Date?

    // MARK: - B3 batch thresholds — tune here, not in the loop

    /// Flush after this many yields even if the time window hasn't elapsed.
    static let flushEveryYields = 50
    /// Flush after this wall-clock duration even if yield count hasn't hit the cap.
    static let flushEveryDuration: Duration = .milliseconds(250)

    // MARK: - Private

    private var scanTask: Task<Void, Never>?

    // MARK: - Public API

    /// Kick off a scan of `folder`. Cancels any scan in progress first.
    /// Previous scan's `clips` stay visible until the new scan's first batch
    /// flushes — deliberate UX choice, not a bug.
    func start(folder: URL) {
        cancel()
        currentFolder = folder

        scanTask = Task { [weak self] in
            guard let self else { return }

            let files = MXFFolderScanner.discoverMXFFiles(under: folder)
            let total = files.count
            self.scanStartedAt = Date()
            self.state = .scanning(scanned: 0, total: total)

            if total == 0 {
                self.clips = []
                self.state = .complete
                return
            }

            let scanner = MXFFolderScanner()
            let stream = scanner.scan(folder: folder)
            await self.consume(stream, total: total)

            if !Task.isCancelled {
                self.state = .complete
            }
        }
    }

    /// Cancels the in-flight scan, if any. In-flight `mxf2raw` subprocesses
    /// run to completion (known v1 limitation — see code-review #2).
    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        if case .scanning = state {
            state = .idle
            scanStartedAt = nil
        }
    }

    // MARK: - Helpers the `consume` loop uses

    /// Cheap per-yield counter tick. Does NOT re-aggregate clips.
    /// Call every yield if you want the progress bar to move smoothly,
    /// every flush if you'd rather spare the SwiftUI invalidation work.
    private func updateProgress(scanned: Int, total: Int) {
        state = .scanning(scanned: scanned, total: total)
    }

    /// Expensive re-aggregate + publish. O(N) in `partial.count`.
    /// Call on flush (every 50 yields or every 250 ms).
    private func applyBatch(partial: [MXFHeaderInfo], total: Int) {
        self.clips = ClipAggregator.aggregate(partial)
        self.state = .scanning(scanned: partial.count, total: total)
    }

    // MARK: - TODO: YOUR CONTRIBUTION (Wave 4.1)
    //
    // Implement the B3 batched-aggregation loop.
    //
    // Contract:
    //   1. for await info in stream → append to a running [MXFHeaderInfo]
    //   2. Tick progress on every yield via updateProgress(scanned:total:)
    //   3. Flush via applyBatch(partial:total:) when EITHER
    //          yieldsSinceFlush >= Self.flushEveryYields   (50)   OR
    //          elapsedSinceFlush >= Self.flushEveryDuration (250 ms)
    //      whichever fires first. Reset both counters after a flush.
    //   4. After the stream completes, do ONE FINAL applyBatch so tail
    //      results (<50 files, <250 ms) aren't stranded.
    //   5. If Task.isCancelled, break the loop cleanly — the caller handles
    //      state transitions after consume returns.
    //
    // Notes for you:
    //   • This method runs on @MainActor, so applyBatch / updateProgress are
    //     direct calls — no hop. The scanner's subprocesses are off-main.
    //   • Use ContinuousClock for the timer; wall-clock is correct here.
    //   • Pragmatic: ticking progress on every yield is fine at 10k files
    //     (~30 µs per SwiftUI invalidation), but you could throttle it too.
    //     Your call. Start simple.
    private func consume(_ stream: AsyncStream<MXFHeaderInfo>, total: Int) async {
        var infos: [MXFHeaderInfo] = []
        var yieldsSinceFlush = 0
        var lastFlush = ContinuousClock.now

        for await info in stream {
            if Task.isCancelled { break }
            infos.append(info)
            yieldsSinceFlush += 1
            updateProgress(scanned: infos.count, total: total)

            let elapsed = lastFlush.duration(to: .now)
            if yieldsSinceFlush >= Self.flushEveryYields || elapsed >= Self.flushEveryDuration {
                applyBatch(partial: infos, total: total)
                yieldsSinceFlush = 0
                lastFlush = .now
            }
        }
        // Final flush: catch the <50-yield / <250 ms tail so nothing is stranded.
        applyBatch(partial: infos, total: total)
    }
}
