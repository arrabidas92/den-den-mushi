import Foundation
import Network
import Observation

/// Live connectivity flag for SwiftUI. Used by `StoryViewerPage` and
/// `StoryAvatar` to auto-retry failed images when the network comes back.
/// Hops to the main actor before mutating `isOnline` so View bodies can
/// read it synchronously.
@MainActor
@Observable
final class NetworkMonitor {

    private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.stories.networkmonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
