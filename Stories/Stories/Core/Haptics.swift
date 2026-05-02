import UIKit

/// Thin UIKit haptics wrapper. Three named events match the moments listed
/// in the design spec — like, user-change, dismiss. We do not expose raw
/// generators to Views: the named API forces every haptic call to map onto
/// a documented design-spec moment.
enum Haptics {

    /// Decisive, mid-weight. Like tap and double-tap heart pop.
    static func like() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Soft, low-energy. User-to-user horizontal swipe.
    static func userChange() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// Light, near-silent. Swipe-down dismiss commit.
    static func dismiss() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
