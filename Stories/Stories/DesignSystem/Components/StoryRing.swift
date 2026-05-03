import SwiftUI

/// Top-level alias so call-sites can write `StoryRingState.unseen` rather
/// than `StoryRing.RingState.unseen` — matches the design-spec API shape.
typealias StoryRingState = StoryRing.RingState

/// Pure ring renderer — knows nothing about avatars, images, or users.
/// `StoryAvatar` composes this with the inner content; `StoryTrayItem`
/// composes that with the username.
struct StoryRing: View {

    enum RingState: Sendable, Equatable {
        case unseen
        case seen
        case loading
    }

    let state: RingState
    let size: CGFloat

    @SwiftUI.State private var shimmerPhase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 3pt gap between ring stroke and inner content.
    static let ringGap: CGFloat = 3

    var body: some View {
        Circle()
            .strokeBorder(strokeStyle, lineWidth: lineWidth)
            .frame(width: size, height: size)
            .onAppear { startShimmerIfLoading() }
            .onChange(of: state) { _, _ in startShimmerIfLoading() }
    }

    /// Resolved as `AnyShapeStyle` so the loading branch can hand back a
    /// gradient while the static branches return a flat colour. SwiftUI's
    /// `strokeBorder` accepts any `ShapeStyle`, so the type erasure is the
    /// only friction.
    private var strokeStyle: AnyShapeStyle {
        switch state {
        case .unseen:
            return AnyShapeStyle(Color.ringUnseen)
        case .seen:
            return AnyShapeStyle(Color.ringSeen)
        case .loading:
            return AnyShapeStyle(shimmerGradient)
        }
    }

    /// Angular gradient with a bright highlight that sweeps around the
    /// ring. `shimmerPhase` rotates the gradient via the start-angle so
    /// the highlight orbits the circle rather than fading uniformly —
    /// reads as motion, not a pulse.
    private var shimmerGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: Color.ringSeen, location: 0.0),
                .init(color: Color.ringUnseen, location: 0.5),
                .init(color: Color.ringSeen, location: 1.0),
            ]),
            center: .center,
            startAngle: .degrees(360 * Double(shimmerPhase)),
            endAngle: .degrees(360 * Double(shimmerPhase) + 360),
        )
    }

    private var lineWidth: CGFloat {
        switch state {
        case .unseen, .loading: return 2
        case .seen:             return 1.5
        }
    }

    private func startShimmerIfLoading() {
        guard state == .loading, !reduceMotion else {
            shimmerPhase = 0
            return
        }
        shimmerPhase = 0
        withAnimation(.linear(duration: Motion.skeletonPulse.seconds).repeatForever(autoreverses: false)) {
            shimmerPhase = 1
        }
    }
}

#Preview("Ring states") {
    HStack(spacing: Spacing.l) {
        StoryRing(state: .unseen, size: 64)
        StoryRing(state: .seen, size: 64)
        StoryRing(state: .loading, size: 64)
    }
    .padding(Spacing.l)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
