import SwiftUI

/// Single source of truth for every animation duration in the product.
/// One-place reduced-motion override — `accessibilityReduceMotion` collapses
/// every token to zero — so callers never special-case it themselves.
enum Motion {

    /// 0.2s — micro-feedback (pause overlay fade, tap state).
    static var fast: Duration { Duration.milliseconds(200) }

    /// 0.3s — primary affordances (like spring, header fade).
    static var standard: Duration { Duration.milliseconds(300) }

    /// 0.4s — ring crossfade, dismiss animation tail.
    static var slow: Duration { Duration.milliseconds(400) }

    /// 5.0s — single story item duration (progress bar fill).
    static var itemPlay: Duration { Duration.seconds(5) }

    /// 1.2s — one full opacity cycle of the skeleton tray.
    static var skeletonPulse: Duration { Duration.milliseconds(1_200) }

    /// SwiftUI `Animation` for `fast`, honouring `reduceMotion` (0s) when set.
    static func fastAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.2)
    }

    /// SwiftUI `Animation` for `standard`, honouring `reduceMotion`.
    static func standardAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.3)
    }

    /// SwiftUI `Animation` for `slow`, honouring `reduceMotion`.
    static func slowAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.4)
    }

    /// Linear progress fill over a single item. Reduced-motion collapses it
    /// to a discrete tick at item end (the View that consumes this token
    /// applies the linear vs identity branch on its own).
    static func itemPlayLinear(_ duration: Duration = itemPlay) -> Animation {
        .linear(duration: duration.seconds)
    }

    /// Spring matched to the LikeButton tap (response 0.3, damping 0.6).
    static let likeButtonSpring: Animation = .spring(response: 0.3, dampingFraction: 0.6)
}

extension Duration {
    /// `Duration` -> `TimeInterval` (Double seconds), used by SwiftUI's
    /// `.linear(duration:)` and other APIs that predate `Duration`.
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
