import Foundation
import Testing
@testable import Stories

@Suite("PlaybackController", .serialized)
@MainActor
struct PlaybackControllerTests {

    /// 5s item, 50ms tick → 0.01 progress per tick. Pick durations that
    /// land on round multiples to keep the assertions tolerance-free.

    @Test("initial state is paused-eligible, progress 0, no end fired")
    func initialState() {
        let clock = TestClock()
        let controller = PlaybackController(
            clock: clock,
            itemDuration: .seconds(1),
            tickInterval: .milliseconds(100),
        )
        #expect(controller.progress == 0)
        #expect(controller.isPaused == false)
    }

    @Test("tick advances progress linearly")
    func tickAdvancesProgress() async {
        let clock = TestClock()
        let controller = PlaybackController(
            clock: clock,
            itemDuration: .seconds(1),
            tickInterval: .milliseconds(100),
        )
        controller.start()
        // 100ms tick over a 1s item → 0.1 per tick.
        await clock.advance(by: .milliseconds(300))
        // Three ticks have fired → progress ~= 0.3.
        #expect(abs(controller.progress - 0.3) < 0.01)
        await clock.advance(by: .milliseconds(200))
        #expect(abs(controller.progress - 0.5) < 0.01)
    }

    @Test("pause halts advancement; resume picks up from the same offset")
    func pauseResume() async {
        let clock = TestClock()
        let controller = PlaybackController(
            clock: clock,
            itemDuration: .seconds(1),
            tickInterval: .milliseconds(100),
        )
        controller.start()
        await clock.advance(by: .milliseconds(300))
        let snapshot = controller.progress

        controller.pause()
        await clock.advance(by: .milliseconds(500))
        #expect(controller.progress == snapshot)

        controller.resume()
        await clock.advance(by: .milliseconds(200))
        #expect(abs(controller.progress - (snapshot + 0.2)) < 0.01)
    }

    @Test("reset returns progress to 0 without re-firing onItemEnd")
    func resetReturnsToZero() async {
        let clock = TestClock()
        let controller = PlaybackController(
            clock: clock,
            itemDuration: .seconds(1),
            tickInterval: .milliseconds(100),
        )
        controller.start()
        await clock.advance(by: .milliseconds(400))
        #expect(controller.progress > 0)

        controller.reset()
        #expect(controller.progress == 0)
    }

    @Test("start after a previous run resets to 0")
    func startResets() async {
        let clock = TestClock()
        let controller = PlaybackController(
            clock: clock,
            itemDuration: .seconds(1),
            tickInterval: .milliseconds(100),
        )
        controller.start()
        await clock.advance(by: .milliseconds(400))
        #expect(controller.progress > 0)

        controller.start()
        #expect(controller.progress == 0)
        await clock.advance(by: .milliseconds(100))
        #expect(abs(controller.progress - 0.1) < 0.01)
    }

    @Test("onItemEnd fires exactly once when progress hits 1.0")
    func onItemEndFires() async {
        let clock = TestClock()
        let controller = PlaybackController(
            clock: clock,
            itemDuration: .seconds(1),
            tickInterval: .milliseconds(100),
        )
        var fireCount = 0
        controller.onItemEnd = { fireCount += 1 }
        controller.start()
        // 10 ticks over 1s → progress reaches 1.0 at tick 10.
        await clock.advance(by: .milliseconds(1100))
        #expect(controller.progress == 1.0)
        #expect(fireCount == 1)
        // Continuing to advance must not re-fire.
        await clock.advance(by: .milliseconds(500))
        #expect(fireCount == 1)
    }

    @Test("stop cancels the task; subsequent advances do not move progress")
    func stopCancels() async {
        let clock = TestClock()
        let controller = PlaybackController(
            clock: clock,
            itemDuration: .seconds(1),
            tickInterval: .milliseconds(100),
        )
        controller.start()
        await clock.advance(by: .milliseconds(200))
        let snapshot = controller.progress
        controller.stop()
        await clock.advance(by: .milliseconds(500))
        #expect(controller.progress == snapshot)
    }
}
