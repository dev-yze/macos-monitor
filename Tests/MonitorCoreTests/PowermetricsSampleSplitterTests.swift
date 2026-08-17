import XCTest
@testable import MonitorCore

final class PowermetricsSampleSplitterTests: XCTestCase {
    func testSplitsContinuousOutputOnSampleMarker() {
        var splitter = PowermetricsSampleSplitter()
        let lines = [
            "*** Sampled system activity (Sun Aug 16 13:27:44 2026 +0800) (2040ms elapsed) ***",
            "**** Processor usage ****",
            "CPU Power: 1673 mW",
            "GPU Power: 560 mW",
            "ANE Power: 0 mW",
            "Combined Power (CPU + GPU + ANE): 2233 mW",
            "**** GPU usage ****",
            "GPU HW active residency:  40.13%",
            "*** Sampled system activity (Sun Aug 16 13:27:46 2026 +0800) (2040ms elapsed) ***",
            "**** Processor usage ****",
            "CPU Power: 2122 mW",
            "GPU Power: 561 mW",
            "Combined Power (CPU + GPU + ANE): 2683 mW",
        ]

        var samples: [MetricsSnapshot] = []
        for line in lines {
            if let sample = splitter.consume(line: line) {
                samples.append(sample)
            }
        }

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(try XCTUnwrap(samples.first?.systemPowerWatts), 2.233, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(samples.first?.gpu.powerWatts), 0.56, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(samples.first?.gpu.usage), 0.4013, accuracy: 0.001)
    }
}
