import Foundation
import os

/// On-disk `UserStateRepository`. Mutations land in memory immediately and
/// are flushed via a 500 ms debounced task — bursts coalesce into one disk
/// write. `flushNow()` is the explicit drain called on dismiss/background.
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

    /// `~/Library/Application Support/Stories/state.json`, excluded from
    /// iCloud backup (state is reproducible).
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
        // The task we came from may have been cancelled and replaced during
        // the sleep — only proceed if we're still the current pending task.
        guard pendingFlush?.isCancelled == false else { return }
        pendingFlush = nil
        flushSynchronously()
    }

    private func flushSynchronously() {
        let snapshot = state
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Self.log.error("Flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Missing → empty state. Corrupt → delete + empty state. Unreadable →
    /// empty state with logged error.
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
