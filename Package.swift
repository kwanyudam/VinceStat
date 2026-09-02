// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VinceStat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VinceStat",
            path: "Sources/VinceStat",
            resources: [
                // 펫 스프라이트 번들 (.codex-pet 포맷). build.sh 가 생성된 리소스 번들을
                // .app/Contents/Resources 로 복사해야 Bundle.module 이 찾는다.
                .copy("Resources/spritesheet.png"),
                .copy("Resources/pet.json")
            ]
        )
    ]
)
