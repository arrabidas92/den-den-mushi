import SwiftUI
import os

/// Composition root. Holds the root `StoryListViewModel` as an optional
/// `@State`: hydration is `async throws` (the persisted store reads from
/// `Application Support`), so we cannot construct the ViewModel from
/// `App.init`. The `.task` on the root View hydrates it; until ready, a
/// skeleton tray (shimmering rings) stands in, so the bootstrap surface
/// matches the in-app loading affordance instead of flashing a generic
/// spinner for ~3 frames.
///
/// Fallback chain: if `PersistedUserStateStore` cannot initialise (rare —
/// filesystem unavailable, bundle resource missing), the bootstrap drops
/// to `EphemeralUserStateStore` so the app still launches. The persisted
/// file is never rewritten by the ephemeral fallback; the current session
/// loses durability, future sessions retry.
@main
struct StoriesApp: App {

    @State private var listViewModel: StoryListViewModel?
    @State private var bootstrapError: StoryError?
    /// One monitor per app instance. Injected through Environment so any
    /// view can react to connectivity changes without plumbing a parameter
    /// through every layer. Currently consumed by `StoryViewerPage` for
    /// auto-retry on network return.
    @State private var networkMonitor = NetworkMonitor()

    init() {
        ImageLoader.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let vm = listViewModel {
                    StoryListView(viewModel: vm)
                } else if let error = bootstrapError {
                    bootstrapErrorView(error)
                } else {
                    BootstrapSkeletonView()
                }
            }
            .preferredColorScheme(.dark)
            .environment(networkMonitor)
            .task {
                guard listViewModel == nil, bootstrapError == nil else { return }
                await bootstrap()
            }
        }
    }

    // MARK: - Bootstrap

    @MainActor
    private func bootstrap() async {
        let storyRepo: LocalStoryRepository
        do {
            storyRepo = try LocalStoryRepository()
        } catch let error as StoryError {
            Logger.app.error("Story repo init failed: \(String(describing: error), privacy: .public)")
            bootstrapError = error
            return
        } catch {
            Logger.app.error("Story repo init failed: \(error.localizedDescription, privacy: .public)")
            bootstrapError = .persistenceUnavailable(underlying: error)
            return
        }

        let stateStore: any UserStateRepository
        do {
            stateStore = try await PersistedUserStateStore.makeInApplicationSupport()
        } catch {
            Logger.app.error("State store init failed, falling back to ephemeral: \(error.localizedDescription, privacy: .public)")
            stateStore = EphemeralUserStateStore()
        }

        listViewModel = StoryListViewModel(
            storyRepository: storyRepo,
            userStateRepository: stateStore,
            prefetcher: ImagePrefetchHandle(),
        )
    }

    // MARK: - Bootstrap error fallback

    /// Only rendered when the *story* repository fails — i.e. the bundled
    /// JSON is missing or malformed. The state store has its own fallback
    /// (`EphemeralUserStateStore`) and never reaches this surface.
    private func bootstrapErrorView(_ error: StoryError) -> some View {
        ZStack {
            Color.background.ignoresSafeArea()
            VStack(spacing: Spacing.m) {
                Image(systemName: "exclamationmark.triangle")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(Color.textTertiary)
                Text("Couldn't load stories")
                    .font(.body15)
                    .foregroundStyle(Color.textSecondary)
                Button {
                    bootstrapError = nil
                    Task { await bootstrap() }
                } label: {
                    Text("Retry")
                        .font(.body15)
                        .foregroundStyle(Color.textPrimary.opacity(0.7))
                        .frame(minWidth: 88, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry loading stories")
            }
        }
    }
}

// MARK: - Bootstrap skeleton

/// Shown while the persisted store hydrates. Mirrors the tray skeleton
/// inside `StoryListView` (8 shimmering rings) so the bootstrap surface
/// is visually continuous with the first loaded frame — no spinner, no
/// snap. The cells are non-interactive: tapping a placeholder is a no-op.
private struct BootstrapSkeletonView: View {

    @Environment(\.trayDensity) private var density
    private static let skeletonCount = 8

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: density.itemSpacing) {
                    ForEach(0..<Self.skeletonCount, id: \.self) { _ in
                        StoryTrayItem(state: .loading, density: density)
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
            }
            .scrollDisabled(true)
            .frame(height: StoryTrayItem.avatarSize + 2 * Spacing.m + Spacing.s + 16)
            Divider()
                .background(Color.surfaceElevated.opacity(0.4))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.background)
    }
}
