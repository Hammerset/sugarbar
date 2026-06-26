import Foundation
import Testing

@testable import SugarbarCore

/// Drives the engine deterministically: hands out scripted outcomes, records each
/// scheduled delay instead of sleeping, and cancels the loop once the script is spent.
private actor FakePoller {
    private var outcomes: [PollOutcome]
    private(set) var delays: [TimeInterval] = []

    init(_ outcomes: [PollOutcome]) { self.outcomes = outcomes }

    func next() -> PollOutcome { outcomes.removeFirst() }

    func record(_ delay: TimeInterval) throws {
        delays.append(delay)
        if outcomes.isEmpty { throw CancellationError() }
    }
}

@Suite struct PollingEngineTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func engine(_ poller: FakePoller) -> PollingEngine {
        let now = now
        return PollingEngine(
            planner: .standard,
            now: { now },
            sleep: { try await poller.record($0) },
            jitter: { 1 },
            fetch: { await poller.next() }
        )
    }

    @Test func pollsThenSchedulesAlignedDelayAfterSuccess() async {
        let poller = FakePoller([.success(readingAt: now.addingTimeInterval(-5))])
        await engine(poller).run()
        #expect(await poller.delays == [60])
    }

    @Test func backsOffWithGrowingDelaysWhileRateLimited() async {
        let poller = FakePoller([.rateLimited, .rateLimited, .rateLimited])
        await engine(poller).run()
        #expect(await poller.delays == [30, 60, 120])
    }

    @Test func resetsTheFailureCountAfterASuccess() async {
        let poller = FakePoller([
            .rateLimited,
            .rateLimited,
            .success(readingAt: now.addingTimeInterval(-5)),
            .rateLimited,
        ])
        await engine(poller).run()
        #expect(await poller.delays == [30, 60, 60, 30])
    }
}
