import XCTest
@testable import MonitorCore

final class FrameRateReporterTests: XCTestCase {
    func testReportsAtMostOncePerConfiguredIntervalWhileCountingEveryFrame() {
        var reporter = FrameRateReporter(reportingInterval: 0.25)

        XCTAssertEqual(reporter.recordFrame(at: Date(timeIntervalSince1970: 0)), 1)
        XCTAssertNil(reporter.recordFrame(at: Date(timeIntervalSince1970: 0.1)))
        XCTAssertNil(reporter.recordFrame(at: Date(timeIntervalSince1970: 0.2)))
        XCTAssertEqual(reporter.recordFrame(at: Date(timeIntervalSince1970: 0.3)), 4)
    }
}
