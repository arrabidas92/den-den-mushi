import SwiftUI

/// Top chrome of the viewer: small avatar (no ring), username, relative
/// timestamp, close button. Pure layout — the close action is injected so
/// the parent can decide whether it dismisses, pauses, or triggers a
/// custom transition.
///
/// Avatar deliberately omits the ring: inside the viewer the user has
/// already entered the story, so the seen-state ring is no longer the
/// signal that matters. Keeping the chrome quiet matches Instagram's
/// header treatment.
struct StoryViewerHeader: View {

    let user: User
    let timestamp: Date
    let onClose: () -> Void

    /// Used by tests and previews so the relative formatter stays
    /// deterministic. Production passes `Date()`.
    var now: Date = Date()

    static let height: CGFloat = 56
    private static let avatarSize: CGFloat = 32
    private static let closeIconSize: CGFloat = 24
    private static let closeTouchTarget: CGFloat = 44

    var body: some View {
        HStack(spacing: Spacing.m) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(user.username)
                    .font(.usernameHeader)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.relativeTimestamp(from: timestamp, now: now))
                    .font(.timestamp)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            closeButton
        }
        .padding(.horizontal, Spacing.l)
        .frame(height: Self.height)
    }

    private var avatar: some View {
        StoryAvatar(
            url: user.avatarURL,
            initials: Self.initials(for: user.username),
            ring: .seen,
            size: Self.avatarSize,
        )
        .accessibilityHidden(true)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.closeIconSize, height: Self.closeIconSize)
                .foregroundStyle(Color.textPrimary)
                .frame(width: Self.closeTouchTarget, height: Self.closeTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .accessibilityAddTraits(.isButton)
    }

    static func initials(for username: String) -> String {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "?" }
        return String(trimmed.prefix(2)).uppercased()
    }

    /// Compact relative formatter: "now", "12m", "3h", "2d", "5w". The
    /// system `RelativeDateTimeFormatter` is too verbose ("2 days ago")
    /// for a 13pt timestamp slot — this matches Instagram's compact form.
    static func relativeTimestamp(from date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        switch elapsed {
        case ..<60:           return "now"
        case ..<3_600:        return "\(Int(elapsed / 60))m"
        case ..<86_400:       return "\(Int(elapsed / 3_600))h"
        case ..<604_800:      return "\(Int(elapsed / 86_400))d"
        default:              return "\(Int(elapsed / 604_800))w"
        }
    }
}

// MARK: - Previews

#Preview("Recent + old timestamps") {
    let user = User(
        id: "alice",
        stableID: "alice",
        username: "alice.demo",
        avatarURL: URL(string: "https://picsum.photos/seed/alice/200/200")!,
    )
    let now = Date()
    return VStack(spacing: Spacing.l) {
        StoryViewerHeader(user: user, timestamp: now.addingTimeInterval(-30), onClose: {}, now: now)
        StoryViewerHeader(user: user, timestamp: now.addingTimeInterval(-12 * 60), onClose: {}, now: now)
        StoryViewerHeader(user: user, timestamp: now.addingTimeInterval(-3 * 3_600), onClose: {}, now: now)
        StoryViewerHeader(user: user, timestamp: now.addingTimeInterval(-2 * 86_400), onClose: {}, now: now)
        StoryViewerHeader(user: user, timestamp: now.addingTimeInterval(-5 * 604_800), onClose: {}, now: now)
    }
    .padding(.vertical, Spacing.l)
    .frame(maxWidth: .infinity)
    .background(Color.background)
    .preferredColorScheme(.dark)
}

#Preview("Long username truncates") {
    let user = User(
        id: "long",
        stableID: "long",
        username: "this.is.a.very.long.username.that.should.truncate",
        avatarURL: URL(string: "https://picsum.photos/seed/long/200/200")!,
    )
    return StoryViewerHeader(user: user, timestamp: Date(), onClose: {})
        .frame(width: 320)
        .background(Color.background)
        .preferredColorScheme(.dark)
}
