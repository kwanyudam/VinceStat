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
    /// Keychain 허용 대화상자를 사용자가 거부한 적이 있으면 자동 갱신에서 다시 묻지 않는다.
    /// 대시보드의 "다시 시도"나 수동 갱신 버튼으로만 해제된다.
    var keychainDenied: Bool {
        didSet { UserDefaults.standard.set(keychainDenied, forKey: "keychainDenied") }
    }
    /// 저장된 자체 토큰 (있으면 Keychain 팝업 경로를 아예 타지 않는다)
    private(set) var storedToken: StoredToken?
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
        storedToken = claudeService.storedToken()

        startSystemTimer()
        restartClaudeTimer()
        tickSystem()
        refreshClaude()
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

    /// - Parameter userInitiated: 사용자가 직접 누른 갱신인지. 이때는 Keychain 을 거부한
    ///   이력이 있어도 한 번 더 물어본다(사용자가 명시적으로 요청했으므로).
    func refreshClaude(userInitiated: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let service = claudeService
        let allowPrompt = userInitiated || !keychainDenied
        Task {
            defer { isRefreshing = false }
            do {
                let result = try await service.fetchFromAPI(allowKeychainPrompt: allowPrompt)
                usage = result
                usageError = nil
                lastRefresh = Date()
                if result.credentialSource == .claudeCodeKeychain { keychainDenied = false }
                storedToken = service.storedToken()
            } catch {
                if case ClaudeUsageError.keychainDenied = error { keychainDenied = true }
                usageError = error.localizedDescription
                storedToken = service.storedToken()
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

    /// 현재 자격증명 상태 한 줄 요약
    var authStatusText: String {
        if let stored = storedToken {
            return stored.origin == .manual
                ? "장기 토큰 사용 중 — Keychain 팝업 없음"
                : "Claude Code 토큰을 복사해 사용 중"
        }
        if keychainDenied { return "Keychain 접근 거부됨 — 추정 모드로만 동작합니다" }
        return usage?.credentialSource?.label ?? "자격증명 없음"
    }

    var hasManualToken: Bool { storedToken?.origin == .manual }

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
