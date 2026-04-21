import SwiftUI

// MARK: - Theme

/// FCP-style dark color palette, matching Penumbra and CropBatch conventions
/// per the App Shell Standard (see docs/cookbook/00-app-shell.md).
///
/// Use `Theme.xxx` everywhere for backgrounds, text, and accent — never
/// `Color.gray`, `.secondary` for chrome, or `NSColor.*` in view code.
/// The app runs in forced dark mode, so there is no light-mode variant.
struct Theme {
    /// Graphite — darkest surface. Used for outer chrome: header, footer, sidebars.
    static var primaryBackground: Color { Color(white: 0.10) }

    /// Charcoal — slightly lifted surface. Used for the main content area so it
    /// reads as the focus zone rather than disappearing into the chrome.
    static var secondaryBackground: Color { Color(white: 0.15) }

    /// Brand accent — warm orange. Used for selection, active toggles, primary actions.
    static var accent: Color { Color(red: 0.9, green: 0.5, blue: 0.2) }

    /// Primary text — pure white.
    static var primaryText: Color { .white }

    /// Secondary text — muted white for captions, helper text, disabled states.
    static var secondaryText: Color { .white.opacity(0.65) }
}
