import UIKit

/// Three named events matching the design-spec moments (like, user-change,
/// dismiss). Generators are kept alive and `prepare()`-d up-front by
/// `prewarm()` — without this the *first* `impactOccurred()` of a session
/// pays the lazy load of Core Haptics + `RenderBox.metallib` (~0.46s hang
/// measured on the first like tap).
@MainActor
enum Haptics {

    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)

    static func prewarm() {
        mediumGenerator.prepare()
        softGenerator.prepare()
        lightGenerator.prepare()
    }

    static func like() {
        mediumGenerator.impactOccurred()
        mediumGenerator.prepare()
    }

    static func userChange() {
        softGenerator.impactOccurred()
        softGenerator.prepare()
    }

    static func dismiss() {
        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }
}
