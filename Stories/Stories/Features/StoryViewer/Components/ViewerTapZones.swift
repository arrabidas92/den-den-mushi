import SwiftUI

/// Two transparent zones split 1:2 (left third → previous, right two-thirds
/// → next), Instagram parity (forward is the dominant action — design.md).
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
        HStack(spacing: 0) {
            Color.red.opacity(0.15).frame(maxWidth: .infinity)
            Color.green.opacity(0.15).frame(maxWidth: .infinity)
            Color.green.opacity(0.15).frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
    }
    .preferredColorScheme(.dark)
}
