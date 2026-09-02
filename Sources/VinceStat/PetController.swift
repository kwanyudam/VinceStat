import AppKit
import SwiftUI

/// 펫 창의 수명과 우클릭 대시보드 팝오버를 관리한다. 끄면 창과 재생 타이머를 완전히 없앤다
/// (숨기기만 하면 꺼 놓은 상태에서도 타이머가 계속 돈다).
@MainActor
final class PetController: NSObject, NSPopoverDelegate {
    private unowned let state: AppState
    private var window: PetWindow?
    private var view: PetView?
    private var popover: NSPopover?

    init(state: AppState) {
        self.state = state
        super.init()
    }

    var isShowing: Bool { window != nil }

    func apply(enabled: Bool) {
        petDebugLog("apply(enabled: \(enabled)) isShowing=\(isShowing)")
        if enabled {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        guard window == nil else { return }
        guard let sheet = PetSpriteSheet.bundled else {
            petDebugLog("스프라이트 번들이 없어 펫을 띄우지 못했습니다")
            return
        }

        let size = PetView.windowSize
        let origin = Self.savedOrigin(fallback: Self.defaultOrigin(size: size))
        let win = PetWindow(contentRect: NSRect(origin: origin, size: size))

        let petView = PetView(state: state, sheet: sheet)
        petView.frame = NSRect(origin: .zero, size: size)
        petView.onRequestWindowMove = { [weak win] newOrigin in
            win?.setFrameOrigin(newOrigin)
            Self.saveOrigin(newOrigin)
        }
        petView.onRightClick = { [weak self] location in
            self?.showDashboardPopover(at: location)
        }
        win.contentView = petView
        win.orderFrontRegardless()
        petView.start()

        window = win
        view = petView
        petDebugLog("show frame=\(win.frame) screens=\(NSScreen.screens.map(\.visibleFrame))")
    }

    private func hide() {
        popover?.performClose(nil)
        popover = nil
        view?.stop()
        window?.orderOut(nil)
        view = nil
        window = nil
    }

    // MARK: - 우클릭 대시보드

    /// 메뉴바에서 쓰는 것과 **같은** `DashboardView` 를 팝오버로 띄운다.
    /// 메뉴를 따로 만들지 않는 이유는 두 벌을 유지하면 반드시 어긋나기 때문이다.
    private func showDashboardPopover(at location: NSPoint) {
        guard let window, let view else { return }

        if let existing = popover, existing.isShown {
            existing.performClose(nil)
            return
        }

        let controller = NSHostingController(rootView: DashboardView().environment(state))
        controller.sizingOptions = .preferredContentSize

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self

        // 팝오버 안의 입력란(토큰·코드 붙여넣기)이 키 입력을 받으려면 앵커 창이 key 가 되어야 한다.
        window.wantsKey = true
        view.setInteractionLocked(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // 커서 위치를 앵커로 삼고, 펫이 화면 아래쪽에 있는 경우가 많으니 위로 펼친다.
        let anchor = NSRect(x: location.x, y: location.y, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        self.popover = popover
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window?.wantsKey = false
            view?.setInteractionLocked(false)
            popover = nil
        }
    }

    // MARK: - 위치 기억

    private static let originDefaultsKey = "petWindowOrigin"

    private static func defaultOrigin(size: NSSize) -> CGPoint {
        // NSScreen.main 은 key 창을 기준으로 정해져서 앱 시작 시점에는 엉뚱한 화면을 줄 수 있다.
        // screens.first 는 항상 주 디스플레이다.
        let visible = NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: visible.maxX - size.width - 32, y: visible.minY + 32)
    }

    private static func saveOrigin(_ origin: CGPoint) {
        UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: originDefaultsKey)
    }

    /// 저장된 자리가 지금 연결된 어느 화면에도 없으면(모니터를 뺐다면) 기본 위치로 되돌린다.
    private static func savedOrigin(fallback: CGPoint) -> CGPoint {
        guard
            let dict = UserDefaults.standard.dictionary(forKey: originDefaultsKey),
            let x = dict["x"] as? CGFloat,
            let y = dict["y"] as? CGFloat
        else { return fallback }

        let saved = CGPoint(x: x, y: y)
        let onScreen = NSScreen.screens.contains {
            $0.visibleFrame.insetBy(dx: -60, dy: -60).contains(saved)
        }
        return onScreen ? saved : fallback
    }
}
