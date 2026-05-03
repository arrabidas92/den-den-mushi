import Foundation
import os

nonisolated extension Logger {

    /// Hardcoded so test runs (whose bundle identifier is `xctest`-flavoured)
    /// log under the same subsystem as the app, keeping `os_log`/Console
    /// filters consistent across host bundles.
    private static let subsystem = "dendenmushi.Stories"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
