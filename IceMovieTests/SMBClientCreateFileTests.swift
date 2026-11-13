import Foundation
import IceCore
@testable import SMBSession
import XCTest

/// 真实 SMB 原子创建验收。默认跳过；运行前在模拟器可见的
/// `/private/tmp/icemovie-smb-test.json` 写入 host/share/user/password。
final class SMBClientCreateFileTests: XCTestCase {
    private struct TestConfig: Decodable {
        let host: String
        let share: String
        let user: String
        let password: String
    }

    func testCreateReadNoOverwriteAndCancelCleanup() async throws {
        let environment = ProcessInfo.processInfo.environment
        let configURL = URL(fileURLWithPath: "/private/tmp/icemovie-smb-test.json")
        let fileConfig: TestConfig? = {
            guard let data = try? Data(contentsOf: configURL) else { return nil }
            return try? JSONDecoder().decode(TestConfig.self, from: data)
        }()
        let host = environment["ICEMOVIE_SMB_TEST_HOST"] ?? fileConfig?.host
        let share = environment["ICEMOVIE_SMB_TEST_SHARE"] ?? fileConfig?.share
        let user = environment["ICEMOVIE_SMB_TEST_USER"] ?? fileConfig?.user
        let password = environment["ICEMOVIE_SMB_TEST_PASSWORD"] ?? fileConfig?.password
        guard let host, let share, let user, let password else {
            throw XCTSkip("未配置真实 SMB 测试环境")
        }

        let client = SMBClient(heartbeatInterval: .seconds(60))
        do {
            try await client.connect(
                host: host,
                user: user,
                password: password,
                share: share
            )
            let name = "__photo_sync_test_\(UUID().uuidString).jpg"
            let data = Data(repeating: 0x5A, count: 4096)
            let modified = Date(timeIntervalSince1970: 1_700_000_000)

            try await client.createFile(
                path: name,
                data: data,
                modified: modified,
                onProgress: { _ in true }
            )

            let entries = try await client.listDirectory(path: "")
            let entry = entries.first(where: { $0.name == name })
            XCTAssertEqual(entry?.size, Int64(data.count), "远端大小应与写入一致")
            let actualModified = entry?.modified?.timeIntervalSince1970 ?? 0
            XCTAssertEqual(
                actualModified,
                modified.timeIntervalSince1970,
                accuracy: 2,
                "修改时间应设置为拍摄时间"
            )

            do {
                try await client.createFile(
                    path: name,
                    data: Data([0x01]),
                    modified: nil,
                    onProgress: { _ in true }
                )
                XCTFail("已存在文件必须拒绝覆盖")
            } catch let error as SMBConnectionError {
                guard case .alreadyExists = error else { throw error }
            }

            let source = try await client.openByteSource(path: name)
            let read = try await source.read(at: 0, count: data.count)
            await source.close()
            XCTAssertEqual(read, data, "拒绝覆盖后原内容不得变化")

            let cancelName = "__photo_sync_cancel_\(UUID().uuidString).jpg"
            do {
                try await client.createFile(
                    path: cancelName,
                    data: Data(repeating: 0x11, count: 2 * 1024 * 1024),
                    modified: nil,
                    onProgress: { _ in false }
                )
                XCTFail("进度回调返回 false 时应中止")
            } catch {
                // 期望中止；下面确认没有留下最终文件或临时文件。
            }
            let after = try await client.listDirectory(path: "")
            XCTAssertFalse(
                after.contains { $0.name.hasPrefix(cancelName) },
                "取消后不得留下最终文件"
            )
            XCTAssertFalse(
                after.contains {
                    $0.name.contains(".icemovie-tmp-")
                        && $0.name.contains(cancelName)
                },
                "取消后不得留下临时文件"
            )
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }
}

final class SMBClientFileDeletionTests: XCTestCase {
    func testMissingFileErrorsAreTreatedAsSuccessfulDelete() {
        XCTAssertTrue(
            SMBClient.isMissingFileError(
                NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            )
        )
        XCTAssertTrue(SMBClient.isMissingFileError(POSIXError(.ENOENT)))
        XCTAssertTrue(
            SMBClient.isMissingFileError(
                NSError(
                    domain: "libsmb2",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Error code 2: No such file"]
                )
            )
        )
    }

    func testOtherErrorsAreNotTreatedAsMissingFile() {
        XCTAssertFalse(
            SMBClient.isMissingFileError(
                NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            )
        )
        XCTAssertFalse(
            SMBClient.isMissingFileError(
                NSError(
                    domain: "libsmb2",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "STATUS_ACCESS_DENIED"]
                )
            )
        )
    }
}
