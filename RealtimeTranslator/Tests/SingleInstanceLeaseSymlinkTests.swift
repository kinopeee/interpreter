import Darwin
import Foundation
import XCTest
@testable import RealtimeTranslator

final class SingleInstanceLeaseSymlinkTests: XCTestCase {
    func testAcquireRejectsSymlinkLockPath() throws {
        // Given: instance.lockが通常ファイルではなくsymlinkになっている作業ディレクトリ
        let location = try makeTemporaryLockLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let target = location.directory.appendingPathComponent("other.lock")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: location.lockURL,
            withDestinationURL: target
        )

        // When: 多重起動ロックを取得する
        do {
            _ = try SingleInstanceLease.acquire(at: location.lockURL)
            XCTFail("symlinkのロックパスは開いてはいけません")
        } catch let error as SingleInstanceLeaseError {
            // Then: O_NOFOLLOWによりsymlinkを追わずopenFailedで拒否する
            guard case .openFailed(let errorNumber) = error else {
                return XCTFail("想定外のエラーです: \(error)")
            }
            XCTAssertTrue(
                errorNumber == ELOOP || errorNumber == EEXIST || errorNumber == EPERM,
                "symlink拒否のerrnoではありません: \(errorNumber)"
            )
        }
    }

    func testReleaseIsSafeToCallTwice() throws {
        // Given: 一時ロックファイルを所有しているlease
        let location = try makeTemporaryLockLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let owner = try XCTUnwrap(
            try SingleInstanceLease.acquire(at: location.lockURL)
        )

        // When: releaseを連続で呼ぶ
        owner.release()
        owner.release()

        // Then: 二重解放せず、次のownerが同じパスを取得できる
        let replacement = try SingleInstanceLease.acquire(at: location.lockURL)
        defer { replacement?.release() }
        XCTAssertNotNil(replacement)
    }

    private func makeTemporaryLockLocation() throws -> (
        directory: URL,
        lockURL: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RealtimeTranslator-SingleInstanceLeaseSymlinkTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            directory,
            directory.appendingPathComponent("instance.lock")
        )
    }
}
