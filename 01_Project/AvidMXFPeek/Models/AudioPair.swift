import Foundation

/// One stereo pair of audio stems from an Avid OP-Atom clip.
///
/// Avid clips expose audio as many independent mono MXF files (A01, A02, A03, …).
/// For preview playback we want to present them as stereo pairs (A01+A02,
/// A03+A04, …) so the user can audition each pair via `AVMediaSelectionGroup`.
/// When the stem count is odd, the last stem becomes a mono pair (same URL
/// routed to both channels) so no audio is dropped.
struct AudioPair: Sendable, Hashable, Identifiable {

    /// 0-based pair index within the clip.
    let id: Int

    /// Stem routed to the stereo left channel.
    let leftStemURL: URL

    /// Stem routed to the stereo right channel. Equal to `leftStemURL` for mono pairs.
    let rightStemURL: URL

    /// Human-readable label for UI pickers. Example: `"A01+A02"` or `"A05 (mono)"`.
    /// Alphanumeric / underscore-safe for direct use in ffmpeg `-var_stream_map name:…`.
    let label: String

    /// True when left and right channels reference the same file (odd-count fallback).
    var isMono: Bool { leftStemURL == rightStemURL }

    /// Derive stereo pairs from a `Clip`'s audio stems.
    ///
    /// Rules:
    /// - Video stems (`videoTrackCount > 0`) are excluded.
    /// - Audio stems are sorted by filename (A01, A02, …) for deterministic pairing.
    /// - Stems are grouped two-at-a-time: `[A01, A02, A03, A04]` → 2 pairs.
    /// - If the count is odd the last stem becomes a mono pair.
    /// - Clips with no audio stems produce an empty array (video-only preview).
    static func pairsFromClip(_ clip: Clip) -> [AudioPair] {
        let audioStems = clip.files
            .filter { $0.audioTrackCount > 0 && $0.videoTrackCount == 0 }
            .sorted { $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent }
            .map(\.fileURL)

        guard !audioStems.isEmpty else { return [] }

        var pairs: [AudioPair] = []
        var cursor = 0
        var pairIndex = 0
        while cursor < audioStems.count {
            let left = audioStems[cursor]
            if cursor + 1 < audioStems.count {
                let right = audioStems[cursor + 1]
                let label = "\(stemName(left))_\(stemName(right))"
                pairs.append(AudioPair(id: pairIndex, leftStemURL: left, rightStemURL: right, label: label))
                cursor += 2
            } else {
                let label = "\(stemName(left))_mono"
                pairs.append(AudioPair(id: pairIndex, leftStemURL: left, rightStemURL: left, label: label))
                cursor += 1
            }
            pairIndex += 1
        }
        return pairs
    }

    /// Extract `"A01"` from `"A01.E60D568E_8BA778BA77F96A.mxf"`.
    /// Falls back to the bare filename (no extension) if the expected `.` is absent.
    private static func stemName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if let dot = name.firstIndex(of: ".") {
            return String(name[..<dot])
        }
        return name
    }
}
