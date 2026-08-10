import Foundation
import Security

/// VinceStat이 직접 만든 Keychain 항목에 Claude 토큰을 보관한다.
/// 항목의 생성자가 VinceStat 자신이라, 고정 서명 identity 가 유지되는 한 읽을 때 허용
/// 대화상자가 뜨지 않는다.
struct StoredToken: Codable {
    enum Origin: String, Codable {
        /// `claude setup-token` 으로 발급받아 사용자가 직접 넣은 장기 토큰
        case manual
        /// Claude Code Keychain 항목에서 한 번 읽어 복사해 둔 토큰 (만료 있음)
        case mirror
        /// VinceStat 자체 OAuth 로그인으로 받은 토큰 쌍 — refresh 로 스스로 갱신한다
        case oauth
    }

    var accessToken: String
    /// `.oauth` 만 가진다. 만료 전에 이걸로 조용히 새 access token 을 받는다.
    var refreshToken: String?
    /// nil 이면 만료 시각을 모르는 토큰(장기 토큰)으로 취급한다.
    var expiresAt: Date?
    var origin: Origin

    init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        origin: Origin
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.origin = origin
    }

    /// 만료 직전 갱신을 위해 60초 여유를 둔다.
    func isValid(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > now.addingTimeInterval(60)
    }

    /// OAuth 토큰은 만료 5분 전에 미리 갱신한다 — 갱신이 네트워크 왕복이라 여유가 필요하다.
    func needsRefresh(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(300)
    }
}

final class TokenStore {
    /// Claude Code 토큰의 미러 / 사용자가 넣은 장기 토큰
    static let mirrorService = "com.vince.vincestat.token"
    /// VinceStat 자체 OAuth 로그인 토큰 쌍 (미러와 수명이 달라 항목을 분리한다)
    static let oauthService = "com.vince.vincestat.oauth"

    private let service: String
    private let account = "claude-oauth"

    init(service: String = TokenStore.mirrorService) {
        self.service = service
    }

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
        attributes[kSecAttrLabel as String] = service == TokenStore.oauthService
            ? "VinceStat — Anthropic OAuth 토큰"
            : "VinceStat — Claude usage token"
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
