import SwiftUI

struct StoryViewerFooter: View {

    let isLiked: Bool
    let onToggleLike: @MainActor () -> Void

    static let height: CGFloat = 64

    var body: some View {
        HStack(spacing: Spacing.m) {
            Spacer()
            LikeButton(isLiked: isLiked, action: onToggleLike)
        }
        .padding(.horizontal, Spacing.l)
        .frame(height: Self.height)
    }
}

#Preview("Liked / Not liked") {
    VStack(spacing: Spacing.l) {
        StoryViewerFooter(isLiked: false, onToggleLike: {})
        StoryViewerFooter(isLiked: true, onToggleLike: {})
    }
    .frame(maxWidth: .infinity)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
