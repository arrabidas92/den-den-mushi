import Foundation
import Network
import Observation

/// Live connectivity flag, published on the main actor for SwiftUI
/// observation. Used by `StoryViewerPage` to auto-retry a failed image
/// the moment the network comes back — Instagram's pattern: don't make
/// the user tap Retry on every story when their flight Wi-Fi finally
/// connects.
///
/// `NWPathMonitor` callbacks fire on a background queue; we hop to the
/// main actor before mutating `isOnline` so SwiftUI's Observation tracking
/// stays on its expected actor and the property can be read synchronously
/// from `View.body`.
@MainActor
@Observable
final class NetworkMonitor {

    private(set) var isOnline = true

    nonisolated(unsafe) private let monitor = NWPathMonitor()
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
