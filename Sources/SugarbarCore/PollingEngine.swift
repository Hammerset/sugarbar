import Foundation

/// Runs the poll loop: fetch, then sleep for the delay the planner picks from the
/// outcome — realigning to the reading clock on success, backing off on failure.
/// `start()`/`stop()` are how the app pauses on system sleep and resumes on wake.
public actor PollingEngine {
    public typealias Fetch = @Sendable () async -> PollOutcome

    private let planner: PollPlanner
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let fetch: Fetch

    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0

    public init(
        planner: PollPlanner = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        jitter: @escaping @Sendable () -> Double = { .random(in: 0...1) },
        fetch: @escaping Fetch
    ) {
        self.planner = planner
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
        self.fetch = fetch
    }

    public func start() {
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    func run() async {
        while !Task.isCancelled {
            let outcome = await fetch()
            switch outcome {
            case .success:
                consecutiveFailures = 0
            case .rateLimited, .transientFailure:
                consecutiveFailures += 1
            }
            let delay = nextDelay(
                after: outcome,
                now: now(),
                consecutiveFailures: consecutiveFailures,
                planner: planner,
                jitter: jitter()
            )
            do {
                try await sleep(delay)
            } catch {
                break
            }
        }
    }
}
