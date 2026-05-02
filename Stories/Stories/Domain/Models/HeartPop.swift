import CoreGraphics
import Foundation

/// One double-tap heart-pop event. The unique `id` lets back-to-back
/// double-taps render as distinct overlay instances even if `location`
/// matches — without it, SwiftUI would diff the second pop as the same
/// view and skip the animation.
nonisolated struct HeartPop: Sendable, Equatable, Identifiable {
    let id: UUID
    let location: CGPoint

    init(id: UUID = UUID(), location: CGPoint) {
        self.id = id
        self.location = location
    }
}
