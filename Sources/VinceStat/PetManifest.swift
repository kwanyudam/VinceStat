import Foundation

/// `.codex-pet` 번들의 `pet.json` 매니페스트. Orca 의 `pet-bundle-manifest-schema.ts` 와 같은 모양이라,
/// 다른 `.codex-pet` 번들을 가져다 `Resources/` 의 두 파일만 갈아끼워도 그대로 돈다.
struct PetManifest: Codable {
    struct Frame: Codable {
        let width: Int
        let height: Int
    }

    /// 스프라이트시트의 한 줄(row)에 놓인 애니메이션 한 벌.
    struct Animation: Codable {
        /// 0부터 세는 y 인덱스.
        let row: Int
        /// 왼쪽부터 순서대로 재생할 칸 수.
        let frames: Int
        /// 프레임별 유지시간(ms). 없으면 시트 공통 `fps` 를 쓴다.
        let frameDurationsMs: [Double]?
    }

    let id: String?
    let displayName: String?
    let description: String?
    let spritesheetPath: String?
    let frame: Frame
    let fps: Double
    let defaultAnimation: String?
    let animations: [String: Animation]

    static func load(from url: URL) throws -> PetManifest {
        try JSONDecoder().decode(PetManifest.self, from: Data(contentsOf: url))
    }
}
