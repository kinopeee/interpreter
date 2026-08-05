import Foundation

/// テストと一時的な注入用のメモリ実装。Keychainへは触れない。
final class InMemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(initialKey: String? = nil) {
        stored = initialKey
    }

    func load() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIKeyStoreError.emptyKey
        }
        lock.lock()
        stored = trimmed
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}
