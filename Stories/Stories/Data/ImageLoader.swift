import Foundation
import Nuke

/// One-shot Nuke pipeline configuration, called from the composition root
/// before any `LazyImage` is rendered.
enum ImageLoader {

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

    /// Drops memory + disk cache entries for `url`. Called by the
    /// failure-frame Retry path — without it, Nuke's cached failure
    /// short-circuits the next request regardless of network state.
    static func invalidate(_ url: URL) {
        let request = ImageRequest(url: url)
        ImagePipeline.shared.cache.removeCachedImage(for: request)
        ImagePipeline.shared.cache.removeCachedData(for: request)
    }
}
