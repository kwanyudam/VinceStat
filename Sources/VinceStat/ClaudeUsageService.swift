import Foundation
import Security

struct ClaudeUsage {
    struct Window {
        /// 0~100 사용률
        let utilizationPercent: Double
        let resetsAt: Date?

        var remainingPercent: Double { max(0, 100 - utilizationPercent) }
    }

    enum Source {
        case api        // OAuth usage API의 실제 한도 대비 값
        case estimate   // 로컬 JSONL 기반 추정 (사용 토큰 수만 앎)
    }

    /// limits 배열의 weekly_scoped 항목 — 모델별 주간 한도 (예: Fable)
    struct ScopedWindow {
        let name: String
        let window: Window
    }

    var source: Source
    var fiveHour: Window?
    var sevenDay: Window?
    var sevenDayOpus: Window?
    var scopedWeekly: [ScopedWindow] = []
    /// estimate 모드: 최근 5시간 동안 사용한 토큰 수
    var estimatedTokensUsed5h: Int?
    /// 이번 조회에 쓴 자격증명 출처 (대시보드 표시용)
    var credentialSource: CredentialSource?
}

/// 자격증명을 어디서 얻었는지. 팝업이 뜨는 경로는 `claudeCodeKeychain` 뿐이다.
enum CredentialSource: String {
    /// VinceStat 자체 OAuth 로그인 토큰 — 만료 전에 스스로 갱신하므로 팝업이 영구히 없음
    case ownOAuth
    /// VinceStat 자체 Keychain 항목의 장기 토큰 (`claude setup-token`) — 팝업 없음
    case manualToken
    /// VinceStat 자체 Keychain 항목에 복사해 둔 Claude Code 토큰 — 팝업 없음
    case mirroredToken
    /// ~/.claude/.credentials.json — 팝업 없음
    case credentialsFile
    /// Claude Code 의 Keychain 항목 — 허용 대화상자가 뜰 수 있음
    case claudeCodeKeychain

    var label: String {
        switch self {
        case .ownOAuth: return "VinceStat 자체 OAuth (자동 갱신)"
        case .manualToken: return "장기 토큰 (setup-token)"
        case .mirroredToken: return "복사된 Claude Code 토큰"
        case .credentialsFile: return "~/.claude/.credentials.json"
        case .claudeCodeKeychain: return "Claude Code Keychain"
        }
    }
}

enum ClaudeUsageError: LocalizedError {
    case noCredentials
    case keychainSkipped
    case keychainDenied
    case tokenExpired
    case tokenRejected
    case manualTokenUnsupported
    case rateLimited(retryAfter: TimeInterval?, detail: String?)
    case httpError(Int, detail: String?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Claude Code 자격증명을 찾지 못했습니다"
        case .keychainSkipped:
            return "토큰이 만료되어 추정 모드입니다 — ↻ 를 누르면 Keychain 접근을 요청합니다"
        case .keychainDenied:
            return "Keychain 접근이 거부되었습니다 — 다시 묻지 않습니다"
        case .tokenExpired:
            return "OAuth 토큰이 만료되었습니다 (Claude Code를 한 번 실행하면 갱신됩니다)"
        case .tokenRejected:
            return "토큰이 거부되었습니다 (401) — 장기 토큰을 다시 발급해 주세요"
        case .manualTokenUnsupported:
            return "장기 토큰(setup-token)은 usage API가 받지 않습니다 (429) — 인증 → 삭제 후 Claude Code 토큰을 쓰세요"
        case .rateLimited(let retryAfter, let detail):
            let wait = retryAfter.map { " — \(Int($0.rounded()))초 후 재시도" } ?? " — 잠시 후 재시도"
            return "usage API 요청 한도 초과 (429)\(wait)" + (detail.map { " · \($0)" } ?? "")
        case .httpError(let code, let detail):
            return "usage API 오류 (HTTP \(code))" + (detail.map { " · \($0)" } ?? "")
        case .badResponse:
            return "usage API 응답을 해석하지 못했습니다"
        }
    }
}

