import Foundation
import os

/// On-disk `UserStateRepository`. Mutations land in memory immediately and
/// are flushed to the JSON file via a 500 ms debounced `Task` per turn.
/// Bursts (e.g. five `markSeen` calls during a binge-watch) coalesce into
/// a single disk write. `flushNow()` is the explicit drain hook called
/// from `.onDisappear` and `.background` to bound state loss on suspend.
actor PersistedUserStateStore: UserStateRepository {

    private nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Stories",
        category: "persistence"
    )

    private var state: UserState
    private let fileURL: URL
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private var pendingFlush: Task<Void, Never>?

    init(
        fileURL: URL,
        clock: any Clock<Duration> = ContinuousClock(),
        debounce: Duration = .milliseconds(500)
    ) async throws {
        self.fileURL = fileURL
        self.clock = clock
        self.debounce = debounce
        self.state = Self.loadOrRecover(at: fileURL)
    }

    /// Default-location convenience init.
    /// `~/Library/Application Support/Stories/state.json`, with the file
    /// excluded from iCloud backup (state is reproducible — re-syncing it
    /// would waste bandwidth).
    static func makeInApplicationSupport(
        clock: any Clock<Duration> = ContinuousClock(),
        debounce: Duration = .milliseconds(500)
    ) async throws -> PersistedUserStateStore {
        let fm = FileManager.default
        let appSupport: URL
        do {
            appSupport = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw StoryError.persistenceUnavailable(underlying: error)
        }
        let dir = appSupport.appendingPathComponent("Stories", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw StoryError.persistenceUnavailable(underlying: error)
        }
        var fileURL = dir.appendingPathComponent("state.json", isDirectory: false)
        // Mark excluded-from-backup once on the parent dir; new files inherit.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? fileURL.setResourceValues(values)
        return try await PersistedUserStateStore(fileURL: fileURL, clock: clock, debounce: debounce)
    }

    // MARK: - UserStateRepository

    func markSeen(itemID: String) async {
        state.seenItemIDs.insert(itemID)
        scheduleFlush()
    }

    func toggleLike(itemID: String) async -> Bool {
        let now = !state.likedItemIDs.contains(itemID)
        if now {
            state.likedItemIDs.insert(itemID)
        } else {
            state.likedItemIDs.remove(itemID)
        }
        scheduleFlush()
        return now
    }

    func isSeen(_ id: String) async -> Bool {
        state.seenItemIDs.contains(id)
    }

    func isLiked(_ id: String) async -> Bool {
        state.likedItemIDs.contains(id)
    }

    /// Cancels any pending debounced flush and writes synchronously.
    /// Idempotent — calling on an unchanged store is a cheap no-op write.
    func flushNow() async {
        pendingFlush?.cancel()
        pendingFlush = nil
        flushSynchronously()
    }

    // MARK: - Internals

    private func scheduleFlush() {
        pendingFlush?.cancel()
        let clock = self.clock
        let debounce = self.debounce
        pendingFlush = Task { [weak self] in
            try? await clock.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.flushSynchronouslyIfStillPending()
        }
    }

    private func flushSynchronouslyIfStillPending() {
        // Re-entered after the sleep on the actor's executor. The Task we
        // came from may have been cancelled and replaced — only proceed if
        // we are still the current pending task.
        guard pendingFlush?.isCancelled == false else { return }
        pendingFlush = nil
        flushSynchronously()
    }

    private func flushSynchronously() {
        // Snapshot + write in a single actor turn — no `await` between them.
        // Mutations queued mid-flush wait their turn cleanly, no partial-state
        // window observable on disk.
        let snapshot = state
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Self.log.error("Flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads the file at `fileURL` and returns the parsed state.
    /// - Missing file → empty state (first launch).
    /// - Corrupt file → log, delete, return empty state.
    /// - Unreadable file (permission etc.) → empty state with a logged error.
    private nonisolated static func loadOrRecover(at fileURL: URL) -> UserState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return .empty }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            log.error("Read failed: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
        do {
            return try JSONDecoder().decode(UserState.self, from: data)
        } catch {
            log.error("State file corrupt, deleting: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: fileURL)
            return .empty
        }
    }
}
