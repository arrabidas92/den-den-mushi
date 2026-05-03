import Foundation
import os

extension Logger {

    private static let subsystem = Bundle.main.bundleIdentifier ?? "Stories"

    static let app = Logger(subsystem: subsystem, category: "app")
}
