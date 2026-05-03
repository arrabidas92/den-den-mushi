import Foundation
import os
@testable import Stories

/// Minimal hand-rolled `Clock<Duration>` — replaces `swift-clocks` which
/// CLAUDE.md declines as a dependency. State lives behind an actor for
/// Swift 6 strict concurrency.
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
        // `Clock.now` is synchronous, so cache the offset outside the actor.
        Instant(offset: nowOffset.value)
    }

    private let nowOffset = AtomicDuration(.zero)
    private lazy var state = State(nowOffset: nowOffset)

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        try await state.suspendUntil(deadline)
    }

    /// Advances the clock and resumes every continuation whose deadline is
    /// now past, in deadline order. We step time fragment-by-fragment to
    /// the next pending deadline rather than bulk-bumping: a bulk advance
    /// would let freshly re-armed `clock.sleep`s land past the wall and
    /// only the first tick would release.
    func advance(by duration: Duration) async {
        // Drain so the controller's tick task reaches its first
        // `clock.sleep` and registers a pending continuation before we
        // move time.
        await drain()

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

    private func drain() async {
        for _ in 0..<8 { await Task.yield() }
    }

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

        func dueContinuations() -> [CheckedContinuation<Void, Error>] {
            let cutoff = currentOffset
            let due = pending
                .filter { $0.deadline.offset <= cutoff }
                .sorted { $0.deadline.offset < $1.deadline.offset }
            pending.removeAll { $0.deadline.offset <= cutoff }
            return due.map(\.cont)
        }

        func nextDeadlineNotAfter(_ cap: Duration) -> Duration? {
            pending.map(\.deadline.offset)
                .filter { $0 <= cap }
                .min()
        }
    }
}
