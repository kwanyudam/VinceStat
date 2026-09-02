import AppKit

/// 펫 발치에 붙는 패널의 내용. `PetView` 가 매 프레임 `AppState` 에서 새로 만든다.
struct PetHUDContent: Equatable {
    /// 항상 보이는 값 — Claude 잔여 (또는 추정 토큰).
    var claudeText: String
    var claudeWarn: Bool
    /// 다음 Claude 갱신까지 남은 시간. `nil` 이면 아직 멀어서 표시하지 않는다.
    var countdownText: String?
    /// 지금 갱신 중 — 카운트다운 자리를 대신 차지한다.
    var isRefreshing: Bool
    /// 마우스를 올렸을 때만 덧붙는 시스템 지표.
    var cpuText: String?
    var memText: String?
}

/// 펫 바로 아래에 붙는 수치 패널.
///
/// 평소에는 Claude 수치 한 줄만 둔다 — 펫은 흘긋 보는 물건이라 상시 정보가 많으면 배경 소음이 된다.
/// CPU·MEM 은 마우스를 올렸을 때만 펼친다. 임의의 배경 위에 뜨므로 시스템 색을 따르지 않고
/// 반투명 검정 캡슐 + 흰 글자로 고정한다 (밝은 배경에서 사라지지 않게).
enum PetHUD {
    /// 갱신까지 이 시간 이하로 남으면 카운트다운을 추가로 띄운다.
    /// 기본 갱신 주기 5분 기준으로 마지막 1분에만 뜬다.
    static let countdownLeadTime: TimeInterval = 60

    /// 세 줄(잔여 + 카운트다운 + CPU/MEM)까지 늘어날 수 있으므로 창은 이만큼 아래를 비워 둔다.
    static let maxHeight: CGFloat = 52

    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 4
    private static let lineGap: CGFloat = 1

    private static let labelColor = NSColor.white.withAlphaComponent(0.55)
    private static let valueColor = NSColor.white
    private static let subtleColor = NSColor.white.withAlphaComponent(0.7)
    /// Claude 브랜드 주황 (#D97757) — SwiftUI 쪽 `claudeOrange` 와 같은 색.
    static let claudeMarkColor = NSColor(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

    /// 남은 시간을 카운트다운 문자열로. 1분 이상은 `1m 05s`, 미만은 `38s`.
    static func countdownText(secondsRemaining: TimeInterval) -> String {
        let total = max(0, Int(secondsRemaining.rounded()))
        if total >= 60 {
            return String(format: "%dm %02ds", total / 60, total % 60)
        }
        return "\(total)s"
    }

    /// `centerX` 를 가운데로, `topY` 를 위쪽 끝으로 삼아 아래로 그린다 (펫 발치에 붙이는 용도).
    /// 실제로 차지한 사각형을 돌려주며, `PetView` 가 이를 마우스 히트 영역으로 재사용한다.
    @discardableResult
    static func draw(_ content: PetHUDContent, centerX: CGFloat, topY: CGFloat, maxWidth: CGFloat) -> NSRect {
        let lines = attributedLines(for: content)
        guard !lines.isEmpty else { return .zero }

        let sizes = lines.map { $0.size() }
        let contentWidth = sizes.map(\.width).max() ?? 0
        let contentHeight = sizes.map(\.height).reduce(0, +)
            + CGFloat(max(0, lines.count - 1)) * lineGap

        let pillWidth = min(maxWidth, contentWidth + horizontalPadding * 2)
        let pillHeight = contentHeight + verticalPadding * 2
        let pill = NSRect(
            x: centerX - pillWidth / 2,
            y: topY - pillHeight,
            width: pillWidth,
            height: pillHeight
        )

        let radius = min(pillHeight / 2, 10)
        let background = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.68).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        background.lineWidth = 1
        background.stroke()

        // y-up 좌표계라 첫 줄이 가장 높다.
        var cursorY = pill.maxY - verticalPadding
        for (index, line) in lines.enumerated() {
            cursorY -= sizes[index].height
            line.draw(at: NSPoint(x: pill.midX - sizes[index].width / 2, y: cursorY))
            cursorY -= lineGap
        }
        return pill
    }

    private static func attributedLines(for content: PetHUDContent) -> [NSAttributedString] {
        var lines = [claudeLine(content)]
        if let refresh = refreshLine(content) {
            lines.append(refresh)
        }
        if let system = systemLine(content) {
            lines.append(system)
        }
        return lines
    }

    private static func claudeLine(_ content: PetHUDContent) -> NSAttributedString {
        let line = NSMutableAttributedString(
            string: "✳ ",
            attributes: [.font: valueFont, .foregroundColor: claudeMarkColor]
        )
        line.append(NSAttributedString(
            string: content.claudeText,
            attributes: [
                .font: valueFont,
                .foregroundColor: content.claudeWarn ? claudeMarkColor : valueColor
            ]
        ))
        return line
    }

    private static func refreshLine(_ content: PetHUDContent) -> NSAttributedString? {
        let text: String
        if content.isRefreshing {
            text = "↻ 갱신 중"
        } else if let countdown = content.countdownText {
            text = "↻ \(countdown)"
        } else {
            return nil
        }
        return NSAttributedString(
            string: text,
            attributes: [.font: captionFont, .foregroundColor: subtleColor]
        )
    }

    /// 호버 중일 때만 붙는 줄. 둘 다 없으면 줄 자체를 만들지 않는다.
    private static func systemLine(_ content: PetHUDContent) -> NSAttributedString? {
        guard let cpu = content.cpuText, let mem = content.memText else { return nil }
        let line = NSMutableAttributedString()
        appendSegment(to: line, label: "CPU", value: cpu)
        line.append(NSAttributedString(
            string: "  ",
            attributes: [.font: captionFont]
        ))
        appendSegment(to: line, label: "MEM", value: mem)
        return line
    }

    private static func appendSegment(to line: NSMutableAttributedString, label: String, value: String) {
        line.append(NSAttributedString(
            string: "\(label) ",
            attributes: [.font: labelFont, .foregroundColor: labelColor]
        ))
        line.append(NSAttributedString(
            string: value,
            attributes: [.font: captionFont, .foregroundColor: subtleColor]
        ))
    }

    // MARK: - 폰트

    private static var valueFont: NSFont {
        monospacedDigits(NSFont.systemFont(ofSize: 11, weight: .semibold))
    }

    private static var labelFont: NSFont {
        monospacedDigits(NSFont.systemFont(ofSize: 8, weight: .medium))
    }

    private static var captionFont: NSFont {
        monospacedDigits(NSFont.systemFont(ofSize: 9, weight: .medium))
    }

    /// 숫자가 매 프레임 바뀌므로 고정폭 숫자를 쓴다 — 아니면 패널 너비가 계속 흔들린다.
    private static func monospacedDigits(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
