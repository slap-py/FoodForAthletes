import Foundation
import Security

enum APIKeyStore {
    enum Key: String, CaseIterable {
        case openAI = "openai_api_key"
        case foodDataCentral = "fooddata_central_api_key"
    }

    static func value(for key: Key) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "FoodForAthletes",
            kSecAttrAccount: key.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, for key: Key) throws {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "FoodForAthletes",
            kSecAttrAccount: key.rawValue
        ]
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
            ? SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            : SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unableToSave(status) }
    }

    static func delete(_ key: Key) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "FoodForAthletes",
            kSecAttrAccount: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var hasCredentials: Bool {
        value(for: .openAI)?.isEmpty == false && value(for: .foodDataCentral)?.isEmpty == false
    }
}

enum KeychainError: LocalizedError {
    case unableToSave(OSStatus)

    var errorDescription: String? { "The API key could not be saved to the iPhone Keychain." }
}
