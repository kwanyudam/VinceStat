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
}

enum ClaudeUsageError: LocalizedError {
    case noCredentials
    case tokenExpired
    case httpError(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "Claude Code 자격증명을 찾지 못했습니다"
        case .tokenExpired: return "OAuth 토큰이 만료되었습니다 (Claude Code를 한 번 실행하면 갱신됩니다)"
        case .httpError(let code): return "usage API 오류 (HTTP \(code))"
        case .badResponse: return "usage API 응답을 해석하지 못했습니다"
        }
    }
}

/// Claude Code의 OAuth 자격증명으로 사용량 API를 조회하고,
/// 실패 시 ~/.claude/projects JSONL 로컬 추정으로 폴백한다.
final class ClaudeUsageService {
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // MARK: - API 경로

    func fetchFromAPI() async throws -> ClaudeUsage {
        guard let creds = loadCredentials() else { throw ClaudeUsageError.noCredentials }
        if let expiresAt = creds.expiresAt, expiresAt < Date() {
            throw ClaudeUsageError.tokenExpired
        }

        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeUsageError.badResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw ClaudeUsageError.tokenExpired }
            throw ClaudeUsageError.httpError(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.badResponse
        }

        var usage = ClaudeUsage(source: .api)
        usage.fiveHour = parseWindow(json["five_hour"])
        usage.sevenDay = parseWindow(json["seven_day"])
        usage.sevenDayOpus = parseWindow(json["seven_day_opus"])
        usage.scopedWeekly = parseScopedWeekly(json["limits"])
        guard usage.fiveHour != nil || usage.sevenDay != nil else {
            throw ClaudeUsageError.badResponse
        }
        return usage
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
        let expiresAt: Date?
    }

    private func loadCredentials() -> Credentials? {
        // 1) 파일 (~/.claude/.credentials.json) — Keychain 프롬프트 없이 읽힘
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: fileURL), let creds = parseCredentials(data) {
            return creds
        }
        // 2) Keychain "Claude Code-credentials" — 최초 접근 시 macOS 허용 대화상자가 뜬다
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return parseCredentials(data)
    }

    private func parseCredentials(_ data: Data) -> Credentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token, expiresAt: expiresAt)
    }

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
