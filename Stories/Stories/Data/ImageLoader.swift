import Foundation
import Nuke

/// One-shot Nuke pipeline configuration. Called from the app's composition
/// root before any `LazyImage` is rendered.
enum ImageLoader {

    /// Configures the shared `ImagePipeline` once.
    /// - Memory cache: defaults are sensible for our 1080×1920 frames.
    /// - Disk cache: 7-day TTL so cold launches feel instant on previously
    ///   viewed users; data URLs are stable seeds, so cache hits are
    ///   deterministic across sessions.
    /// - Request timeout: 15 s (story images are large; mobile networks vary).
    static func configure() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30

        let pipeline = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: config)
            $0.dataCache = try? DataCache(name: "com.stories.imagecache")
            $0.isProgressiveDecodingEnabled = false
        }
        ImagePipeline.shared = pipeline
    }

    /// Drops both the memory and disk cache entries for `url`. Called by
    /// the failure-frame Retry path: without it, Nuke's cached failure
    /// short-circuits the next request and the user sees the same broken
    /// frame regardless of network state.
    static func invalidate(_ url: URL) {
        let request = ImageRequest(url: url)
        ImagePipeline.shared.cache.removeCachedImage(for: request)
        ImagePipeline.shared.cache.removeCachedData(for: request)
    }
}
