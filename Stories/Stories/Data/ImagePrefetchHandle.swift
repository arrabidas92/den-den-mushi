import Foundation
import Nuke

/// Screen-scoped prefetch lifetime. `@MainActor` matches Nuke 12's
/// annotation on `ImagePrefetcher`.
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
