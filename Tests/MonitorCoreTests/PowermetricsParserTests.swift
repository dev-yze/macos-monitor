import XCTest
@testable import MonitorCore

final class PowermetricsParserTests: XCTestCase {
    func testParsesPowerFrequencyAndTemperatures() {
        let sample = """
        **** Processor usage ****
        CPU Power: 5200 mW
        GPU Power: 1800 mW
        Combined Power (CPU + GPU + ANE): 7480 mW
        E-Cluster HW active frequency: 1320 MHz
        P-Cluster HW active frequency: 3100 MHz
        GPU HW active residency: 42.6%

        **** SMC sensors ****
        CPU die temperature: 61.2 C
        GPU die temperature: 58.9 C
        """

        let snapshot = PowermetricsParser.parse(sample, timestamp: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(try XCTUnwrap(snapshot.systemPowerWatts), 7.48, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.gpu.powerWatts), 1.8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.gpu.usage), 0.426, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.cpu.frequencyMHz), 3100, accuracy: 0.001)
        XCTAssertEqual(snapshot.temperatures.count, 2)
        XCTAssertEqual(snapshot.temperatures.first?.name, "CPU die")
        XCTAssertEqual(try XCTUnwrap(snapshot.temperatures.first?.celsius), 61.2, accuracy: 0.001)
    }

    func testIgnoresGPUFrequencyForCPUFrequency() {
        let sample = """
        **** Processor usage ****
        E-Cluster HW active frequency: 1320 MHz
        GPU HW active frequency: 1500 MHz
        """

        let snapshot = PowermetricsParser.parse(sample, timestamp: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(try XCTUnwrap(snapshot.cpu.frequencyMHz), 1320, accuracy: 0.001)
    }

    func testParsesRealM5ProOutput() {
        let sample = """
        **** Processor usage ****
        P0-Cluster HW active frequency: 1344 MHz
        P1-Cluster HW active frequency: 1689 MHz
        S-Cluster HW active frequency: 2416 MHz
        CPU Power: 1673 mW
        GPU Power: 560 mW
        ANE Power: 0 mW
        Combined Power (CPU + GPU + ANE): 2233 mW
        **** GPU usage ****
        GPU HW active frequency: 338 MHz
        GPU HW active residency:  40.13% (338 MHz:  40% 486 MHz:   0%)
        GPU Power: 560 mW
        """

        let snapshot = PowermetricsParser.parse(sample, timestamp: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(try XCTUnwrap(snapshot.systemPowerWatts), 2.233, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.gpu.powerWatts), 0.56, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.gpu.usage), 0.4013, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.cpu.frequencyMHz), 2416, accuracy: 0.001)
    }
}
