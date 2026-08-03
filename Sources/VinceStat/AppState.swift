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
    private let historyLimit = 100  // 3초 간격 × 100 = 5분

    init() {
        let defaults = UserDefaults.standard
        let savedMinutes = defaults.integer(forKey: "claudeRefreshMinutes")
        claudeRefreshMinutes = savedMinutes > 0 ? savedMinutes : 5
        let savedThreshold = defaults.double(forKey: "warnThresholdPercent")
        warnThresholdPercent = savedThreshold > 0 ? savedThreshold : 80

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

    /// 메뉴바 Claude 수치 (✳ 아이콘 제외)
    var claudeText: String {
        guard let usage else { return "–" }
        switch usage.source {
        case .api:
            guard let window = usage.fiveHour else { return "–" }
            return "\(Int(window.remainingPercent.rounded()))%"
        case .estimate:
            guard let tokens = usage.estimatedTokensUsed5h else { return "–" }
            return "~\(Self.shortTokens(tokens))"
        }
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

    func refreshClaude() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let service = claudeService
        Task {
            defer { isRefreshing = false }
            do {
                let result = try await service.fetchFromAPI()
                usage = result
                usageError = nil
                lastRefresh = Date()
            } catch {
                usageError = error.localizedDescription
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
}
