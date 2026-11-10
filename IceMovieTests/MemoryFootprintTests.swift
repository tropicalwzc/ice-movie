import IceCore
import XCTest

/// 播放器状态条与压测报告都依赖这条内存读数，先保证它本身靠谱。
final class MemoryFootprintTests: XCTestCase {

    func testCurrentReadsPlausibleValue() {
        let mb = MemoryFootprint.currentMB
        XCTAssertGreaterThan(mb, 0, "phys_footprint 读取失败时返回 -1")
        XCTAssertLessThan(mb, 16_384, "单位应是 MB，不是字节")
    }

    func testPeakFollowsReadsAndResets() {
        MemoryFootprint.resetPeak()
        XCTAssertEqual(MemoryFootprint.peakMB, 0, accuracy: 0.0001, "reset 后峰值应归零")

        let current = MemoryFootprint.currentMB
        XCTAssertGreaterThanOrEqual(MemoryFootprint.peakMB, current, "读取会推进峰值")

        MemoryFootprint.resetPeak()
        XCTAssertEqual(MemoryFootprint.peakMB, 0, accuracy: 0.0001)
    }

    func testLabelFormatting() {
        XCTAssertEqual(MemoryFootprint.label(-1), "--")
        XCTAssertEqual(MemoryFootprint.label(0), "0 MB")
        XCTAssertEqual(MemoryFootprint.label(185.4), "185 MB")
        XCTAssertEqual(MemoryFootprint.label(1023.4), "1023 MB")
        XCTAssertEqual(MemoryFootprint.label(2048), "2.00 GB")
    }

    func testLevelByAbsoluteUsage() {
        XCTAssertEqual(MemoryFootprint.level(currentMB: 200, baselineMB: nil), .normal)
        XCTAssertEqual(MemoryFootprint.level(currentMB: 699, baselineMB: nil), .normal)
        XCTAssertEqual(MemoryFootprint.level(currentMB: 700, baselineMB: nil), .warning)
        XCTAssertEqual(MemoryFootprint.level(currentMB: 1200, baselineMB: nil), .critical)
        XCTAssertEqual(MemoryFootprint.level(currentMB: -1, baselineMB: nil), .normal)
    }

    /// 绝对值正常但会话内涨得多，同样是泄漏信号。
    func testLevelBySessionGrowth() {
        XCTAssertEqual(MemoryFootprint.level(currentMB: 350, baselineMB: 100), .warning)
        XCTAssertEqual(MemoryFootprint.level(currentMB: 600, baselineMB: 100), .critical)
        // 相对基线下降不算异常。
        XCTAssertEqual(MemoryFootprint.level(currentMB: 90, baselineMB: 300), .normal)
    }
}
