import Foundation

enum APIKeyStoreError: Error, LocalizedError, Equatable, Sendable {
    case emptyKey
    case notFound
    case unexpectedStatus(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "APIキーが空です"
        case .notFound:
            return "APIキーが保存されていません"
        case .unexpectedStatus:
            return "APIキーの保存領域へアクセスできません"
        case .encodingFailed:
            return "APIキーを処理できません"
        }
    }
}

protocol APIKeyStore: AnyObject, Sendable {
    func load() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

extension APIKeyStore {
    var hasStoredKey: Bool {
        (try? load()?.isEmpty == false) == true
    }
}
