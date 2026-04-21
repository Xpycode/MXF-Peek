import Foundation

/// Bundled command-line tools AvidMXFPeek depends on.
///
/// As of the 2026-04-20-C pivot the app ships with exactly one bundled
/// binary — `ffprobe` (arm64 static, martin-riedl.de). The prior
/// bmx/mxf2raw/bmxtranswrap/ffmpeg toolchain + lib dylibs were dropped
/// when real-data validation showed bmx's libMXF refuses Avid's non-standard
/// `VideoLineMap` descriptor. See `docs/plans/2026-04-20-ffprobe-pivot.md`.
enum BundledTool: String, CaseIterable {
    case ffprobe

    var displayName: String {
        switch self {
        case .ffprobe: return "FFprobe"
        }
    }
}

/// Resolves paths to bundled command-line tools.
///
/// Bundle-first: looks inside `.app/Contents/Resources`. Dev ergonomics
/// fallback to Homebrew so the app can run from a freshly-cloned checkout
/// before `bundle-ffprobe.sh` has populated Resources/.
struct BundledToolResolver {

    static let shared = BundledToolResolver()

    private init() {}

    /// Resolves the path for a bundled tool.
    func path(for tool: BundledTool) -> URL? {
        if let bundledPath = Bundle.main.url(forResource: tool.rawValue, withExtension: nil) {
            return bundledPath
        }
        return homebrewPath(for: tool)
    }

    /// Whether a given tool is resolvable right now.
    func isAvailable(_ tool: BundledTool) -> Bool {
        path(for: tool) != nil
    }

    // MARK: - Private

    private func homebrewPath(for tool: BundledTool) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(tool.rawValue)",   // Apple Silicon
            "/usr/local/bin/\(tool.rawValue)"       // Intel
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    // MARK: - Diagnostics

    /// Diagnostic summary of tool availability. Used by logging / about panels.
    func diagnosticSummary() -> String {
        var lines = ["Tool Availability:"]
        for tool in BundledTool.allCases {
            if let url = path(for: tool) {
                let isBundled = url.path.contains(".app/")
                lines.append("  \(tool.displayName): ✓ \(url.path) (\(isBundled ? "bundled" : "system"))")
            } else {
                lines.append("  \(tool.displayName): ✗ not found")
            }
        }
        return lines.joined(separator: "\n")
    }
}
