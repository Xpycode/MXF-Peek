import SwiftUI

@main
struct AvidMXFPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var model = ScanModel()
    @State private var playbackState = PlaybackState()
    @State private var coordinator: PlaybackCoordinator?

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: model,
                playbackState: playbackState,
                coordinator: coordinator
            )
            .frame(minWidth: 900, minHeight: 600)
            .preferredColorScheme(.dark)
            .task { initializeCoordinatorIfNeeded() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Open Folder\u{2026}") {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    @MainActor
    private func initializeCoordinatorIfNeeded() {
        guard coordinator == nil else { return }
        do {
            let cacheRoot = PreviewCache.defaultRootDir()
            let cache = try PreviewCache(rootDir: cacheRoot)
            let server = try PreviewHTTPServer(rootDir: cacheRoot)
            let ffmpegURL = BundledToolResolver.shared.path(for: .ffmpeg)
                ?? URL(fileURLWithPath: "/dev/null")  // no-ffmpeg fallback; transcode will .failed at runtime
            let transcoder = PreviewTranscoder(ffmpegURL: ffmpegURL)
            let c = PlaybackCoordinator(
                scanModel: model,
                playbackState: playbackState,
                cache: cache,
                server: server,
                transcode: { videoURL, pairs, duration, outputDir in
                    transcoder.transcode(
                        videoStemURL: videoURL,
                        audioPairs: pairs,
                        durationSeconds: duration,
                        outputDir: outputDir
                    )
                }
            )
            c.start()
            coordinator = c
            appDelegate.coordinator = c
        } catch {
            // Player disabled; scan / browse / export still work.
            print("[AvidMXFPeek] playback init failed: \(error)")
        }
    }
}

extension Notification.Name {
    static let openFolder = Notification.Name("avidmxfpeek.openFolder")
}
