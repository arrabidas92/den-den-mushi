import SwiftUI

/// Two transparent zones laid out 1:2 vertically (left third = previous,
/// right two-thirds = next). The asymmetry mirrors Instagram and reflects
/// that *forward* is the dominant action — a Fitts-law improvement, not a
/// stylistic choice (see `design.md` § *Tap zones*).
///
/// `onNext`/`onPrevious` fire *immediately* on single tap — no waiting
/// for a possible double-tap. SwiftUI's
/// `TapGesture(count: 2).exclusively(before: TapGesture(count: 1))`
/// composition forces a 250–300 ms wait before the single tap commits,
/// which the reviewer perceived as a noticeable lag on every forward
/// tap. We accept the trade-off that a double-tap on the right zone
/// also advances the story by one item: the heart pop fires on the
/// newly-current item, which mirrors Instagram's behaviour when a user
/// taps quickly twice.
struct ViewerTapZones: View {

    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDoubleTap: () -> Void

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
        // Two independent `onTapGesture` modifiers (count 2 declared
        // *before* count 1) let SwiftUI fire the single-tap path with
        // minimal arbitration delay while still routing a recognised
        // double-tap to `onDoubleTap`.
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDoubleTap)
            .onTapGesture(count: 1, perform: onNext)
            .accessibilityLabel("Next")
            .accessibilityAddTraits(.isButton)
    }
}

#Preview("Tap zones overlay") {
    ZStack {
        Color.surface
        ViewerTapZones(
            onPrevious: {},
            onNext: {},
            onDoubleTap: {},
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
