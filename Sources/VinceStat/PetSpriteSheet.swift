import AppKit
import CoreGraphics

/// 재생 가능한 애니메이션 한 벌 — 미리 잘라 둔 프레임 이미지와 프레임별 유지시간.
struct PetSpriteAnimation {
    let images: [NSImage]
    let durationsMs: [Double]
}

/// `spritesheet.png` + `pet.json` 을 읽어 애니메이션별 프레임으로 잘라 두는 로더.
///
/// 매 틱 배경 위치를 계산하지 않고 미리 잘라 배열로 들고 있는다 — 펫은 프레임 수가 적어서
/// (9행 × 4칸) 전부 잘라 둬도 메모리가 문제되지 않고, 그리기가 배열 인덱싱 한 번으로 끝난다.
final class PetSpriteSheet {
    /// 번들에 들어 있는 리아코 시트. 로딩 실패는 곧 리소스 누락이라 앱 시작 시 한 번만 시도한다.
    static let bundled: PetSpriteSheet? = {
        guard
            let sheetURL = Bundle.module.url(forResource: "spritesheet", withExtension: "png"),
            let manifestURL = Bundle.module.url(forResource: "pet", withExtension: "json")
        else {
            petDebugLog("번들에서 spritesheet.png / pet.json 을 찾지 못했습니다")
            return nil
        }
        do {
            return try PetSpriteSheet(manifestURL: manifestURL, spritesheetURL: sheetURL)
        } catch {
            petDebugLog("스프라이트 로딩 실패: \(error)")
            return nil
        }
    }()

    let manifest: PetManifest
    private let sheet: CGImage
    private var cache: [String: PetSpriteAnimation] = [:]

    init(manifestURL: URL, spritesheetURL: URL) throws {
        manifest = try PetManifest.load(from: manifestURL)
        let data = try Data(contentsOf: spritesheetURL)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        sheet = image
    }

    /// 이름으로 애니메이션을 꺼낸다. 처음 요청할 때만 잘라서 캐시한다.
    func animation(named name: String) -> PetSpriteAnimation? {
        if let cached = cache[name] { return cached }
        guard let spec = manifest.animations[name] else { return nil }

        let frameW = manifest.frame.width
        let frameH = manifest.frame.height
        var images: [NSImage] = []
        images.reserveCapacity(spec.frames)

        for column in 0..<spec.frames {
            let rect = CGRect(x: column * frameW, y: spec.row * frameH, width: frameW, height: frameH)
            guard let cropped = sheet.cropping(to: rect) else { continue }
            images.append(NSImage(cgImage: cropped, size: NSSize(width: frameW, height: frameH)))
        }
        guard !images.isEmpty else { return nil }

        let durations = spec.frameDurationsMs
            ?? Array(repeating: 1000.0 / manifest.fps, count: images.count)
        let animation = PetSpriteAnimation(images: images, durationsMs: durations)
        cache[name] = animation
        return animation
    }

    /// 요청한 이름이 시트에 없으면 `defaultAnimation` → 첫 번째 애니메이션 순으로 물러난다.
    /// 다른 `.codex-pet` 번들로 갈아끼웠을 때 이름이 달라도 최소한 뭔가는 그려지게 하기 위함이다.
    func resolved(_ name: PetAnimationName) -> PetSpriteAnimation? {
        if let exact = animation(named: name.rawValue) { return exact }
        if let fallbackName = manifest.defaultAnimation,
           let fallback = animation(named: fallbackName) {
            return fallback
        }
        if let firstKey = manifest.animations.keys.sorted().first {
            return animation(named: firstKey)
        }
        return nil
    }
}
