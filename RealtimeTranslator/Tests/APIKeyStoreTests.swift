import XCTest
@testable import RealtimeTranslator

final class APIKeyStoreTests: XCTestCase {
    func testInMemorySaveLoadDeleteAndRejectEmpty() throws {
        // Given: 空のin-memory store
        let store = InMemoryAPIKeyStore()

        // When/Then: 空文字は拒否
        XCTAssertThrowsError(try store.save("   ")) { error in
            XCTAssertEqual(error as? APIKeyStoreError, .emptyKey)
        }

        // When: 保存・上書き・削除
        try store.save("sk-one")
        XCTAssertEqual(try store.load(), "sk-one")
        try store.save("sk-two")
        XCTAssertEqual(try store.load(), "sk-two")
        try store.delete()

        // Then: 削除後はnil
        XCTAssertNil(try store.load())
    }

    func testKeychainStoreRoundTripWithNamespacedService() throws {
        // Given: テスト専用service名のKeychain store
        let service = "com.realtimetranslator.tests.\(UUID().uuidString)"
        let store = KeychainAPIKeyStore(service: service, account: "unit-test-key")
        defer { try? store.delete() }

        // When: 保存する
        try store.save("sk-keychain-test")

        // Then: 読み戻せ、削除できる
        XCTAssertEqual(try store.load(), "sk-keychain-test")
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testBootstrapImportsEnvironmentOnlyWhenKeychainEmpty() throws {
        // Given: 空storeと環境変数
        let store = InMemoryAPIKeyStore()

        // When: 取り込む
        let imported = try APIKeyBootstrap.importFromEnvironmentIfNeeded(
            store: store,
            environment: ["OPENAI_API_KEY": " sk-from-env "]
        )

        // Then: 保存され、既存キーがある場合は無視
        XCTAssertTrue(imported)
        XCTAssertEqual(try store.load(), "sk-from-env")

        let ignored = try APIKeyBootstrap.importFromEnvironmentIfNeeded(
            store: store,
            environment: ["OPENAI_API_KEY": "sk-other"]
        )
        XCTAssertFalse(ignored)
        XCTAssertEqual(try store.load(), "sk-from-env")
    }

    func testBootstrapIgnoresBlankEnvironmentValue() throws {
        // Given: 空白の環境変数
        let store = InMemoryAPIKeyStore()

        // When
        let imported = try APIKeyBootstrap.importFromEnvironmentIfNeeded(
            store: store,
            environment: ["OPENAI_API_KEY": "   "]
        )

        // Then
        XCTAssertFalse(imported)
        XCTAssertNil(try store.load())
    }
}
