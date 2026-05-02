import SwiftUI

/// Named typographic styles. Always reference these — `Font.system(size:)`
/// in Views is forbidden — so the type scale stays consistent and the
/// reviewer can audit it in one place.
extension Font {

    /// 12pt SF Pro Text, medium. Tray usernames.
    static let usernameTray      = Font.system(size: 12, weight: .medium, design: .default)

    /// 15pt SF Pro Text, semibold. Viewer header username.
    static let usernameHeader    = Font.system(size: 15, weight: .semibold, design: .default)

    /// 13pt SF Pro Text, regular. Header timestamp, failure caption.
    static let timestamp         = Font.system(size: 13, weight: .regular, design: .default)

    /// 22pt SF Pro Display, bold. Section headers (none currently in use,
    /// kept for future surfaces and parity with the design spec).
    static let sectionTitle      = Font.system(size: 22, weight: .bold, design: .default)

    /// 15pt SF Pro Text, regular. Body copy.
    static let body15            = Font.system(size: 15, weight: .regular, design: .default)

    /// 11pt SF Pro Text, regular. Captions, hints.
    static let caption11         = Font.system(size: 11, weight: .regular, design: .default)
}
