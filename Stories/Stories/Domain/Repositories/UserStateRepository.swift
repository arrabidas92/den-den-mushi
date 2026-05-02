import Foundation

/// Per-item seen/like state. `flushNow()` is the explicit drain hook —
/// callers invoke it on background/dismiss to coalesce any pending
/// debounced write before the app is suspended.
protocol UserStateRepository: Sendable {
    func markSeen(itemID: String) async
    func toggleLike(itemID: String) async -> Bool
    func isSeen(_ id: String) async -> Bool
    func isLiked(_ id: String) async -> Bool
    func flushNow() async
}
