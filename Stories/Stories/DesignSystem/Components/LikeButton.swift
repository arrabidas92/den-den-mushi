import SwiftUI

struct LikeButton: View {

    let isLiked: Bool
    let action: @MainActor () -> Void

    @State private var scale: CGFloat = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let iconSize: CGFloat = 28
    static let touchTarget: CGFloat = 44

    var body: some View {
        // `onTapGesture` rather than `Button`: the viewer's root drag gesture
        // (minimum 10pt) makes Button wait for the drag to engage or release
        // before firing — ~100ms delay on the first tap of a session.
        Image(systemName: isLiked ? "heart.fill" : "heart")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: Self.iconSize, height: Self.iconSize)
            .foregroundStyle(isLiked ? Color.accentLike : Color.textPrimary)
            .scaleEffect(scale)
            .frame(width: Self.touchTarget, height: Self.touchTarget)
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isLiked ? "Unlike" : "Like")
            .accessibilityValue(isLiked ? "liked" : "not liked")
    }

    private func tap() {
        Haptics.like()
        action()
        guard !reduceMotion else { return }
        withAnimation(Motion.likeButtonSpring) {
            scale = 1.2
        } completion: {
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
