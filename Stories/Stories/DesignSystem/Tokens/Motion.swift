import SwiftUI

/// Animation tokens. `fastAnimation(reduceMotion:)` collapses to zero
/// so callers never special-case `accessibilityReduceMotion` themselves.
enum Motion {

    /// 1.2s — one full opacity cycle of the skeleton tray.
    static var skeletonPulse: Duration { Duration.milliseconds(1_200) }

    /// 200ms ease-out, or instant under reduced motion.
    static func fastAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.2)
    }

    /// Spring matched to the LikeButton tap (response 0.3, damping 0.6).
    static let likeButtonSpring: Animation = .spring(response: 0.3, dampingFraction: 0.6)
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
