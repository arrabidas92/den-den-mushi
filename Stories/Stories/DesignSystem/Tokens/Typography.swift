import SwiftUI

/// Named typographic styles — `Font.system(size:)` directly in Views is
/// forbidden so the type scale stays consistent.
extension Font {

    static let usernameTray      = Font.system(size: 12, weight: .medium, design: .default)

    static let usernameHeader    = Font.system(size: 15, weight: .semibold, design: .default)

    static let timestamp         = Font.system(size: 13, weight: .regular, design: .default)

    static let body15            = Font.system(size: 15, weight: .regular, design: .default)
}
