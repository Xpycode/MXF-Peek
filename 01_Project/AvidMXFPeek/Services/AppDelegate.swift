import AppKit

/// AppKit delegate hook for clean app-quit.
///
/// Cmd-Q routes through `applicationShouldTerminate(_:)` which we use to
/// SIGTERM any in-flight ffmpeg subprocess before AppKit exits. Returning
/// `.terminateLater` is the only Apple-documented way to await async
/// cleanup without blocking the AppKit runloop — the runloop spins in
/// `NSModalPanelRunLoopMode` until we call `reply(toApplicationShouldTerminate:)`,
/// which lets `@MainActor` Tasks (and `Process.terminationHandler` callbacks)
/// fire normally during the wait.
///
/// Without this hook, ffmpeg children get reparented to launchd on quit
/// and continue running. Note: we cannot defend against SIGKILL of the
/// app itself (force-quit, crash) — Darwin has no `PR_SET_PDEATHSIG`
/// equivalent. See plan §P8.4 research notes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by `AvidMXFPeekApp` once the coordinator graph is initialized.
    /// Weak so the app's `@State` retains ownership.
    weak var coordinator: PlaybackCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        Task { @MainActor in
            await coordinator.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
