import XCTest
@testable import MonitorCore

final class ReconnectBackoffTests: XCTestCase {
    func testDelaysDoubleUpToMaxThenStayCapped() {
        var backoff = ReconnectBackoff(initialDelay: 1, maxDelay: 30)

        let delays = (0..<8).map { _ in backoff.nextDelay() }

        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testCustomInitialDelayRespected() {
        var backoff = ReconnectBackoff(initialDelay: 3, maxDelay: 10)

        XCTAssertEqual(backoff.nextDelay(), 3)
        XCTAssertEqual(backoff.nextDelay(), 6)
        XCTAssertEqual(backoff.nextDelay(), 10)
    }

    func testResetReturnsToInitialDelay() {
        var backoff = ReconnectBackoff(initialDelay: 1, maxDelay: 30)
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()

        backoff.reset()

        XCTAssertEqual(backoff.attempt, 0)
        XCTAssertEqual(backoff.nextDelay(), 1)
    }
}
