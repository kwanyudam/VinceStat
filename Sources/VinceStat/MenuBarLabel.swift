import AppKit
import SwiftUI

/// Claude 브랜드 컬러 (#D97757)
let claudeOrange = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

/// 메뉴바 라벨. MenuBarExtra 라벨은 색을 템플릿(흑백)으로 렌더링하므로,
/// 컬러(주황 ✳)를 보존하려면 뷰를 NSImage로 직접 렌더링해야 한다.
struct MenuBarLabel: View {
    let state: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: renderImage())
    }

    @MainActor
    private func renderImage() -> NSImage {
        let content = MenuBarContent(
            cpuText: state.cpuText,
            memText: state.memText,
            claudeText: state.claudeText,
            claudeWarn: state.claudeWarn,
            textColor: colorScheme == .dark ? .white : .black
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return NSImage() }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2)
        )
        image.isTemplate = false
        return image
    }
}

private struct MenuBarContent: View {
    let cpuText: String
    let memText: String
    let claudeText: String
    let claudeWarn: Bool
    let textColor: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .medium))
            Text(cpuText)

            Image(systemName: "memorychip")
                .font(.system(size: 11, weight: .medium))
                .padding(.leading, 3)
            Text(memText)

            Text("✳")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(claudeOrange)
                .padding(.leading, 3)
            Text(claudeText)
                .foregroundStyle(claudeWarn ? claudeOrange : textColor)
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(textColor)
        .padding(.horizontal, 1)
    }
}
