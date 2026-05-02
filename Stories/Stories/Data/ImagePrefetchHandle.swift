import Foundation
import Nuke

/// Screen-scoped prefetch lifetime. Owned by `StoryListViewModel` and
/// `ViewerStateModel`; cancelled implicitly by Nuke when deallocated.
///
/// `@MainActor` matches Nuke 12's annotation on `ImagePrefetcher` and
/// keeps callers honest — ViewModels are already `@MainActor`, so usage
/// crosses no actor hops.
@MainActor
final class ImagePrefetchHandle {

    private let prefetcher = ImagePrefetcher()

    func prefetch(_ urls: [URL]) {
        prefetcher.startPrefetching(with: urls)
    }

    func cancel() {
        prefetcher.stopPrefetching()
    }
}
