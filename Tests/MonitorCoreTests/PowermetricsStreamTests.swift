import Darwin
import XCTest
@testable import MonitorCore

final class PowermetricsStreamTests: XCTestCase {
    private var path = ""

    override func setUp() {
        super.setUp()
        path = "/tmp/macosmonitor-test-\(UUID().uuidString).fifo"
        XCTAssertEqual(mkfifo(path, 0o600), 0)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    /// 重连场景：管道缓冲里积压了旧样本（甚至是结构完整的旧样本）。
    /// `start()` 必须排空它们，保证第一个解析出的样本是重连之后新写入的，
    /// 否则旧字节会被 parser 打上「现在」的时间戳混进历史。
    func testStartDrainsStaleBufferedData() throws {
        // 挂住一个读端，writer 的非阻塞 open 才能成功，数据才会留在管道缓冲里。
        let holderFD = open(path, O_RDONLY | O_NONBLOCK)
        XCTAssertNotEqual(holderFD, -1)
        defer { close(holderFD) }

        let staleWriter = open(path, O_WRONLY | O_NONBLOCK)
        XCTAssertNotEqual(staleWriter, -1)
        writeString(staleWriter, """
        *** Sampled system activity (Sun Aug 16 13:27:44 2026 +0800) (2040ms elapsed) ***
        **** Processor usage ****
        CPU Power: 9999 mW
        Combined Power (CPU + GPU + ANE): 9999 mW
        *** Sampled system activity (Sun Aug 16 13:27:46 2026 +0800) (2040ms elapsed) ***
        **** Processor usage ****
        """)
        close(staleWriter)

        let stream = PowermetricsStream(fifoPath: path)
        var received: [MetricsSnapshot] = []
        let freshExpectation = expectation(description: "收到重连后的新样本")
        stream.onSample = { sample in
            received.append(sample)
            freshExpectation.fulfill()
        }
        stream.onFailure = { message in XCTFail("意外失败：\(message)") }
        try stream.start()
        defer { stream.stop() }

        // 重连后新写入两个样本边界 → 应解析出恰好 1 个新样本。
        let freshWriter = open(path, O_WRONLY | O_NONBLOCK)
        XCTAssertNotEqual(freshWriter, -1)
        writeString(freshWriter, """
        *** Sampled system activity (Tue Aug 18 13:00:00 2026 +0800) (2000ms elapsed) ***
        **** Processor usage ****
        CPU Power: 1234 mW
        Combined Power (CPU + GPU + ANE): 2345 mW
        *** Sampled system activity (Tue Aug 18 13:00:02 2026 +0800) (2000ms elapsed) ***
        **** Processor usage ****
        """)
        // 保持 writer 打开直到断言完成，避免 EOF 触发 onEnd 干扰。
        defer { close(freshWriter) }

        wait(for: [freshExpectation], timeout: 5)

        XCTAssertEqual(received.count, 1, "旧数据应被排空，只允许解析出新写入的样本")
        XCTAssertEqual(try XCTUnwrap(received.first?.systemPowerWatts), 2.345, accuracy: 0.001)
    }

    private func writeString(_ fd: Int32, _ string: String) {
        string.withCString { pointer in
            _ = Darwin.write(fd, pointer, strlen(pointer))
        }
    }
}
