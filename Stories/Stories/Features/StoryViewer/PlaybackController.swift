import Foundation
import Observation

/// Drives the 0...1 progress of the current story item. The split from
/// `ViewerStateModel` keeps the timer testable in isolation against an
/// injected `Clock<Duration>`.
@Observable
final class PlaybackController {

    private(set) var progress: Double = 0

    private(set) var isPaused = false

    /// Fired exactly once per item, when `progress` first reaches 1.0.
    var onItemEnd: (() -> Void)?

    private let clock: any Clock<Duration>
    private let itemDuration: Duration
    private let tickInterval: Duration
    private var task: Task<Void, Never>?
    private var didFireEnd = false

    init(
        clock: any Clock<Duration> = ContinuousClock(),
        itemDuration: Duration = .seconds(7),
        tickInterval: Duration = .milliseconds(50),
    ) {
        self.clock = clock
        self.itemDuration = itemDuration
        self.tickInterval = tickInterval
    }

    // Under Swift 6 strict mode a nonisolated deinit cannot touch the
    // MainActor-isolated `task`. The tick loop captures `[weak self]`, so a
    // deallocated controller stops advancing on its next tick. Callers that
    // need immediate teardown must invoke `stop()`.

    // MARK: - Lifecycle

    func start() {
        task?.cancel()
        progress = 0
        isPaused = false
        didFireEnd = false
        task = Task { [weak self] in await self?.runLoop() }
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    /// Rewinds without restarting the tick loop (used by the failure-frame
    /// retry path which wants to keep the loop paused).
    func reset() {
        progress = 0
        didFireEnd = false
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Tick loop

    private func runLoop() async {
        let progressPerTick = tickInterval / itemDuration

        while !Task.isCancelled {
            do {
                try await clock.sleep(for: tickInterval)
            } catch {
                return
            }
            try? Task.checkCancellation()
            if Task.isCancelled { return }
            guard !isPaused else { continue }
            let next = min(1.0, progress + progressPerTick)
            progress = next
            if next >= 1.0, !didFireEnd {
                didFireEnd = true
                onItemEnd?()
            }
        }
    }
}

private extension Duration {

    static func / (lhs: Duration, rhs: Duration) -> Double {
        let lhsTotal = Double(lhs.components.seconds) + Double(lhs.components.attoseconds) / 1e18
        let rhsTotal = Double(rhs.components.seconds) + Double(rhs.components.attoseconds) / 1e18
        return lhsTotal / rhsTotal
    }
}
