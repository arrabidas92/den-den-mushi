import Foundation
import Observation

/// Drives the 0...1 progress of the *current* story item. Knows nothing
/// about which item is current, who the user is, or how to dismiss —
/// that's `ViewerStateModel`'s job. The split keeps the timer testable
/// in isolation against an injected `Clock<Duration>`.
///
/// MainActor isolation is inherited from the module default; the tick
/// task launched by `start()` therefore mutates `progress` on the main
/// actor without explicit hops.
@Observable
final class PlaybackController {

    /// Linear 0...1 progress of the current item. Bound by the View to
    /// the segmented progress bar. Resets to 0 on `start()` and `reset()`.
    private(set) var progress: Double = 0

    /// True while the tick loop is sleeping without advancing `progress`.
    /// The flag is owned here; callers (gestures, scenePhase) flip it
    /// through `pause()` / `resume()` and never cancel the underlying task.
    private(set) var isPaused = false

    /// Fired exactly once per item, when `progress` first reaches 1.0.
    /// Wired by `ViewerStateModel` to `nextItem()`.
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

    // No `deinit` cancels `task` directly — under Swift 6 strict mode the
    // MainActor-isolated property cannot be touched from a nonisolated
    // deinit. The tick loop captures `[weak self]` (see `start()`), so a
    // deallocated controller stops advancing on its very next tick when
    // `self?.runLoop()` resolves to `nil`. Callers that need an immediate
    // teardown (the viewer dismiss path) must invoke `stop()` explicitly.

    // MARK: - Lifecycle

    /// Cancels any in-flight tick loop, resets `progress` to 0, and starts
    /// a fresh loop. Called by `ViewerStateModel` on every item change.
    func start() {
        task?.cancel()
        progress = 0
        isPaused = false
        didFireEnd = false
        task = Task { [weak self] in await self?.runLoop() }
    }

    /// Halts advancement. The tick task keeps running and sleeping —
    /// resume picks up from the same `progress` without rebuilding state.
    func pause() {
        isPaused = true
    }

    /// Re-enables advancement after `pause()`.
    func resume() {
        isPaused = false
    }

    /// Returns `progress` to 0 without touching the running task.
    /// `start()` already covers most callers; `reset()` is reserved for
    /// the failure-frame retry path that wants to rewind without
    /// restarting the timer (the View may want to keep the loop paused).
    func reset() {
        progress = 0
        didFireEnd = false
    }

    /// Cancels the tick loop. Called by `ViewerStateModel` on dismiss
    /// and on deinit (latter is implicit via the deinit of `task`).
    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Tick loop

    private func runLoop() async {
        // Each tick contributes `tickInterval / itemDuration` of progress
        // when not paused. Multiplying durations as fractions keeps the
        // tickInterval a tunable knob without rewriting the loop.
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
                // Stay in the loop: ViewerStateModel typically calls
                // `start()` from inside `onItemEnd`, which cancels us.
            }
        }
    }
}

private extension Duration {

    /// Ratio of two durations as a `Double`. Both sides are reduced to
    /// the same attoseconds-scale `components` representation, so the
    /// ratio is exact for any tickInterval / itemDuration we use.
    static func / (lhs: Duration, rhs: Duration) -> Double {
        let lhsTotal = Double(lhs.components.seconds) + Double(lhs.components.attoseconds) / 1e18
        let rhsTotal = Double(rhs.components.seconds) + Double(rhs.components.attoseconds) / 1e18
        return lhsTotal / rhsTotal
    }
}
