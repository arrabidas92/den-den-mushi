import SwiftUI
import NukeUI

/// Avatar image with a ring around it. Three internal phases:
/// - **Loading**: pulsing ring + Surface elevated inner.
/// - **Loaded**: image fills the inner circle.
/// - **Failed**: initials glyph on Surface elevated, no haptic, no log spam.
///
/// `ring` is provided by the consumer because the seen/unseen decision lives
/// in the ViewModel — the avatar component itself is dumb.
struct StoryAvatar: View {

    let url: URL?
    let initials: String
    let ring: StoryRing.RingState
    let size: CGFloat

    init(url: URL?, initials: String, ring: StoryRing.RingState, size: CGFloat = 64) {
        self.url = url
        self.initials = initials
        self.ring = ring
        self.size = size
    }

    var body: some View {
        let innerDiameter = size - 2 * (StoryRing.ringGap + 2) // ring stroke ~2pt + gap
        ZStack {
            inner
                .frame(width: innerDiameter, height: innerDiameter)
                .clipShape(Circle())
            StoryRing(state: ring, size: size)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var inner: some View {
        if let url {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if state.error != nil {
                    initialsView
                } else {
                    Color.surfaceElevated
                }
            }
        } else {
            initialsView
        }
    }

    private var initialsView: some View {
        ZStack {
            Color.surfaceElevated
            Text(initials)
                .font(.usernameHeader)
                .foregroundStyle(Color.textSecondary)
        }
    }
}

#Preview("Avatar states") {
    HStack(spacing: Spacing.l) {
        StoryAvatar(url: nil, initials: "AM", ring: .unseen, size: 64)
        StoryAvatar(url: nil, initials: "BK", ring: .seen, size: 64)
        StoryAvatar(url: nil, initials: "CR", ring: .loading, size: 64)
    }
    .padding(Spacing.l)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
