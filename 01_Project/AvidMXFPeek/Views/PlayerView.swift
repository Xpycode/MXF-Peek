import SwiftUI
import AVKit

/// SwiftUI container for the v1.2 preview player.
///
/// Wraps `AVPlayerView` via `NSViewRepresentable` (see plan §11.4 — we need
/// `showsTimecodes` + frame-stepping + JKL shortcuts which `SwiftUI.VideoPlayer`
/// doesn't expose). Overlays match `PlaybackState.phase`: spinner while
/// transcoding, error banner on failure. Audio-pair Picker is above the
/// player and hidden/disabled when the clip has fewer than 2 stereo pairs.
///
/// See `docs/plans/2026-04-22-player-hls.md` §P7.
struct PlayerView: View {
    @Bindable var playbackState: PlaybackState
    let onPairSelected: (AudioPair) -> Void

    var body: some View {
        VStack(spacing: 0) {
            audioPairPicker
            ZStack {
                AVPlayerViewRepresentable(player: playbackState.player)
                    .background(Color.black)
                phaseOverlay
            }
        }
    }

    // MARK: - Audio pair picker

    @ViewBuilder
    private var audioPairPicker: some View {
        if playbackState.audioPairs.count >= 2 {
            HStack(spacing: 6) {
                Text("Audio")
                    .font(.caption)
                    .foregroundColor(Theme.secondaryText)
                Picker("Audio", selection: $playbackState.selectedPair) {
                    ForEach(playbackState.audioPairs) { pair in
                        Text(pair.label).tag(Optional(pair))
                    }
                }
                .pickerStyle(.menu)
                .disabled({
                    if case .playing = playbackState.phase { return false }
                    return true
                }())
                .onChange(of: playbackState.selectedPair) { _, new in
                    if let new { onPairSelected(new) }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.secondaryBackground)
        }
    }

    // MARK: - Phase overlay

    @ViewBuilder
    private var phaseOverlay: some View {
        switch playbackState.phase {
        case .idle, .playing:
            EmptyView()

        case .preparing(let startedAt, let progress):
            Color.black.opacity(0.5)
                .overlay {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)

                        TimelineView(.periodic(from: .now, by: 1.0)) { context in
                            let elapsed = Int(context.date.timeIntervalSince(startedAt))
                            Text("\(elapsed)s")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.white)
                        }

                        if let progress {
                            ProgressView(value: progress)
                                .tint(Theme.accent)
                                .frame(width: 240)
                        }
                    }
                }

        case .failed(let message):
            Color.black.opacity(0.5)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.accent)
                            .font(.title2)
                        Text("Preview failed")
                            .font(.headline)
                            .foregroundColor(Theme.primaryText)
                        Text(message)
                            .font(.caption)
                            .foregroundColor(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .background(Theme.secondaryBackground)
                    .cornerRadius(8)
                }
        }
    }
}

// MARK: - AVPlayerView wrapper

/// `NSViewRepresentable` wrapper around `AVPlayerView`.
///
/// `showsTimecodes` and `showsFrameSteppingButtons` are set once at creation.
/// `updateNSView` guards against reassigning an identical player — repeated assignment
/// causes AVKit to tear down and rebuild its control layer unnecessarily.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFrameSteppingButtons = true
        view.showsTimecodes = true
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
