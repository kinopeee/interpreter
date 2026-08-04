import Darwin
import Foundation
import XCTest
@testable import RealtimeTranslator

final class SingleInstanceLeaseTests: XCTestCase {
    func testSecondLeaseCannotAcquireOwnedLock() throws {
        // Given: 一時ロックファイルを所有する最初のlease
        let location = try makeTemporaryLockLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let owner = try XCTUnwrap(
            try SingleInstanceLease.acquire(at: location.lockURL)
        )
        defer { owner.release() }

        // When: 同じロックファイルのleaseを重ねて取得する
        let duplicate = try SingleInstanceLease.acquire(at: location.lockURL)

        // Then: 既存ownerを維持したまま重複取得だけを拒否する
        XCTAssertNil(duplicate)
    }

    func testLeaseCanBeAcquiredAfterOwnerReleasesLock() throws {
        // Given: 一時ロックファイルを所有しているlease
        let location = try makeTemporaryLockLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let owner = try XCTUnwrap(
            try SingleInstanceLease.acquire(at: location.lockURL)
        )

        // When: ownerがleaseを解放してから同じファイルを取得する
        owner.release()
        let replacement = try SingleInstanceLease.acquire(at: location.lockURL)
        defer { replacement?.release() }

        // Then: stale lockを残さず次のownerが取得できる
        XCTAssertNotNil(replacement)
    }

    func testLeasePublishesOwnerPIDAndClearsItOnRelease() throws {
        // Given: 一時ロックファイルを取得した現在プロセス
        let location = try makeTemporaryLockLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let owner = try XCTUnwrap(
            try SingleInstanceLease.acquire(at: location.lockURL)
        )

        // When: launcherが参照するowner metadataを読み取る
        let ownerMetadata = try String(
            contentsOf: location.lockURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // Then: 現在PIDを公開し、release後はstale PIDを残さない
        XCTAssertEqual(ownerMetadata, String(Darwin.getpid()))
        owner.release()
        XCTAssertEqual(
            try String(contentsOf: location.lockURL, encoding: .utf8),
            ""
        )
    }

    private func makeTemporaryLockLocation() throws -> (
        directory: URL,
        lockURL: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RealtimeTranslator-SingleInstanceLeaseTests-\(UUID().uuidString)",
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
