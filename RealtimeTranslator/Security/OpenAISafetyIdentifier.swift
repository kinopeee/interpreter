import CryptoKit
import Foundation

enum OpenAISafetyIdentifier {
    private static let defaultsKey = "openaiSafetyInstallID"

    /// 非PIIの安定識別子。初回起動時にランダムUUIDを生成し、SHA-256ハッシュを返す。
    static func hashedValue(
        defaults: UserDefaults = .standard
    ) -> String {
        let installID: String
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            installID = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: defaultsKey)
            installID = generated
        }
        let digest = SHA256.hash(data: Data(installID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
