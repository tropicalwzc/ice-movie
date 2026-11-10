import XCTest
@testable import RenderKit

/// 回放缓存的准入判定。
///
/// 背景：缓存窗口满了如果按「删掉关键帧后的第 1 帧」方式缩容，`recent[0]`
/// 仍然是关键帧，但段内会出现越来越大的缺口。回放这种序列会让显示层因
/// 参考帧缺失解码失败，反而触发一次恢复 + seek。这里用帧序号把缺口挡在
/// 回放之前。
final class VideoRendererReplayTests: XCTestCase {

    func testSingleKeyframeIsReplayable() {
        XCTAssertTrue(VideoRenderer.isReplayable(firstIsKeyframe: true, sequences: [7]))
    }

    func testEmptySnapshotIsNotReplayable() {
        XCTAssertFalse(VideoRenderer.isReplayable(firstIsKeyframe: false, sequences: []))
    }

    func testNonKeyframeHeadIsNotReplayable() {
        // 起播前绑定：缓存从非关键帧开始，无法作为解码起点。
        XCTAssertFalse(VideoRenderer.isReplayable(firstIsKeyframe: false, sequences: [1, 2, 3]))
    }

    func testContiguousSnapshotIsReplayable() {
        XCTAssertTrue(
            VideoRenderer.isReplayable(firstIsKeyframe: true, sequences: [10, 11, 12, 13])
        )
    }

    /// 旧裁剪逻辑的产物：关键帧 + 跳过了若干帧的尾部。
    func testSnapshotWithGapIsNotReplayable() {
        XCTAssertFalse(
            VideoRenderer.isReplayable(firstIsKeyframe: true, sequences: [10, 11, 40, 41])
        )
    }

    /// 恢复清空后重新缓存时也会出现跳号（中间帧被丢给了旧层）。
    func testSnapshotWithSingleMissingFrameIsNotReplayable() {
        XCTAssertFalse(
            VideoRenderer.isReplayable(firstIsKeyframe: true, sequences: [10, 12, 13])
        )
    }

    func testNonMonotonicSequenceIsNotReplayable() {
        XCTAssertFalse(
            VideoRenderer.isReplayable(firstIsKeyframe: true, sequences: [10, 11, 10])
        )
    }
}
