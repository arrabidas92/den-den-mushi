import Foundation

/// Typed error surface for the data layer. Repositories never leak raw
/// `DecodingError` / `CocoaError` upward — they map into one of these.
nonisolated enum StoryError: LocalizedError, Sendable {
    case bundleResourceMissing(name: String)
    case decodingFailed(underlying: Error)
    case persistenceUnavailable(underlying: Error)
    case pageOutOfRange

    var errorDescription: String? {
        switch self {
        case .bundleResourceMissing(let name):
            return "Bundle resource missing: \(name)"
        case .decodingFailed(let underlying):
            return "Decoding failed: \(underlying.localizedDescription)"
        case .persistenceUnavailable(let underlying):
            return "Persistence unavailable: \(underlying.localizedDescription)"
        case .pageOutOfRange:
            return "Page index out of range"
        }
    }
}
