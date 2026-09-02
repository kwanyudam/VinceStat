import AppKit

/// 리아코 한 마리를 그리고 마우스 조작을 처리하는 뷰. 값은 `AppState` 에서 직접 읽는다
/// (별도 프로세스가 아니라 VinceStat 안에 살기 때문에 상태 파일 같은 중간 단계가 필요 없다).
@MainActor
final class PetView: NSView {
    /// 스프라이트를 그릴 정사각형 한 변.
    static let spriteSize: CGFloat = 96
    /// 창 크기. 아래쪽에 수치 패널이 최대 세 줄까지 늘어날 자리를 비워 둔다.
    static let windowSize = NSSize(width: 190, height: spriteSize + PetHUD.maxHeight)

    private unowned let state: AppState
    private let sheet: PetSpriteSheet

    private var frameIndex = 0
    private var currentAnimation: PetAnimationName = .waving
    private var frames: PetSpriteAnimation?
    private var frameTimer: Timer?
    private var pointerTimer: Timer?

    private var hovering = false
    private var dragging = false
    private var dragDirection: PetDragDirection?
    private var dragBaselineX: CGFloat = 0
    private var dragOffset: CGPoint = .zero

    /// 팝오버가 떠 있는 동안은 커서가 펫 밖으로 나가도 창이 이벤트를 계속 받아야 한다.
    private var interactionLocked = false

    /// 마지막으로 그린 패널 위치 — 패널을 잡고도 끌 수 있게 히트 영역에 포함한다.
    private var lastHUDRect: NSRect = .zero

    var onRequestWindowMove: ((_ screenOrigin: CGPoint) -> Void)?
    var onRightClick: ((_ locationInView: NSPoint) -> Void)?

