import SwiftUI

/// Bootstrap loading state — shown while the composition root awaits
/// `PersistedUserStateStore.makeInApplicationSupport`. Hydration takes
/// <50ms in practice, so the View is here for correctness, not as a
/// designed surface; a logo or copy would flash for ~3 frames and read
/// as a glitch (see `design.md` § *Loading & empty states*).
struct LoadingView: View {

    var body: some View {
        ZStack {
            Color.background.ignoresSafeArea()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color.textPrimary)
                .scaleEffect(1.2)
        }
    }
}

#Preview {
    LoadingView()
        .preferredColorScheme(.dark)
}
