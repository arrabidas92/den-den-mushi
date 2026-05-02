import CoreGraphics

/// Layout spacing scale. Powers-of-two-ish, predictable. Magic numbers in
/// View code are forbidden — pull from this enum so the rhythm stays
/// consistent across the product.
enum Spacing {
    static let xs: CGFloat  = 4
    static let s: CGFloat   = 8
    static let m: CGFloat   = 12
    static let l: CGFloat   = 16
    static let xl: CGFloat  = 24
    static let xxl: CGFloat = 32
}
