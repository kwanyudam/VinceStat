import Foundation

/// Claude 5시간 블록 잔여량을 펫의 "활력"으로 바꾸는 규칙. 그리기·타이머와 무관한 순수 계산이라
/// 여기만 보면 잔여 몇 %에서 펫이 얼마나 느려지는지 전부 알 수 있다.
///
/// 설계 의도: 잔량이 줄어드는 것을 숫자가 아니라 **움직임의 둔함**으로 먼저 알아채게 한다.
/// 그래서 임계값에서 뚝 끊기지 않고 60% 아래부터 서서히 느려지되, 30% 이하에서는 기울기를
/// 급하게 꺾어 "확실히 이상하다"가 눈에 들어오게 했다.
struct PetVitality {
    /// 이 값 이하면 `isSluggish` — 눈에 띄게 느려지고 채도도 빠진다.
    static let sluggishThreshold: Double = 30
    /// 여기까지는 정상 속도. 60% 아래부터 완만하게 둔해지기 시작한다.
    static let healthyThreshold: Double = 60
    /// 이 값 이하면 `isExhausted` — 눈이 감기고 거의 기어다닌다.
    static let exhaustedThreshold: Double = 10

    static let normalSpeed: Double = 1.0
    /// `sluggishThreshold`(30%) 지점의 속도.
    static let sluggishSpeed: Double = 0.7
    /// 잔여 0% 지점의 속도. 완전히 멈추면 죽은 것처럼 보이므로 바닥을 남겨 둔다.
    static let floorSpeed: Double = 0.25

    /// 5시간 블록 잔여 %. `nil` 이면 아직 모르거나(첫 조회 전) 로컬 추정 모드다 —
    /// 추정 모드는 플랜 한도 대비 %를 알 수 없으므로 활력을 깎지 않는다.
    let remainingPercent: Double?

    init(remainingPercent: Double?) {
        self.remainingPercent = remainingPercent.map { min(100, max(0, $0)) }
    }

    /// 잔여를 모를 때는 정상으로 취급한다 — 데이터가 없다는 이유로 펫을 느리게 만들면
    /// 사용자가 "잔량이 떨어졌다"로 오독한다.
    var isSluggish: Bool {
        guard let remainingPercent else { return false }
        return remainingPercent <= Self.sluggishThreshold
    }

    var isExhausted: Bool {
        guard let remainingPercent else { return false }
        return remainingPercent <= Self.exhaustedThreshold
    }

    /// 애니메이션 재생 속도 배수. 프레임 진행량에 그대로 곱한다.
    ///
    /// - 60% 이상: 1.0 (변화 없음)
    /// - 60 → 30%: 1.0 → 0.7 로 선형 감소 (완만하게 둔해짐)
    /// - 30 → 0%: 0.7 → 0.25 로 선형 감소 (기울기가 2배 이상 가팔라짐)
    var speedMultiplier: Double {
        guard let remainingPercent else { return Self.normalSpeed }

        if remainingPercent >= Self.healthyThreshold {
            return Self.normalSpeed
        }
        if remainingPercent >= Self.sluggishThreshold {
            let span = Self.healthyThreshold - Self.sluggishThreshold
            let t = (remainingPercent - Self.sluggishThreshold) / span  // 0…1
            return Self.sluggishSpeed + (Self.normalSpeed - Self.sluggishSpeed) * t
        }
        let t = remainingPercent / Self.sluggishThreshold  // 0…1
        return Self.floorSpeed + (Self.sluggishSpeed - Self.floorSpeed) * t
    }

    /// 지친 정도 0…1 (0 = 멀쩡, 1 = 완전히 지침). 채도·눈꺼풀·처짐에 함께 쓴다.
    var fatigue: Double {
        guard let remainingPercent else { return 0 }
        guard remainingPercent < Self.healthyThreshold else { return 0 }
        return 1 - (remainingPercent / Self.healthyThreshold)
    }
}
