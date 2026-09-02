import Foundation

/// `pet.json` 이 선언한 애니메이션 이름. 원시값이 곧 매니페스트의 키다.
enum PetAnimationName: String {
    /// 평상시 — 정면(얼굴이 보이는 쪽). 시트의 row 4.
    case jumping
    /// 마우스 호버 — 반대편으로 돌아선다(등이 보이는 쪽). 시트의 row 3.
    case waving
    /// 잠듦 스킨(어둡게) — 잔량이 떨어져 졸기 시작.
    case idle
    /// 얼음 스킨 — 잔량이 거의 없어 얼어붙음.
    case waiting
    /// Claude 갱신 중 — 정면으로 종종거림.
    case running
    case runningRight = "running-right"
    case runningLeft = "running-left"
}

/// 지금 어떤 애니메이션을 재생할지 고르는 순수 함수. 뷰·타이머와 분리해 두어
/// "언제 어떤 그림이 나오는가" 규칙이 이 파일 하나에만 있게 한다.
///
/// 우선순위는 조작 → 작업 → 잔량 순이다. 사용자가 만지고 있을 때는 그 반응이 먼저 보여야 하고,
/// 잔량은 가만히 두었을 때 드러나면 충분하다.
///
/// 잔량 단계에 리아코 시트에 이미 구워져 있는 상태이상 스킨을 그대로 쓴다 —
/// 30% 이하는 졸음(어두운 idle), 10% 이하는 얼음(waiting). 속도 배수(`PetVitality`)와 겹쳐서
/// "느려진다 → 존다 → 얼어붙는다" 로 읽힌다.
///
/// 방향: 기본은 얼굴이 보이는 정면(`jumping` 행)이고, 마우스를 올리면 반대편으로 돌아선다
/// (`waving` 행 — 등이 보이는 쪽). 시트의 행 이름은 Orca 펫 규약을 따른 것이라 여기서 쓰는
/// 의미와 다르다 — 이름이 아니라 실제 그림의 방향을 기준으로 골랐다.
struct PetAnimationInput {
    var dragging = false
    /// 드래그 방향. `nil` 이면 아직 방향이 잡히지 않았다.
    var dragDirection: PetDragDirection?
    var hovering = false
    var refreshing = false
    var vitality = PetVitality(remainingPercent: nil)
}

enum PetDragDirection {
    case left
    case right
}

func selectPetAnimation(_ input: PetAnimationInput) -> PetAnimationName {
    if input.dragging {
        switch input.dragDirection {
        case .right: return .runningRight
        case .left: return .runningLeft
        case nil: return .running
        }
    }
    if input.hovering { return .waving }
    if input.refreshing { return .running }
    if input.vitality.isExhausted { return .waiting }
    if input.vitality.isSluggish { return .idle }
    return .jumping
}

/// 4pt 이상 수평으로 움직였을 때만 방향을 바꾼다 — 손떨림에 좌우로 파닥이지 않게.
/// (Orca 의 `nextPetDragAnimation` 과 같은 규칙)
func nextPetDragDirection(
    current: PetDragDirection?,
    deltaX: CGFloat
) -> (direction: PetDragDirection?, accepted: Bool) {
    if deltaX >= 4 { return (.right, true) }
    if deltaX <= -4 { return (.left, true) }
    return (current, false)
}
