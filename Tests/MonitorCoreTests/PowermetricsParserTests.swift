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

    // MARK: - Sanity bounds（管道数据不可信：越界值必须丢弃并计数）

    func testDropsAbsurdPowerValues() {
        // 伪造样本：功耗超出物理合理范围（如本机任意进程向管道注入的垃圾数据）。
        let sample = """
        **** Processor usage ****
        CPU Power: 99999999 mW
        GPU Power: -500 mW
        Combined Power (CPU + GPU + ANE): 99999999 mW
        """

        let result = PowermetricsParser.parseDetailed(sample)

        XCTAssertNil(result.snapshot.systemPowerWatts)
        XCTAssertNil(result.snapshot.gpu.powerWatts)
        XCTAssertEqual(result.droppedInvalidCount, 3, "CPU、GPU、Combined 三个越界值都应被计数")
    }

    func testDropsAbsurdFrequencyResidencyAndTemperature() {
        let sample = """
        P0-Cluster HW active frequency: 99999 MHz
        GPU HW active residency:  240.5%
        CPU die temperature: 900 C
        """

        let result = PowermetricsParser.parseDetailed(sample)

        XCTAssertNil(result.snapshot.cpu.frequencyMHz)
        XCTAssertNil(result.snapshot.gpu.usage)
        XCTAssertTrue(result.snapshot.temperatures.isEmpty)
        XCTAssertEqual(result.droppedInvalidCount, 3)
    }

    func testValidValuesPassUntouched() {
        let result = PowermetricsParser.parseDetailed("""
        CPU Power: 5200 mW
        Combined Power (CPU + GPU + ANE): 7480 mW
        P0-Cluster HW active frequency: 3100 MHz
        GPU HW active residency:  99.9%
        CPU die temperature: 61.2 C
        """)

        XCTAssertEqual(result.droppedInvalidCount, 0)
        XCTAssertEqual(try XCTUnwrap(result.snapshot.systemPowerWatts), 7.48, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.snapshot.cpu.frequencyMHz), 3100, accuracy: 0.001)
        XCTAssertEqual(result.snapshot.temperatures.count, 1)
    }

    func testSanityBoundaries() {
        XCTAssertEqual(MetricSanity.watts(0), 0)
        XCTAssertEqual(MetricSanity.watts(500), 500)
        XCTAssertNil(MetricSanity.watts(500.1))
        XCTAssertNil(MetricSanity.watts(-0.1))
        XCTAssertEqual(MetricSanity.megahertz(10_000), 10_000)
        XCTAssertNil(MetricSanity.megahertz(10_001))
        XCTAssertEqual(MetricSanity.percent(100), 100)
        XCTAssertNil(MetricSanity.percent(100.1))
        XCTAssertEqual(MetricSanity.celsius(-40), -40)
        XCTAssertEqual(MetricSanity.celsius(150), 150)
        XCTAssertNil(MetricSanity.celsius(151))
    }
}
