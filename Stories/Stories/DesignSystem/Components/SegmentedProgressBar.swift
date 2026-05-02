import SwiftUI

/// Pure rendering — `progress` is driven externally by `PlaybackController`.
/// Segments before `currentIndex` render full, after render at 30% opacity,
/// the active one fills proportionally to `progress`.
struct SegmentedProgressBar: View {

    let count: Int
    let currentIndex: Int
    /// 0...1, only applied to the segment at `currentIndex`.
    let progress: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 3pt height per the design spec; matches the perceptual minimum
    /// for "this is a thin progress bar" without crossing into hairline.
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
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(Color.progressInactive)
                .frame(width: width, height: Self.segmentHeight)
            Capsule(style: .continuous)
                .fill(Color.progressActive)
                .frame(width: width * CGFloat(filled(at: index)), height: Self.segmentHeight)
        }
        .frame(width: width, alignment: .leading)
    }

    private func filled(at index: Int) -> Double {
        if index < currentIndex { return 1 }
        if index == currentIndex {
            // Reduced motion: a discrete tick (empty until the item ends,
            // then full at index advance) is preferable to a continuous
            // 5s linear sweep — see design.md § Motion principles.
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
