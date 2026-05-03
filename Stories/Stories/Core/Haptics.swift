import UIKit

/// Thin UIKit haptics wrapper. Three named events match the moments listed
/// in the design spec — like, user-change, dismiss. We do not expose raw
/// generators to Views: the named API forces every haptic call to map onto
/// a documented design-spec moment.
///
/// Generators are kept alive between calls and `prepare()`-ed up-front by
/// `prewarm()`. Without this, the *first* `impactOccurred()` of a session
/// pays a one-shot cost — the Core Haptics engine and `RenderBox.metallib`
/// load lazily on demand, which produced a measured ~0.46s hang on the
/// first like-button tap.
@MainActor
enum Haptics {

    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)

    /// Warm the haptic engine and the three generators we use. Call once on
    /// viewer entry — `prepare()` is a no-op cost during steady-state but
    /// removes the cold-start hang on the first impact of the session.
    static func prewarm() {
        mediumGenerator.prepare()
        softGenerator.prepare()
        lightGenerator.prepare()
    }

    /// Decisive, mid-weight. Like tap.
    static func like() {
        mediumGenerator.impactOccurred()
        // Re-prime for the next call so back-to-back likes also fire warm.
        mediumGenerator.prepare()
    }

    /// Soft, low-energy. User-to-user horizontal swipe.
    static func userChange() {
        softGenerator.impactOccurred()
        softGenerator.prepare()
    }

    /// Light, near-silent. Swipe-down dismiss commit.
    static func dismiss() {
        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }
}
