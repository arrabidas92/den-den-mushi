import SwiftUI

/// Tray cell — avatar + label + tap target. Three states share identical
/// outer geometry (avatar 64pt, label height) so switching state never
/// reflows neighbours. Density only affects the *parent* HStack spacing
/// (in `StoryListView`); we accept it here purely for prop colocation.
struct StoryTrayItem: View {

    enum State: Sendable {
        case loaded(user: User, isFullySeen: Bool)
        case loading
        case failed(retry: () -> Void)
    }

    let state: State
    var density: TrayDensity = .regular
    var onTap: () -> Void = {}

    static let avatarSize: CGFloat = 64
    static let skeletonLabelWidth: CGFloat = 32
    static let skeletonLabelHeight: CGFloat = 8
    /// Char cap matches Instagram's tray treatment: long handles are cut
    /// flush rather than ending in an ellipsis. SwiftUI's `.tail` truncation
    /// always renders `…`, which reads as a visual artefact at 12pt —
    /// Instagram cuts mid-glyph instead. The cap is calibrated so the
    /// trimmed text always fits the layout width below, making the frame's
    /// own truncation a no-op.
    static let labelCharCap: Int = 10
    /// Sized so 10 chars of `usernameTray` (12pt medium) fit without the
    /// frame itself triggering tail truncation. Slightly wider than the
    /// avatar (64pt) on purpose — Instagram lets the label overflow the
    /// avatar a touch.
    static let labelMaxWidth: CGFloat = 80

    var body: some View {
        VStack(spacing: Spacing.s) {
            avatar
            label
                .frame(maxWidth: Self.labelMaxWidth)
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var avatar: some View {
        switch state {
        case .loaded(let user, let isFullySeen):
            StoryAvatar(
                url: user.avatarURL,
                initials: initials(from: user.username),
                ring: isFullySeen ? .seen : .unseen,
                size: Self.avatarSize
            )
        case .loading:
            StoryAvatar(url: nil, initials: "", ring: .loading, size: Self.avatarSize)
        case .failed:
            ZStack {
                Circle()
                    .fill(Color.surfaceElevated)
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                Image(systemName: "exclamationmark.triangle")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        switch state {
        case .loaded(let user, _):
            Text(Self.trimmedLabel(for: user.username))
                .font(.usernameTray)
                .tracking(-0.2)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        case .loading:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.surfaceElevated)
                .frame(width: Self.skeletonLabelWidth, height: Self.skeletonLabelHeight)
        case .failed:
            Text("Retry")
                .font(.usernameTray)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func handleTap() {
        switch state {
        case .loaded:           onTap()
        case .loading:          break
        case .failed(let retry): retry()
        }
    }

    static func trimmedLabel(for username: String) -> String {
        username.count > labelCharCap ? String(username.prefix(labelCharCap)) : username
    }

    private func initials(from username: String) -> String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: true)
        if parts.count >= 2, let secondInitial = parts[1].first {
            return "\(first)\(secondInitial)".uppercased()
        }
        return String(first).uppercased()
    }

    private var accessibilityLabel: String {
        switch state {
        case .loaded(let user, let seen):
            return "\(user.username), \(seen ? "viewed" : "new")"
        case .loading:           return "Loading story"
        case .failed:            return "Tap to retry"
        }
    }
}

#Preview("Tray states") {
    let alice = User(
        id: "alice", stableID: "alice", username: "alice.morgan",
        avatarURL: URL(string: "https://picsum.photos/seed/a/200/200")!
    )
    return HStack(spacing: TrayDensity.regular.itemSpacing) {
        StoryTrayItem(state: .loaded(user: alice, isFullySeen: false))
        StoryTrayItem(state: .loaded(user: alice, isFullySeen: true))
        StoryTrayItem(state: .loading)
        StoryTrayItem(state: .failed(retry: {}))
    }
    .padding(Spacing.l)
    .background(Color.background)
    .preferredColorScheme(.dark)
}

#Preview("Long username — flush cut, no ellipsis") {
    let long = User(
        id: "long", stableID: "long",
        username: "alexandre_duarte_official",
        avatarURL: URL(string: "https://picsum.photos/seed/long/200/200")!
    )
    let short = User(
        id: "short", stableID: "short", username: "ben",
        avatarURL: URL(string: "https://picsum.photos/seed/short/200/200")!
    )
    return HStack(spacing: TrayDensity.regular.itemSpacing) {
        StoryTrayItem(state: .loaded(user: long, isFullySeen: false))
        StoryTrayItem(state: .loaded(user: short, isFullySeen: false))
    }
    .padding(Spacing.l)
    .background(Color.background)
    .preferredColorScheme(.dark)
}
