import Foundation

/// Typed error surface for the data layer. Repositories never leak raw
/// `DecodingError` / `CocoaError` upward — they map into one of these.
nonisolated enum StoryError: Error, Sendable {
    case bundleResourceMissing(name: String)
    case decodingFailed(underlying: Error)
    case persistenceUnavailable(underlying: Error)
    case pageOutOfRange
}
