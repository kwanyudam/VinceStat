import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    // MARK: - 시스템 지표
    var cpuPercent: Double = 0
    var memUsedGB: Double = 0
    let memTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []

    // MARK: - Claude 사용량
    var usage: ClaudeUsage?
    var usageError: String?
    var lastRefresh: Date?
    var isRefreshing = false
    /// 마지막 Keychain 허용 대화상자에서 사용자가 거부했는지 (대시보드 표시용).
    /// 자동 갱신은 이 값과 무관하게 애초에 대화상자를 띄우지 않는다 — `refreshClaude` 참고.
    var keychainDenied: Bool {
        didSet { UserDefaults.standard.set(keychainDenied, forKey: "keychainDenied") }
    }
    /// 저장된 자체 토큰 (있으면 Keychain 팝업 경로를 아예 타지 않는다)
    private(set) var storedToken: StoredToken?
    /// VinceStat 자체 OAuth 로그인 토큰 — 있으면 만료 전에 스스로 갱신하므로 팝업이 영구히 없다
    private(set) var oauthToken: StoredToken?
    var isLoggingIn = false
    var loginError: String?
    /// 429 를 받으면 이 시각까지 자동 갱신을 건너뛴다 (수동 갱신은 그대로 허용).
    private(set) var rateLimitedUntil: Date?
    /// 메뉴바 카운트다운 표시용 현재 시각 (3초 틱, 1분 미만 카운트다운 시 1초 틱)
    private(set) var now = Date()

    // MARK: - 설정 (UserDefaults 영속)
    var claudeRefreshMinutes: Int {
        didSet {
            UserDefaults.standard.set(claudeRefreshMinutes, forKey: "claudeRefreshMinutes")
            restartClaudeTimer()
        }
    }
    var warnThresholdPercent: Double {
        didSet { UserDefaults.standard.set(warnThresholdPercent, forKey: "warnThresholdPercent") }
    }
    /// 데스크톱 펫 표시 여부. 끄면 창뿐 아니라 애니메이션 타이머까지 없앤다 —
    /// 숨기기만 하면 꺼 둔 상태에서도 30fps 루프가 계속 돈다.
    var petEnabled: Bool {
        didSet {
            UserDefaults.standard.set(petEnabled, forKey: "petEnabled")
            petController.apply(enabled: petEnabled)
        }
    }

    /// AppState 가 소유하고 펫 쪽은 `unowned` 로 되참조한다 (AppState 는 앱 수명 내내 산다).
    /// `self` 를 넘겨야 해서 lazy 이고, 관찰 대상이 아니므로 @Observable 추적에서 뺀다.
    @ObservationIgnored private lazy var petController = PetController(state: self)

    private let statsService = SystemStatsService()
    private let claudeService = ClaudeUsageService()
    private var systemTimer: Timer?
    private var claudeTimer: Timer?
    private var countdownTimer: Timer?
    private let historyLimit = 100  // 3초 간격 × 100 = 5분

    init() {
        let defaults = UserDefaults.standard
        let savedMinutes = defaults.integer(forKey: "claudeRefreshMinutes")
        claudeRefreshMinutes = savedMinutes > 0 ? savedMinutes : 5
        let savedThreshold = defaults.double(forKey: "warnThresholdPercent")
        warnThresholdPercent = savedThreshold > 0 ? savedThreshold : 80
        keychainDenied = defaults.bool(forKey: "keychainDenied")
        petEnabled = defaults.bool(forKey: "petEnabled")
        storedToken = claudeService.storedToken()
        oauthToken = claudeService.oauthToken()

        startSystemTimer()
        restartClaudeTimer()
        tickSystem()
        refreshClaude()

        // 창 생성은 NSApplication 이 완전히 올라온 뒤로 미룬다 — AppState 는 App 구조체가
        // 만들어지는 시점(applicationDidFinishLaunching 이전)에 초기화된다.
        petDebugLog("init petEnabled=\(petEnabled) env=\(ProcessInfo.processInfo.environment["VINCESTAT_PET_REMAINING"] ?? "nil")")
        if petEnabled {
            Task { @MainActor in self.petController.apply(enabled: true) }
        }
    }

    // MARK: - 메뉴바 텍스트

    var memPercent: Double {
        memTotalGB > 0 ? min(100, memUsedGB / memTotalGB * 100) : 0
    }

    var cpuText: String { String(format: "%.0f%%", cpuPercent) }
    var memText: String { String(format: "%.0f%%", memPercent) }

    /// 메뉴바 Claude 수치 (✳ 아이콘 제외).
    /// 잔여 0%면 리셋까지 남은 시간(2h28m), 1분 미만이면 초 카운트다운(42s)을 보여준다.
    var claudeText: String {
        guard let usage else { return "–" }
        switch usage.source {
        case .api:
            guard let window = usage.fiveHour else { return "–" }
            let remaining = Int(window.remainingPercent.rounded())
            if remaining <= 0, let resetsAt = window.resetsAt {
                return Self.countdownText(until: resetsAt, from: now)
            }
            return "\(remaining)%"
        case .estimate:
            guard let tokens = usage.estimatedTokensUsed5h else { return "–" }
            return "~\(Self.shortTokens(tokens))"
        }
    }

    /// 리셋까지 남은 시간 포맷: 2h28m / 28m / 42s
    static func countdownText(until date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }

    var claudeWarn: Bool {
        guard let window = usage?.fiveHour, usage?.source == .api else { return false }
        return window.utilizationPercent >= warnThresholdPercent
    }

    // MARK: - 펫이 읽는 값

    /// 펫 활력 계산용 5시간 블록 잔여 %.
    /// 로컬 추정 모드에서는 플랜 한도 대비 %를 알 수 없으므로 `nil` — 펫은 정상 속도를 유지한다.
    var petRemainingPercent: Double? {
        // 개발용 주입: 잔량별로 펫이 어떻게 보이는지 확인할 때 쓴다 (`VINCESTAT_PET_REMAINING=25 swift run`).
        if let raw = ProcessInfo.processInfo.environment["VINCESTAT_PET_REMAINING"],
           let forced = Double(raw) {
            return forced
        }
        guard let usage, usage.source == .api, let window = usage.fiveHour else { return nil }
        return window.remainingPercent
    }

    /// 다음 자동 갱신 예정 시각. 반복 타이머의 다음 발화 시각이 곧 그 시각이다.
    /// ↻ 수동 갱신은 타이머를 리셋하지 않으므로 이 값도 앞당겨지지 않는다.
    var nextClaudeRefreshAt: Date? { claudeTimer?.fireDate }

    static func shortTokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return String(format: "%.0fk", Double(count) / 1_000)
        default: return "\(count)"
        }
    }

    // MARK: - 시스템 타이머

    private func startSystemTimer() {
        systemTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSystem() }
        }
        systemTimer?.tolerance = 1
    }

    private func tickSystem() {
        if let cpu = statsService.sampleCPUPercent() {
            cpuPercent = cpu
            cpuHistory.append(cpu)
            if cpuHistory.count > historyLimit { cpuHistory.removeFirst() }
        }
        if let mem = statsService.sampleMemoryUsedGB() {
            memUsedGB = mem
            memHistory.append(mem)
            if memHistory.count > historyLimit { memHistory.removeFirst() }
        }
        now = Date()
        updateCountdownTimer()
    }

    // MARK: - 리셋 카운트다운

    /// 잔여 0% 카운트다운 표시 중 남은 시간이 1분대에 들어오면 1초 타이머로 전환한다.
    private func updateCountdownTimer() {
        let needsSecondTick: Bool = {
            guard usage?.source == .api,
                  let window = usage?.fiveHour,
                  Int(window.remainingPercent.rounded()) <= 0,
                  let resetsAt = window.resetsAt
            else { return false }
            return resetsAt.timeIntervalSince(now) < 90
        }()

        if needsSecondTick {
            guard countdownTimer == nil else { return }
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickCountdown() }
            }
        } else {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    private func tickCountdown() {
        now = Date()
        // 리셋 시각이 지나면 새 윈도우 정보를 바로 가져온다
        if let resetsAt = usage?.fiveHour?.resetsAt, resetsAt <= now {
            countdownTimer?.invalidate()
            countdownTimer = nil
            refreshClaude()
        }
    }

    // MARK: - Claude 타이머 / 갱신

    private func restartClaudeTimer() {
        claudeTimer?.invalidate()
        let interval = TimeInterval(claudeRefreshMinutes * 60)
        claudeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClaude() }
        }
        claudeTimer?.tolerance = 10
    }

    /// 자체 OAuth 로그인이 되어 있으면 이 값과 무관하게 팝업이 뜨지 않는다 — 토큰을 스스로
    /// refresh 하므로 Claude Code Keychain 을 읽지 않는다.
    ///
    /// - Parameter userInitiated: 사용자가 직접 누른 갱신인지. 로그인하지 않은 폴백 상태에서
    ///   **Keychain 허용 대화상자는 이때만 뜬다.** 타이머·앱 시작 같은 자동 갱신은 미러 토큰이
    ///   만료됐어도 Claude Code 항목을 읽지 않고 조용히 추정 모드로 내려간다. 팝업이 예고 없이
    ///   튀어나오는 대신 사용자가 ↻ 를 누른 순간에만 뜨게 하기 위함이다.
    func refreshClaude(userInitiated: Bool = false) {
        guard !isRefreshing else { return }
        // 429 백오프 중이면 자동 갱신은 건너뛴다 (사용자가 직접 누른 갱신은 통과)
        if !userInitiated, let until = rateLimitedUntil, until > Date() { return }
        isRefreshing = true
        let service = claudeService
        let allowPrompt = userInitiated
        Task {
            defer { isRefreshing = false }
            do {
                let result = try await service.fetchFromAPI(allowKeychainPrompt: allowPrompt)
                usage = result
                usageError = nil
                rateLimitedUntil = nil
                lastRefresh = Date()
                if result.credentialSource == .claudeCodeKeychain { keychainDenied = false }
                storedToken = service.storedToken()
                oauthToken = service.oauthToken()
            } catch {
                if case ClaudeUsageError.keychainDenied = error { keychainDenied = true }
                if case ClaudeUsageError.rateLimited(let retryAfter, _) = error {
                    rateLimitedUntil = Date().addingTimeInterval(retryAfter ?? 600)
                }
                usageError = error.localizedDescription
                storedToken = service.storedToken()
                oauthToken = service.oauthToken()
                // 폴백: 로컬 JSONL 추정 (파일 IO라 백그라운드에서)
                let estimated = await Task.detached(priority: .utility) {
                    service.estimateTokensUsedLast5h()
                }.value
                if let estimated {
                    usage = ClaudeUsage(source: .estimate, estimatedTokensUsed5h: estimated)
                    lastRefresh = Date()
                }
            }
        }
    }

    // MARK: - 인증

    /// 자체 OAuth 로그인이 살아 있는지 (= Keychain 팝업이 뜰 일이 없는 상태)
    var hasOAuthLogin: Bool { oauthToken?.refreshToken != nil }

    /// 로그인했지만 refresh token 이 죽어서 다시 로그인해야 하는 상태
    var oauthNeedsRelogin: Bool { oauthToken != nil && oauthToken?.refreshToken == nil }

    /// 현재 자격증명 상태 한 줄 요약
    var authStatusText: String {
        if hasOAuthLogin { return "자체 OAuth 로그인 — 자동 갱신, 팝업 없음" }
        if oauthNeedsRelogin { return "로그인이 만료됨 — 다시 로그인해 주세요" }
        if let stored = storedToken {
            if stored.origin == .manual { return "장기 토큰 사용 중 — usage API 가 거절합니다 (삭제 권장)" }
            return stored.isValid()
                ? "Claude Code 토큰을 복사해 사용 중 — 팝업 없음"
                : "복사해 둔 토큰이 만료됨 — ↻ 를 누르면 Keychain 허용을 한 번 묻습니다"
        }
        if keychainDenied { return "Keychain 접근 거부됨 — ↻ 를 누르면 다시 묻습니다" }
        return usage?.credentialSource?.label ?? "자격증명 없음"
    }

    var hasManualToken: Bool { storedToken?.origin == .manual }

    /// 브라우저로 Anthropic 로그인 → VinceStat 전용 토큰 쌍 발급.
    /// 이후로는 만료 전에 스스로 refresh 하므로 Keychain 허용 창이 뜨지 않는다.
    func loginWithAnthropic() {
        performLogin { try await self.claudeService.loginWithOAuth() }
    }

    /// 리다이렉트를 못 받는 경우용: 인증 페이지를 열고 코드를 붙여넣게 한다.
    func openPastedLoginPage() {
        loginError = nil
        NSWorkspace.shared.open(claudeService.pastedLoginURL())
    }

    func completePastedLogin(_ code: String) {
        performLogin { try await self.claudeService.completePastedLogin(code) }
    }

    private func performLogin(_ work: @escaping () async throws -> Void) {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        loginError = nil
        Task {
            defer { isLoggingIn = false }
            do {
                try await work()
                oauthToken = claudeService.oauthToken()
                keychainDenied = false
                refreshClaude()
            } catch {
                loginError = error.localizedDescription
                oauthToken = claudeService.oauthToken()
            }
        }
    }

    func logoutOAuth() {
        claudeService.logoutOAuth()
        oauthToken = nil
        loginError = nil
    }

    /// `claude setup-token` 으로 받은 장기 토큰을 저장하고 바로 갱신한다.
    func saveManualToken(_ raw: String) {
        claudeService.saveManualToken(raw)
        storedToken = claudeService.storedToken()
        keychainDenied = false
        refreshClaude(userInitiated: true)
    }

    func clearStoredToken() {
        claudeService.clearStoredToken()
        storedToken = nil
    }

    /// Keychain 거부 이력을 지우고 다시 물어보게 한다.
    func retryKeychain() {
        keychainDenied = false
        refreshClaude(userInitiated: true)
    }
}
