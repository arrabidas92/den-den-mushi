import Foundation
import os
@testable import Stories

/// Minimal hand-rolled `Clock<Duration>` for the test target. Replaces
/// `swift-clocks` (declined as a dependency in CLAUDE.md).
///
/// Usage:
/// ```swift
/// let clock = TestClock()
/// let controller = PlaybackController(clock: clock, itemDuration: .seconds(5))
/// controller.start()
/// await clock.advance(by: .seconds(1))   // progress ~= 0.2
/// ```
///
/// State lives behind an actor to satisfy Swift 6 strict concurrency
/// without locks; the public methods route through it.
final class TestClock: Clock, @unchecked Sendable {

    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var minimumResolution: Duration { .zero }
    var now: Instant {
        // `Clock.now` is synchronous on the protocol. Cache the latest
        // offset alongside the actor so reads do not need to await — the
        // value is updated in lockstep with `advance(by:)`.
        Instant(offset: nowOffset.value)
    }

    private let nowOffset = AtomicDuration(.zero)
    private lazy var state = State(nowOffset: nowOffset)

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        try await state.suspendUntil(deadline)
    }

    /// Advances the clock by `duration` and resumes every continuation
    /// whose deadline is now in the past, in deadline order. After each
    /// resume we yield repeatedly so the resumed code (which typically
    /// re-arms another `sleep`) reaches its next suspension point before
    /// we continue. The yield count is empirically generous — Swift
    /// Testing parallelism otherwise lets unrelated tasks interleave on
    /// the main actor and wins races against the runloop draining.
    func advance(by duration: Duration) async {
        // Drain first: callers typically `start()` a controller and
        // immediately `advance(...)`, but the controller's tick task
        // hasn't run yet — its body is queued on the main actor. Yield
        // so it reaches its first `clock.sleep` and registers a pending
        // continuation before we move time forward.
        await drain()

        // Step time forward in fragments aligned to the next pending
        // deadline. A bulk `nowOffset.add(duration)` would cause every
        // freshly re-armed `clock.sleep(for: tickInterval)` (which
        // anchors its deadline at `now + tickInterval`) to land past
        // the wall — so a single advance would release only one tick
        // and the rest would be born "in the future" relative to a
        // now-already-bumped clock. Walking the timeline preserves the
        // invariant that `now` ratchets forward in lockstep with each
        // released waiter.
        let target = nowOffset.value + duration
        while let nextDeadline = await state.nextDeadlineNotAfter(target) {
            nowOffset.set(nextDeadline)
            let due = await state.dueContinuations()
            for cont in due {
                cont.resume()
                await drain()
            }
        }
        nowOffset.set(target)
        await drain()
    }

    /// Performs enough cooperative yields that any task resumed by
    /// `advance(by:)` has time to run its body up to its next suspension.
    private func drain() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// Tiny wrapper so `now` (a synchronous protocol requirement) can
    /// read the current offset without hopping to the actor. Mutations
    /// happen only inside `advance(by:)`, which already serialises them.
    final class AtomicDuration: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<Duration>(initialState: .zero)
        init(_ initial: Duration) { lock.withLock { $0 = initial } }
        var value: Duration { lock.withLock { $0 } }
        func add(_ delta: Duration) { lock.withLock { $0 = $0 + delta } }
        func set(_ value: Duration) { lock.withLock { $0 = value } }
    }

    private actor State {

        private struct Pending {
            let deadline: Instant
            let cont: CheckedContinuation<Void, Error>
        }

        private let nowOffset: AtomicDuration
        private var pending: [Pending] = []

        init(nowOffset: AtomicDuration) { self.nowOffset = nowOffset }

        private var currentOffset: Duration { nowOffset.value }

        func suspendUntil(_ deadline: Instant) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if deadline.offset <= currentOffset {
                    cont.resume()
                    return
                }
                pending.append(Pending(deadline: deadline, cont: cont))
            }
        }

        /// Removes and returns every continuation whose deadline is
        /// in the past relative to the *current* `nowOffset`, in deadline
        /// order. Caller is responsible for resuming them.
        func dueContinuations() -> [CheckedContinuation<Void, Error>] {
            let cutoff = currentOffset
            let due = pending
                .filter { $0.deadline.offset <= cutoff }
                .sorted { $0.deadline.offset < $1.deadline.offset }
            pending.removeAll { $0.deadline.offset <= cutoff }
            return due.map(\.cont)
        }

        /// Returns the earliest pending deadline whose offset is `<= cap`,
        /// or `nil` if no such deadline exists. `advance(by:)` uses this
        /// to walk the timeline tick-by-tick.
        func nextDeadlineNotAfter(_ cap: Duration) -> Duration? {
            pending.map(\.deadline.offset)
                .filter { $0 <= cap }
                .min()
        }
    }
}
