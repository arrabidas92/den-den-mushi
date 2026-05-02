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
}
