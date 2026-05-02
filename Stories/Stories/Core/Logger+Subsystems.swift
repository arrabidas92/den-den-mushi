import Foundation
import os

/// One logger per subsystem so console-filtering stays useful — `app`,
/// `viewer`, `list`, `persistence`, `images` are the five categories the
/// codebase emits into. The subsystem is derived from the bundle id
/// (e.g. `com.<candidate>.Stories`) at runtime so it tracks the
/// signing identity rather than hard-coding a namespace.
extension Logger {

    private static let subsystem = Bundle.main.bundleIdentifier ?? "Stories"

    /// Composition root and lifecycle (bootstrap, scenePhase).
    static let app         = Logger(subsystem: subsystem, category: "app")

    /// Viewer state transitions (item start, like, dismiss, gesture).
    static let viewer      = Logger(subsystem: subsystem, category: "viewer")

    /// Tray and pagination — load events, retry paths.
    static let list        = Logger(subsystem: subsystem, category: "list")

    /// Persistence (PersistedUserStateStore). Already used inside the
    /// store via a private logger; the public token mirrors it so other
    /// callers can route events to the same category.
    static let persistence = Logger(subsystem: subsystem, category: "persistence")

    /// Image loading (Nuke configuration, prefetch lifecycle).
    static let images      = Logger(subsystem: subsystem, category: "images")
}
