import SwiftUI

/// 28pt heart button. Stroke white when not liked, fill #FF3B30 when liked.
/// Spring + haptic fire internally on tap; the parent only needs to pass
/// the boolean state and the action closure.
struct LikeButton: View {

    let isLiked: Bool
    let action: @MainActor () -> Void

    @State private var scale: CGFloat = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let iconSize: CGFloat = 28
    static let touchTarget: CGFloat = 44

    var body: some View {
        Button(action: tap) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .foregroundStyle(isLiked ? Color.accentLike : Color.textPrimary)
                .scaleEffect(scale)
                .frame(width: Self.touchTarget, height: Self.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLiked ? "Unlike" : "Like")
        .accessibilityValue(isLiked ? "liked" : "not liked")
    }

    private func tap() {
        Haptics.like()
        action()
        guard !reduceMotion else { return }
        withAnimation(Motion.likeButtonSpring) {
            scale = 1.2
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(Motion.likeButtonSpring) {
                scale = 1.0
            }
        }
    }
}

#Preview("Liked / Not liked") {
    HStack(spacing: Spacing.xl) {
        LikeButton(isLiked: false, action: {})
        LikeButton(isLiked: true, action: {})
    }
    .padding(Spacing.l)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
