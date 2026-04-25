import AVFoundation
import Observation

/// Mutable playback state shared between `PlaybackCoordinator` and `PlayerView`.
///
/// Coordinator writes; view layer reads. All properties are main-isolated via
/// `@MainActor` on the class. See `docs/plans/2026-04-22-player-hls.md` §P6.1.
@MainActor
@Observable
final class PlaybackState {

    // MARK: - Phase

    enum Phase {
        /// No clip is selected or playback is torn down.
        case idle
        /// Transcode / AVPlayer asset load in progress.
        /// `startedAt` is the wall-clock timestamp when preparation began.
        /// `progress` is the ffmpeg encode fraction (0–1), nil until first progress event.
        case preparing(startedAt: Date, progress: Double?)
        /// AVPlayerItem.status == .readyToPlay; player is running.
        case playing
        /// Terminal error — transcode failure, missing stems, or AVPlayer error.
        case failed(String)
    }

    // MARK: - Observable properties

    var phase: Phase = .idle

    /// Nil in `.idle`. Created once on first clip load; reused via `replaceCurrentItem` thereafter.
    var player: AVPlayer?

    /// The clip currently being prepared or playing.
    var currentClipID: Clip.ID?

    /// All stereo pairs available for the current clip. Empty for video-only clips.
    var audioPairs: [AudioPair] = []

    /// The pair currently routed to the player's audible track. Nil when `audioPairs` is empty.
    var selectedPair: AudioPair?

    /// The HLS audible selection group. Populated once `AVPlayerItem.status == .readyToPlay`.
    /// Nil for video-only clips or while still preparing.
    var audibleGroup: AVMediaSelectionGroup?

    // MARK: - Convenience

    /// Clear all state back to `.idle`. Called by the coordinator when selection clears.
    func reset() {
        phase = .idle
        currentClipID = nil
        audioPairs = []
        selectedPair = nil
        audibleGroup = nil
        // player is retained and cleared by the coordinator via replaceCurrentItem(with: nil)
    }
}

// MARK: - Phase Equatable

extension PlaybackState.Phase: Equatable {
    static func == (lhs: PlaybackState.Phase, rhs: PlaybackState.Phase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.preparing(let la, let lp), .preparing(let ra, let rp)):
            // Date identity: treat same pointer / value as equal for test assertions.
            return la == ra && lp == rp
        case (.playing, .playing):
            return true
        case (.failed(let l), .failed(let r)):
            return l == r
        default:
            return false
        }
    }
}
