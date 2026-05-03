import SwiftUI

/// `progress` is driven externally by `PlaybackController` (0...1, applied
/// only to the segment at `currentIndex`).
struct SegmentedProgressBar: View {

    let count: Int
    let currentIndex: Int
    let progress: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let segmentHeight: CGFloat = 3
    static let interSegmentGap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let totalGap = Self.interSegmentGap * CGFloat(max(count - 1, 0))
            let segmentWidth = max(0, (geo.size.width - totalGap) / CGFloat(max(count, 1)))
            HStack(spacing: Self.interSegmentGap) {
                ForEach(0..<count, id: \.self) { i in
                    segment(at: i, width: segmentWidth)
                }
            }
        }
        .frame(height: Self.segmentHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Story progress")
        .accessibilityValue("Item \(currentIndex + 1) of \(count)")
    }

    @ViewBuilder
    private func segment(at index: Int, width: CGFloat) -> some View {
        let fillWidth = width * CGFloat(filled(at: index))
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(Color.progressInactive)
                .frame(width: width, height: Self.segmentHeight)
            Capsule(style: .continuous)
                .fill(Color.progressActive)
                .frame(width: fillWidth, height: Self.segmentHeight)
                // Hard opt-out from ambient parent animations: the fill is
                // driven by 50ms ticks and by discrete resets at item-change.
                // A parent transaction in flight would otherwise animate
                // full → empty, visible as the just-completed segment
                // "rewinding" before the next one starts filling.
                .animation(nil, value: fillWidth)
        }
        .frame(width: width, alignment: .leading)
    }

    private func filled(at index: Int) -> Double {
        if index < currentIndex { return 1 }
        if index == currentIndex {
            // Reduced motion → discrete tick instead of a continuous 5s
            // linear sweep (design.md § Motion principles).
            if reduceMotion { return 0 }
            return min(max(progress, 0), 1)
        }
        return 0
    }
}

#Preview("3 segments, mid playback") {
    SegmentedProgressBar(count: 3, currentIndex: 1, progress: 0.5)
        .padding(Spacing.l)
        .frame(width: 320)
        .background(Color.background)
        .preferredColorScheme(.dark)
}

#Preview("5 segments, item 0 starting") {
    SegmentedProgressBar(count: 5, currentIndex: 0, progress: 0.0)
        .padding(Spacing.l)
        .frame(width: 320)
        .background(Color.background)
        .preferredColorScheme(.dark)
}
