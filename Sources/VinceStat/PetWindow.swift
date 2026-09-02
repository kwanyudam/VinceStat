import AppKit

/// 펫이 사는 테두리 없는 투명 창. 모든 Space 에서 다른 창 위에 떠 있는다.
///
/// 평소 `canBecomeKey` 가 false 인 이유: 펫을 만졌다고 터미널·에디터의 포커스를 뺏으면 안 된다.
/// 마우스 이벤트는 key 창이 아니어도 뷰까지 전달되므로 호버·드래그에는 영향이 없다.
/// 예외는 우클릭 대시보드 팝오버를 띄울 때뿐이라, 그때만 `wantsKey` 를 켠다
/// (팝오버 안의 입력란·버튼이 키 입력을 받으려면 앵커 창이 key 가 될 수 있어야 한다).
final class PetWindow: NSWindow {
    var wantsKey = false

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        // 창 자체는 이벤트를 받되, 펫 바깥의 투명한 영역에서는 PetView 가 주기적으로
        // `ignoresMouseEvents` 를 켜서 아래 앱으로 클릭이 통과하게 한다.
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }
}
