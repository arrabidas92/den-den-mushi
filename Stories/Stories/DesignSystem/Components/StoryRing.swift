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

    @SwiftUI.State private var pulseOpacity: Double = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 3pt gap between ring stroke and inner content.
    static let ringGap: CGFloat = 3

    var body: some View {
        Circle()
            .strokeBorder(strokeColor, lineWidth: lineWidth)
            .frame(width: size, height: size)
            .opacity(pulseOpacity)
            .onAppear { startPulseIfLoading() }
            .onChange(of: state) { _, _ in startPulseIfLoading() }
    }

    private var strokeColor: Color {
        switch state {
        case .unseen, .loading: return .ringUnseen
        case .seen:             return .ringSeen
        }
    }

    private var lineWidth: CGFloat {
        switch state {
        case .unseen, .loading: return 2
        case .seen:             return 1.5
        }
    }

    private func startPulseIfLoading() {
        guard state == .loading, !reduceMotion else {
            pulseOpacity = 1.0
            return
        }
        withAnimation(.easeInOut(duration: Motion.skeletonPulse.seconds).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.4
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
