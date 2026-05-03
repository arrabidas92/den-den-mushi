import SwiftUI

/// Two transparent zones laid out 1:2 vertically (left third = previous,
/// right two-thirds = next). The asymmetry mirrors Instagram and reflects
/// that *forward* is the dominant action — a Fitts-law improvement, not a
/// stylistic choice (see `design.md` § *Tap zones*).
///
/// Single-tap only — fires immediately with no arbitration delay. The
/// double-tap heart-pop is mounted *above* this view in `StoryViewerPage`
/// via a `simultaneousGesture`, so a quick double-tap on the right zone
/// fires the heart pop AND advances by one item (Instagram parity).
struct ViewerTapZones: View {

    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: geo.size.width / 3)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onPrevious)
                    .accessibilityLabel("Previous")
                    .accessibilityAddTraits(.isButton)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onNext)
                    .accessibilityLabel("Next")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }
}

#Preview("Tap zones overlay") {
    ZStack {
        Color.surface
        ViewerTapZones(
            onPrevious: {},
            onNext: {},
        )
        // Visualise the split for the preview — not part of the runtime UI.
        HStack(spacing: 0) {
            Color.red.opacity(0.15).frame(maxWidth: .infinity)
            Color.green.opacity(0.15).frame(maxWidth: .infinity)
            Color.green.opacity(0.15).frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
    }
    .preferredColorScheme(.dark)
}
