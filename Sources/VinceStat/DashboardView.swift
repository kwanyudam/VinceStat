import ServiceManagement
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @State private var tokenInput = ""
    @State private var showAuth = false

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            claudeSection
            Divider()
            systemSection
            Divider()
            settingsSection(minutes: $state.claudeRefreshMinutes, threshold: $state.warnThresholdPercent)
            Divider()
            authSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Claude

    @ViewBuilder
    private var claudeSection: some View {
        HStack {
            Text("Claude").font(.headline)
            Spacer()
            if state.isRefreshing {
                ProgressView().controlSize(.small)
            }
            if let refreshed = state.lastRefresh {
                Text("\(refreshed, style: .relative) 전 동기화")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button {
                state.refreshClaude(userInitiated: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("지금 갱신")
        }

        if let usage = state.usage {
            switch usage.source {
            case .api:
                if let window = usage.fiveHour {
                    usageGauge(title: "5시간 블록", window: window)
                }
                if let window = usage.sevenDay {
                    usageGauge(title: "주간", window: window)
                }
                if let window = usage.sevenDayOpus {
                    usageGauge(title: "주간 (Opus)", window: window)
                }
                ForEach(usage.scopedWeekly, id: \.name) { scoped in
                    usageGauge(title: "주간 (\(scoped.name))", window: scoped.window)
                }
            case .estimate:
                if let tokens = usage.estimatedTokensUsed5h {
                    HStack {
                        Text("최근 5시간 사용 (추정)")
                        Spacer()
                        Text("~\(AppState.shortTokens(tokens)) tok")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Text("usage API 조회 실패 — 로컬 추정치입니다")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } else {
            Text("사용량 정보를 아직 가져오지 못했습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let error = state.usageError {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func usageGauge(title: String, window: ClaudeUsage.Window) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text("잔여 \(Int(window.remainingPercent.rounded()))%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(
                        window.utilizationPercent >= state.warnThresholdPercent
                            ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
                    )
            }
            ProgressView(value: window.utilizationPercent, total: 100)
                .tint(window.utilizationPercent >= state.warnThresholdPercent ? .orange : .accentColor)
            if let resetsAt = window.resetsAt {
                Text("리셋 \(resetsAt.formatted(date: .omitted, time: .shortened)) (\(resetsAt, style: .relative) 후)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 시스템

    @ViewBuilder
    private var systemSection: some View {
        metricRow(
            label: "CPU",
            value: String(format: "%.0f%%", state.cpuPercent),
            history: state.cpuHistory,
            maxValue: 100
        )
        metricRow(
            label: "MEM",
            value: String(format: "%.0f%% (%.1f/%.0fG)", state.memPercent, state.memUsedGB, state.memTotalGB),
            history: state.memHistory,
            maxValue: state.memTotalGB
        )
    }

    private func metricRow(label: String, value: String, history: [Double], maxValue: Double) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 40, alignment: .leading)
            Sparkline(values: history, maxValue: maxValue)
                .frame(height: 18)
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)
        }
    }

    // MARK: - 설정

    private func settingsSection(minutes: Binding<Int>, threshold: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude 갱신 주기")
                Spacer()
                Stepper(value: minutes, in: 1...30) {
                    Text("\(minutes.wrappedValue)분").monospacedDigit()
                }
                .fixedSize()
            }
            .font(.callout)

            HStack {
                Text("경고 임계값")
                Slider(value: threshold, in: 50...95, step: 5)
                Text("\(Int(threshold.wrappedValue))%")
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            .font(.callout)

            Toggle("로그인 시 시작", isOn: launchAtLoginBinding)
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enable in
                // 번들(.app) 밖에서 실행 중이면 실패할 수 있음 — 무시
                if enable {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
            }
        )
    }

    // MARK: - 인증

    /// Claude Code 는 토큰을 갱신할 때마다 Keychain 항목을 삭제·재생성하므로 그 항목에 준
    /// "항상 허용"은 유지되지 않는다. `claude setup-token` 으로 받은 장기 토큰을 여기에 한 번
    /// 넣어 두면 VinceStat 자체 항목에서만 읽으므로 팝업이 다시 뜨지 않는다.
    @ViewBuilder
    private var authSection: some View {
        DisclosureGroup(isExpanded: $showAuth) {
            VStack(alignment: .leading, spacing: 8) {
                if state.keychainDenied {
                    HStack(spacing: 6) {
                        Text("Keychain 접근이 거부된 상태입니다")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("다시 시도") { state.retryKeychain() }
                            .font(.caption)
                    }
                }

                if state.hasManualToken {
                    HStack {
                        Label("장기 토큰 저장됨", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Spacer()
                        Button("삭제") { state.clearStoredToken() }
                            .font(.caption)
                    }
                } else {
                    Text("터미널에서 `claude setup-token` 을 실행해 나온 토큰을 붙여넣으면 이후 Keychain 팝업이 뜨지 않습니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        SecureField("sk-ant-oat01-…", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Button("저장") {
                            state.saveManualToken(tokenInput)
                            tokenInput = ""
                        }
                        .font(.caption)
                        .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("인증").font(.callout)
                Spacer()
                Text(state.authStatusText)
                    .font(.caption2)
                    .foregroundStyle(state.keychainDenied ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
        }
        .font(.callout)
    }

    // MARK: - 푸터

    private var footer: some View {
        HStack {
            Text("VinceStat").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .font(.callout)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let maxValue: Double

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                Path { path in
                    let stepX = geo.size.width / CGFloat(values.count - 1)
                    for (index, value) in values.enumerated() {
                        let x = CGFloat(index) * stepX
                        let ratio = maxValue > 0 ? min(value / maxValue, 1) : 0
                        let y = geo.size.height * (1 - CGFloat(ratio))
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(.tint, lineWidth: 1.5)
            }
        }
    }
}
