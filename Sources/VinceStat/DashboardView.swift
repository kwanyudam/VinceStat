import ServiceManagement
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @State private var tokenInput = ""
    @State private var showAuth = false
    @State private var showPastedLogin = false
    @State private var pastedCode = ""

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

    /// 권장 경로는 **자체 OAuth 로그인**이다 — VinceStat 전용 토큰 쌍을 받아 만료 전에 스스로
    /// 갱신하므로 Claude Code Keychain 을 읽지 않고, 따라서 허용 대화상자가 영구히 뜨지 않는다.
    ///
    /// 로그인하지 않은 경우의 폴백은 예전과 같다: 복사해 둔 Claude Code 토큰 → 만료되면 ↻ 를
    /// 누를 때만 Keychain 허용을 묻는다.
    ///
    /// 장기 토큰(`claude setup-token`) 입력란은 남겨 두되 권하지 않는다 — 그 토큰은
    /// `user:inference` 스코프만 가져서 usage API 가 상시 429 로 거절한다(2026-08-06 확인).
    @ViewBuilder
    private var authSection: some View {
        DisclosureGroup(isExpanded: $showAuth) {
            VStack(alignment: .leading, spacing: 8) {
                oauthLoginRows

                Divider()

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
                    Text("`claude setup-token` 장기 토큰은 usage API 가 429 로 거절합니다 — 넣지 마세요. 평소에는 복사해 둔 Claude Code 토큰으로 동작하고, 만료되면 ↻ 를 누를 때만 Keychain 허용을 묻습니다.")
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

    /// 자체 OAuth 로그인 상태 + 로그인/로그아웃. 로그인해 두면 팝업이 아예 사라진다.
    @ViewBuilder
    private var oauthLoginRows: some View {
        if state.hasOAuthLogin {
            HStack {
                Label("Anthropic 로그인됨 — 자동 갱신", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("로그아웃") { state.logoutOAuth() }
                    .font(.caption)
            }
            if let expiresAt = state.oauthToken?.expiresAt {
                Text("토큰 만료 \(expiresAt, style: .relative) 후 — 만료 전에 스스로 갱신합니다")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text(
                state.oauthNeedsRelogin
                    ? "로그인이 만료되었습니다. 다시 로그인하면 Keychain 허용 창 없이 계속 동작합니다."
                    : "Anthropic 계정으로 한 번 로그인하면 VinceStat 전용 토큰을 발급받아 스스로 갱신합니다 — Keychain 허용 창이 더 이상 뜨지 않습니다."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button(state.oauthNeedsRelogin ? "다시 로그인" : "Anthropic 계정으로 로그인") {
                    state.loginWithAnthropic()
                }
                .font(.caption)
                .disabled(state.isLoggingIn)
                if state.isLoggingIn {
                    ProgressView().controlSize(.small)
                    Text("브라우저에서 로그인을 마쳐 주세요")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup(isExpanded: $showPastedLogin) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("인증 페이지를 열고, 화면에 표시된 코드를 그대로 붙여넣으세요.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("인증 페이지 열기") { state.openPastedLoginPage() }
                        .font(.caption)
                    HStack(spacing: 6) {
                        TextField("코드 붙여넣기", text: $pastedCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Button("완료") {
                            state.completePastedLogin(pastedCode)
                            pastedCode = ""
                        }
                        .font(.caption)
                        .disabled(
                            pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || state.isLoggingIn
                        )
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("브라우저가 되돌아오지 않을 때")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }

        if let loginError = state.loginError {
            Text(loginError)
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
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