/// Claude Code의 OAuth 자격증명으로 사용량 API를 조회하고,
/// 실패 시 ~/.claude/projects JSONL 로컬 추정으로 폴백한다.
final class ClaudeUsageService {
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let tokenStore = TokenStore()
    private let oauthStore = TokenStore(service: TokenStore.oauthService)
    private let oauth = OAuthService()

    // MARK: - API 경로

    /// - Parameter allowKeychainPrompt: Claude Code Keychain 항목을 읽어도 되는지.
    ///   false 면 허용 대화상자가 뜰 수 있는 경로를 아예 타지 않는다.
    func fetchFromAPI(allowKeychainPrompt: Bool) async throws -> ClaudeUsage {
        let credentials = try await loadCredentials(allowKeychainPrompt: allowKeychainPrompt)

        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeUsageError.badResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                // 복사해 둔 토큰이 거부되면 버려서 다음 갱신에 원본을 다시 읽게 한다.
                // 사용자가 직접 넣은 장기 토큰은 지우지 않고 오류만 알린다.
                if credentials.source == .mirroredToken { tokenStore.clear() }
                // 자체 OAuth 토큰이 예상보다 일찍 죽은 경우: 만료로 표시해 두면
                // 다음 갱신에서 refresh token 으로 조용히 새로 받아 온다.
                if credentials.source == .ownOAuth { expireStoredOAuthToken() }
                throw credentials.source == .manualToken
                    ? ClaudeUsageError.tokenRejected
                    : ClaudeUsageError.tokenExpired
            }
            if http.statusCode == 429 {
                // 장기 토큰은 이 엔드포인트에서 상시 429 로 거절된다 (2026-08-06 확인).
                // 일시적 레이트리밋과 구분해서 알려 줘야 사용자가 기다리다 시간을 버리지 않는다.
                if credentials.source == .manualToken { throw ClaudeUsageError.manualTokenUnsupported }
                let retryAfter = (http.value(forHTTPHeaderField: "retry-after"))
                    .flatMap(TimeInterval.init)
                throw ClaudeUsageError.rateLimited(
                    retryAfter: retryAfter,
                    detail: Self.errorDetail(from: data)
                )
            }
            throw ClaudeUsageError.httpError(http.statusCode, detail: Self.errorDetail(from: data))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.badResponse
        }

        var usage = ClaudeUsage(source: .api)
        usage.credentialSource = credentials.source
        usage.fiveHour = parseWindow(json["five_hour"])
        usage.sevenDay = parseWindow(json["seven_day"])
        usage.sevenDayOpus = parseWindow(json["seven_day_opus"])
        usage.scopedWeekly = parseScopedWeekly(json["limits"])
        guard usage.fiveHour != nil || usage.sevenDay != nil else {
            throw ClaudeUsageError.badResponse
        }
        return usage
    }

    /// 오류 응답 본문(`{"type":"error","error":{"type":…,"message":…}}`)에서 원인 한 줄을 뽑는다.
    private static func errorDetail(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return nil }
        let parts = [error["type"] as? String, error["message"] as? String].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }

    /// limits 배열에서 모델 스코프가 붙은 주간 한도(weekly_scoped)를 추출한다.
    private func parseScopedWeekly(_ value: Any?) -> [ClaudeUsage.ScopedWindow] {
        guard let limits = value as? [[String: Any]] else { return [] }
        return limits.compactMap { limit in
            guard limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String,
                  let raw = limit["percent"] as? Double
                      ?? (limit["percent"] as? Int).map(Double.init)
            else { return nil }
            return ClaudeUsage.ScopedWindow(
                name: name,
                window: ClaudeUsage.Window(
                    utilizationPercent: min(100, max(0, raw)),
                    resetsAt: (limit["resets_at"] as? String).flatMap(Self.parseISODate)
                )
            )
        }
    }

    private func parseWindow(_ value: Any?) -> ClaudeUsage.Window? {
        guard let dict = value as? [String: Any] else { return nil }
        guard let raw = dict["utilization"] as? Double ?? (dict["utilization"] as? Int).map(Double.init)
        else { return nil }
        // 스키마 방어: 0~1 분수로 오면 %로 환산
        let percent = raw <= 1.0 ? raw * 100 : raw
        return ClaudeUsage.Window(
            utilizationPercent: min(100, max(0, percent)),
            resetsAt: (dict["resets_at"] as? String).flatMap(Self.parseISODate)
        )
    }

    // MARK: - 자격증명

    private struct Credentials {
        let accessToken: String
        let source: CredentialSource
    }

    /// 팝업이 없는 경로를 먼저 모두 시도하고, Claude Code Keychain 은 최후에 한 번만 본다.
    /// 거기서 읽은 토큰은 VinceStat 자체 항목에 복사해 두므로 만료 전까지 다시 묻지 않는다.
    private func loadCredentials(allowKeychainPrompt: Bool) async throws -> Credentials {
        // 0) VinceStat 자체 OAuth 토큰 — 만료가 가까우면 refresh token 으로 스스로 갱신한다.
        //    이 경로가 살아 있는 동안에는 Claude Code Keychain 을 아예 읽지 않으므로
        //    허용 대화상자가 뜰 일이 없다.
        if let token = try await currentOwnOAuthToken() {
            return Credentials(accessToken: token, source: .ownOAuth)
        }

        // 1) VinceStat 자체 Keychain 항목 — 우리가 만든 항목이라 대화상자가 뜨지 않는다
        if let stored = tokenStore.load(), stored.isValid() {
            return Credentials(
                accessToken: stored.accessToken,
                source: stored.origin == .manual ? .manualToken : .mirroredToken
            )
        }

        // 2) 파일 (~/.claude/.credentials.json) — 파일 권한만 있으면 읽힌다
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: fileURL), let parsed = parseClaudeCodeCredentials(data) {
            return Credentials(accessToken: parsed.accessToken, source: .credentialsFile)
        }

        // 3) Claude Code Keychain 항목 — macOS 허용 대화상자가 뜰 수 있는 유일한 경로
        guard allowKeychainPrompt else { throw ClaudeUsageError.keychainSkipped }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw ClaudeUsageError.keychainDenied
        default:
            throw ClaudeUsageError.noCredentials
        }
        guard let data = item as? Data, let parsed = parseClaudeCodeCredentials(data) else {
            throw ClaudeUsageError.noCredentials
        }
        if let expiresAt = parsed.expiresAt, expiresAt < Date() {
            throw ClaudeUsageError.tokenExpired
        }
        // 복사해 두면 이 토큰이 만료될 때까지 Claude Code 항목을 다시 읽지 않는다
        tokenStore.save(
            StoredToken(accessToken: parsed.accessToken, expiresAt: parsed.expiresAt, origin: .mirror)
        )
        return Credentials(accessToken: parsed.accessToken, source: .claudeCodeKeychain)
    }

    private func parseClaudeCodeCredentials(_ data: Data) -> (accessToken: String, expiresAt: Date?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return (token, expiresAt)
    }

    // MARK: - 자체 OAuth 토큰 (팝업 없는 자동 갱신 경로)

    /// 쓸 수 있는 자체 OAuth access token. 만료가 가까우면 refresh 를 먼저 돌린다.
    /// 로그인이 없거나 갱신이 불가능하면 nil 을 돌려주고, 호출자는 아래 폴백 경로로 내려간다.
    private func currentOwnOAuthToken() async throws -> String? {
        guard let stored = oauthStore.load(), stored.origin == .oauth else { return nil }
        if !stored.needsRefresh() { return stored.accessToken }
        guard let refreshToken = stored.refreshToken else { return nil }  // 재로그인 필요 상태

        do {
            let tokens = try await oauth.refresh(refreshToken: refreshToken)
            oauthStore.save(
                StoredToken(
                    accessToken: tokens.accessToken,
                    // 로테이션되면 새 refresh token 으로 교체, 안 오면 기존 것을 계속 쓴다
                    refreshToken: tokens.refreshToken ?? refreshToken,
                    expiresAt: tokens.expiresAt,
                    origin: .oauth
                )
            )
            return tokens.accessToken
        } catch OAuthError.invalidGrant {
            // refresh token 이 죽었다 — 다시 로그인해야 한다. 항목은 남겨 두고 refresh 만
            // 비워서 대시보드가 "재로그인 필요"를 구분해 보여줄 수 있게 한다.
            oauthStore.save(
                StoredToken(
                    accessToken: stored.accessToken,
                    refreshToken: nil,
                    expiresAt: .distantPast,
                    origin: .oauth
                )
            )
            return nil
        } catch {
            // 네트워크 등 일시적 실패: 토큰을 건드리지 않고 폴백 경로로 내려간다
            return nil
        }
    }

    /// 401 을 받았을 때 다음 갱신이 refresh 를 타도록 만료 표시만 해 둔다.
    private func expireStoredOAuthToken() {
        guard let stored = oauthStore.load(), stored.origin == .oauth else { return }
        oauthStore.save(
            StoredToken(
                accessToken: stored.accessToken,
                refreshToken: stored.refreshToken,
                expiresAt: .distantPast,
                origin: .oauth
            )
        )
    }

    /// 브라우저 로그인(루프백 콜백) — 성공하면 토큰 쌍을 자체 Keychain 항목에 넣는다.
    func loginWithOAuth() async throws {
        try store(tokens: try await oauth.login())
    }

    /// 리다이렉트를 못 받는 환경용: 인증 페이지 URL 을 받아 브라우저로 직접 연다.
    func pastedLoginURL() -> URL { oauth.pastedLoginURL() }

    /// 인증 페이지가 보여 준 코드로 로그인을 마무리한다.
    func completePastedLogin(_ pasted: String) async throws {
        try store(tokens: try await oauth.completePastedLogin(pasted))
    }

    private func store(tokens: OAuthTokens) throws {
        oauthStore.save(
            StoredToken(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                expiresAt: tokens.expiresAt,
                origin: .oauth
            )
        )
    }

    func oauthToken() -> StoredToken? { oauthStore.load() }

    func logoutOAuth() { oauthStore.clear() }

    // MARK: - 자체 토큰 관리 (대시보드에서 호출)

    /// `claude setup-token` 으로 받은 장기 토큰을 저장한다.
    func saveManualToken(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        tokenStore.save(StoredToken(accessToken: token, expiresAt: nil, origin: .manual))
    }

    func storedToken() -> StoredToken? { tokenStore.load() }

    func clearStoredToken() { tokenStore.clear() }

    // MARK: - 로컬 추정 폴백

    /// ~/.claude/projects/**/*.jsonl 에서 최근 5시간 내 usage 토큰을 합산한다.
    /// 최근 5시간 내에 수정된 파일만 연다.
    func estimateTokensUsedLast5h() -> Int? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-5 * 3600)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var total = 0
        var sawAnyFile = false
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate,
                  mtime > cutoff
            else { continue }
            sawAnyFile = true
            total += tokensInFile(url, since: cutoff)
        }
        return sawAnyFile ? total : nil
    }

    private func tokensInFile(_ url: URL, since cutoff: Date) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var total = 0
        for line in content.split(separator: "\n") {
            guard line.contains("\"usage\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if let ts = obj["timestamp"] as? String,
               let date = Self.parseISODate(ts), date < cutoff { continue }
            guard let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            total += intValue(usage["input_tokens"])
            total += intValue(usage["output_tokens"])
            total += intValue(usage["cache_creation_input_tokens"])
        }
        return total
    }

    private func intValue(_ value: Any?) -> Int {
        (value as? Int) ?? (value as? Double).map(Int.init) ?? 0
    }

    private static func parseISODate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
