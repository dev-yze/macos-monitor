import XCTest
@testable import MonitorCore

final class FramesPerSecondCounterTests: XCTestCase {
    func testReportsFramesReceivedDuringTrailingOneSecondWindow() {
        var counter = FramesPerSecondCounter()
        counter.recordFrame(at: Date(timeIntervalSince1970: 0))
        counter.recordFrame(at: Date(timeIntervalSince1970: 0.3))
        counter.recordFrame(at: Date(timeIntervalSince1970: 0.7))

        XCTAssertEqual(counter.framesPerSecond(at: Date(timeIntervalSince1970: 0.8)), 3)
        XCTAssertEqual(counter.framesPerSecond(at: Date(timeIntervalSince1970: 1.1)), 2)
    }
}
