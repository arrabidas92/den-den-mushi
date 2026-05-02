import SwiftUI

/// Bottom chrome of the viewer. Currently just the like button on the
/// trailing edge — the design spec calls for an optional message field on
/// the leading side, but it is in the *Polish skipped* list (see
/// CLAUDE.md), so the leading edge is empty by design.
///
/// The footer height is a fixed token so the tap-zone calculation in
/// `StoryViewerPage` can subtract a known constant.
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
