import Foundation
import Security

struct NativeCredential: Codable {
    let accessToken: String
    let expiresAt: Date
}

/// No shared access group, browser storage, UserDefaults or synchronizable item.
enum NativeCredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ru.archiverf.aveli.native-account",
         kSecAttrAccount as String: "aveli-account-v1", kSecAttrSynchronizable as String: false]
    }
    static func load() throws -> NativeCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NativeAPIError.local("Не удалось открыть защищённый вход. Разблокируйте устройство.") }
        return try JSONDecoder().decode(NativeCredential.self, from: data)
    }
    static func save(_ credential: NativeCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            values.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw NativeAPIError.local("Не удалось сохранить защищённый вход.") }
        } else if status != errSecSuccess { throw NativeAPIError.local("Не удалось сохранить защищённый вход.") }
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}
