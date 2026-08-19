import XCTest
@testable import MonitorCore

final class BatteryStateTests: XCTestCase {
    func testUnavailableWhenEveryFieldIsNil() {
        // 桌面 Mac：没有任何电池数据，不能误判为「未充电」。
        XCTAssertEqual(BatteryMetrics().state, .unavailable)
    }

    func testChargingWhenIsChargingTrue() {
        let battery = BatteryMetrics(percent: 0.5, isCharging: true)
        XCTAssertEqual(battery.state, .charging)
    }

    func testNotChargingWhenIsChargingFalse() {
        let battery = BatteryMetrics(percent: 0.8, isCharging: false)
        XCTAssertEqual(battery.state, .notCharging)
    }

    func testNotChargingWhenDataExistsButIsChargingUnknown() {
        // 有电量/功率数据但充电状态未知：设备有电池，只是状态缺失。
        let battery = BatteryMetrics(percent: 0.6)
        XCTAssertEqual(battery.state, .notCharging)
    }
}