    init(state: AppState, sheet: PetSpriteSheet) {
        self.state = state
        self.sheet = sheet
        super.init(frame: NSRect(origin: .zero, size: Self.windowSize))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - 재생 루프

    /// 프레임 전환은 매니페스트의 프레임별 유지시간을 따르고(연속 타이머가 아니라 매번 재예약),
    /// 커서 판정만 별도로 20Hz 로 돈다. 스프라이트가 느려져도 호버 반응은 그대로 유지된다.
    func start() {
        stop()
        applyAnimation(force: true)
        let pointer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerTick() }
        }
        RunLoop.main.add(pointer, forMode: .common)
        pointerTimer = pointer
    }

    func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    /// 팝오버 표시 중에는 클릭 통과 판정을 멈춘다.
    func setInteractionLocked(_ locked: Bool) {
        interactionLocked = locked
        if locked { window?.ignoresMouseEvents = false }
    }

    private func pointerTick() {
        updatePointerState()
        applyAnimation()
        // 카운트다운 초가 줄어드는 것이 보이도록 패널은 계속 다시 그린다.
        needsDisplay = true
    }

    /// 지금 나와야 할 애니메이션을 고르고, 바뀌었으면 첫 프레임부터 다시 재생한다.
    private func applyAnimation(force: Bool = false) {
        let wanted = selectPetAnimation(PetAnimationInput(
            dragging: dragging,
            dragDirection: dragDirection,
            hovering: hovering,
            refreshing: state.isRefreshing,
            vitality: PetVitality(remainingPercent: state.petRemainingPercent)
        ))
        guard force || wanted != currentAnimation else { return }
        guard let resolved = sheet.resolved(wanted) else { return }

        currentAnimation = wanted
        frames = resolved
        frameIndex = 0
        scheduleNextFrame()
        needsDisplay = true
    }

    /// 프레임 유지시간을 활력 배수로 나눈다 — 잔량이 낮을수록 한 프레임을 오래 붙잡고 있어 느려진다.
    private func scheduleNextFrame() {
        frameTimer?.invalidate()
        guard let frames, !frames.durationsMs.isEmpty else { return }

        let speed = max(0.1, PetVitality(remainingPercent: state.petRemainingPercent).speedMultiplier)
        let holdMs = frames.durationsMs[frameIndex % frames.durationsMs.count] / speed
        let timer = Timer(timeInterval: holdMs / 1000.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func advanceFrame() {
        guard let frames, !frames.images.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.images.count
        needsDisplay = true
        scheduleNextFrame()
    }

    // MARK: - 마우스

    /// 커서 위치를 직접 읽어 호버를 판정하고, 펫 바깥이면 창을 클릭 통과시킨다.
    ///
    /// tracking area 를 쓰지 않는 이유: 이 창은 key 가 되지 않아 `mouseMoved` 가 오지 않고,
    /// 투명한 여백에서 아래 앱의 클릭을 삼키지 않으려면 커서가 창 **밖**에 있을 때도 판정을
    /// 계속해야 한다. `NSEvent.mouseLocation` 은 모니터 없이 언제든 읽을 수 있다.
    private func updatePointerState() {
        guard let window else { return }

        if dragging || interactionLocked {
            window.ignoresMouseEvents = false
            return
        }

        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let inside = interactiveArea().contains(local)
        hovering = inside
        window.ignoresMouseEvents = !inside
    }

    /// 마우스를 받는 영역: 스프라이트 몸통 + 수치 패널. 나머지 투명 여백은 통과시킨다.
    private func interactiveArea() -> NSBezierPath {
        let sprite = spriteRect()
        let body = sprite.insetBy(dx: Self.spriteSize * 0.16, dy: Self.spriteSize * 0.12)
        let path = NSBezierPath(roundedRect: body, xRadius: 12, yRadius: 12)
        if !lastHUDRect.isEmpty {
            path.append(NSBezierPath(roundedRect: lastHUDRect, xRadius: 8, yRadius: 8))
        }
        return path
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        dragDirection = nil
        dragBaselineX = event.locationInWindow.x
        dragOffset = CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)
        applyAnimation()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let window else { return }

        let deltaX = event.locationInWindow.x - dragBaselineX
        let (direction, accepted) = nextPetDragDirection(current: dragDirection, deltaX: deltaX)
        if accepted {
            dragDirection = direction
            dragBaselineX = event.locationInWindow.x
            applyAnimation()
        }

        let pointInScreen = window.convertPoint(toScreen: event.locationInWindow)
        onRequestWindowMove?(CGPoint(
            x: pointInScreen.x - dragOffset.x,
            y: pointInScreen.y - dragOffset.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        dragDirection = nil
        applyAnimation()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(convert(event.locationInWindow, from: nil))
    }

    // MARK: - 그리기

    /// 스프라이트는 창 위쪽에, 패널은 그 바로 아래에 붙는다.
    private func spriteRect() -> NSRect {
        NSRect(
            x: bounds.midX - Self.spriteSize / 2,
            y: bounds.maxY - Self.spriteSize,
            width: Self.spriteSize,
            height: Self.spriteSize
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let sprite = spriteRect()
        if let frames, frames.images.indices.contains(frameIndex) {
            frames.images[frameIndex].draw(
                in: sprite,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
        lastHUDRect = PetHUD.draw(
            hudContent(),
            centerX: bounds.midX,
            // 스프라이트 하단에 살짝 겹치게 붙인다 — 캐릭터 발밑 여백이 비어 있어 잘려 보이지 않는다.
            topY: sprite.minY + Self.spriteSize * 0.10,
            maxWidth: bounds.width
        )
    }

    private func hudContent() -> PetHUDContent {
        var countdown: String?
        if let nextAt = state.nextClaudeRefreshAt {
            let remaining = nextAt.timeIntervalSinceNow
            if remaining >= 0, remaining <= PetHUD.countdownLeadTime {
                countdown = PetHUD.countdownText(secondsRemaining: remaining)
            }
        }
        let showSystem = hovering || interactionLocked
        return PetHUDContent(
            claudeText: state.claudeText,
            claudeWarn: state.claudeWarn,
            countdownText: countdown,
            isRefreshing: state.isRefreshing,
            cpuText: showSystem ? state.cpuText : nil,
            memText: showSystem ? state.memText : nil
        )
    }
}
