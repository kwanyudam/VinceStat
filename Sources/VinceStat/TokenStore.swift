import Foundation
import Security

/// VinceStat이 직접 만든 Keychain 항목에 Claude 토큰을 보관한다.
///
/// Claude Code 의 `Claude Code-credentials` 항목은 토큰 갱신 때마다 삭제·재생성되므로
/// 그 항목의 ACL("항상 허용")은 유지되지 않는다. 반면 이 항목은 생성자가 VinceStat 자신이라
/// 고정 서명 identity 가 유지되는 한 읽을 때 허용 대화상자가 뜨지 않는다.
struct StoredToken: Codable {
    enum Origin: String, Codable {
        /// `claude setup-token` 으로 발급받아 사용자가 직접 넣은 장기 토큰
        case manual
        /// Claude Code Keychain 항목에서 한 번 읽어 복사해 둔 토큰 (만료 있음)
        case mirror
    }

    var accessToken: String
    /// nil 이면 만료 시각을 모르는 토큰(장기 토큰)으로 취급한다.
    var expiresAt: Date?
    var origin: Origin

    /// 만료 직전 갱신을 위해 60초 여유를 둔다.
    func isValid(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > now.addingTimeInterval(60)
    }
}

final class TokenStore {
    private let service = "com.vince.vincestat.token"
    private let account = "claude-oauth"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> StoredToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(StoredToken.self, from: data)
    }

    func save(_ token: StoredToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let update = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard update == errSecItemNotFound else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "VinceStat — Claude usage token"
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
