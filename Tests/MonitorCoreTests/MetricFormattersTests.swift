import XCTest
@testable import MonitorCore

final class MetricFormattersTests: XCTestCase {
    func testFormatsWatts() {
        XCTAssertEqual(MetricFormatters.watts(18.24), "18.2 W")
        XCTAssertEqual(MetricFormatters.watts(nil), "-- W")
    }

    func testFormatsCelsius() {
        XCTAssertEqual(MetricFormatters.celsius(62.6), "63 C")
        XCTAssertEqual(MetricFormatters.celsius(nil), "-- C")
    }

    func testFormatsPercent() {
        XCTAssertEqual(MetricFormatters.percent(0.427), "43%")
        XCTAssertEqual(MetricFormatters.percent(nil), "--%")
    }

    func testFormatsBytesAndThroughput() {
        XCTAssertEqual(MetricFormatters.bytes(1_073_741_824), "1.0 GB")
        XCTAssertEqual(MetricFormatters.throughput(2_097_152), "2.0 MB/s")
    }
}
