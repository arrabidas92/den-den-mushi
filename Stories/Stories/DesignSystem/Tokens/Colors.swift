import SwiftUI

/// Project-wide color palette. Always reference these tokens — never raw
/// `Color(red:green:blue:)` calls in Views — so we can drift the palette
/// in one place. `sRGB` is explicit so values match across iOS versions.
extension Color {

    // MARK: - Backgrounds

    static let background        = Color(.sRGB, red: 0,    green: 0,    blue: 0,    opacity: 1)
    static let surface           = Color(.sRGB, red: 0.055, green: 0.055, blue: 0.055, opacity: 1) // #0E0E0E
    static let surfaceElevated   = Color(.sRGB, red: 0.102, green: 0.102, blue: 0.102, opacity: 1) // #1A1A1A
    static let border            = Color(.sRGB, red: 0.165, green: 0.165, blue: 0.165, opacity: 1) // #2A2A2A

    // MARK: - Text

    static let textPrimary       = Color(.sRGB, red: 1.0, green: 1.0, blue: 1.0, opacity: 1)
    static let textSecondary     = Color(.sRGB, red: 0.627, green: 0.627, blue: 0.627, opacity: 1) // #A0A0A0
    static let textTertiary      = Color(.sRGB, red: 0.353, green: 0.353, blue: 0.353, opacity: 1) // #5A5A5A

    // MARK: - Story rings

    static let ringUnseen        = Color(.sRGB, red: 1.0, green: 1.0, blue: 1.0, opacity: 1)
    static let ringSeen          = Color(.sRGB, red: 0.251, green: 0.251, blue: 0.251, opacity: 1) // #404040
    static let ringLoading       = Color(.sRGB, red: 1.0, green: 1.0, blue: 1.0, opacity: 1)

    // MARK: - Accents

    static let accentLike        = Color(.sRGB, red: 1.0, green: 0.231, blue: 0.188, opacity: 1) // #FF3B30
    static let progressActive    = Color(.sRGB, red: 1.0, green: 1.0, blue: 1.0, opacity: 1)
    static let progressInactive  = Color(.sRGB, red: 1.0, green: 1.0, blue: 1.0, opacity: 0.3)
}
