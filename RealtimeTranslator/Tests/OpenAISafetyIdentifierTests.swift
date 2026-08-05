import XCTest
@testable import RealtimeTranslator

final class OpenAISafetyIdentifierTests: XCTestCase {
    func testHashedValueIsStableForSameInstallID() {
        // Given: 空のUserDefaultsスイート
        let defaults = makeDefaults()

        // When: 同じdefaultsから2回取得する
        let first = OpenAISafetyIdentifier.hashedValue(defaults: defaults)
        let second = OpenAISafetyIdentifier.hashedValue(defaults: defaults)
        let installID = defaults.string(forKey: "openaiSafetyInstallID")

        // Then: 安定したSHA-256 hexを返し、install IDを保持する
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotNil(installID)
        XCTAssertFalse(installID?.isEmpty == true)
        XCTAssertFalse(first.contains(installID ?? ""))
    }

    func testEmptyStoredInstallIDIsRegenerated() {
        // Given: 空文字のinstall IDが残っているdefaults
        let defaults = makeDefaults()
        defaults.set("", forKey: "openaiSafetyInstallID")

        // When: hashedValueを取得する
        let hashed = OpenAISafetyIdentifier.hashedValue(defaults: defaults)
        let installID = defaults.string(forKey: "openaiSafetyInstallID")

        // Then: 空文字を再利用せず新しいIDからhashする
        XCTAssertEqual(hashed.count, 64)
        XCTAssertNotEqual(installID, "")
        XCTAssertNotNil(installID)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.realtimetranslator.tests.safety.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
