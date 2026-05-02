import SwiftUI

/// Two transparent zones laid out 1:2 vertically (left third = previous,
/// right two-thirds = next). The asymmetry mirrors Instagram and reflects
/// that *forward* is the dominant action — a Fitts-law improvement, not a
/// stylistic choice (see `design.md` § *Tap zones*).
///
/// Double-tap inside the right zone fires `onDoubleTap` with the tap
/// location in the *right zone's local coordinate space* — the parent
/// reads that geometry from the same enclosing space so the heart-pop
/// overlay anchors correctly without an extra coordinate hop.
///
/// SwiftUI's `.onTapGesture(count: 2)` declared *before* `.onTapGesture`
/// gives the gesture system the precedence it needs: a quick double-tap
/// fires only the double-tap, a single tap fires only the single-tap
/// after the double-tap window closes. The two never collide.
struct ViewerTapZones: View {

    let onPrevious: () -> Void
    let onNext: () -> Void
    /// Reports the tap location in the *right zone's* local coordinate
    /// space, so the parent can lay the heart-pop overlay inside the same
    /// frame without a second coordinate transform.
    let onDoubleTap: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: geo.size.width / 3)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onPrevious)
                    .accessibilityLabel("Previous")
                    .accessibilityAddTraits(.isButton)

                rightZone
            }
        }
    }

    private var rightZone: some View {
        // GeometryReader inside so `location` from SpatialTapGesture is
        // already expressed in the right zone's coordinates — no math at
        // the call site.
        GeometryReader { _ in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { event in onDoubleTap(event.location) }
                )
                .simultaneousGesture(
                    TapGesture(count: 1).onEnded(onNext)
                )
                .accessibilityLabel("Next")
                .accessibilityAddTraits(.isButton)
        }
    }
}

#Preview("Tap zones overlay") {
    ZStack {
        Color.surface
        ViewerTapZones(
            onPrevious: {},
            onNext: {},
            onDoubleTap: { _ in },
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
