# VinceStat

macOS 메뉴바에 세 가지 수치를 상시 표시하는 개인용 상태바 앱.

```
 42%  18.3G  ✳ 71%
 CPU   MEM   Claude 5h 블록 잔여
```

## 기능

- **CPU / 메모리**: Mach 호출(`host_statistics`)로 3초마다 샘플링. 권한 불필요.
- **Claude 잔여**: Claude Code의 OAuth 자격증명으로 usage API를 조회해 5시간 블록 잔여 %를 표시. 기본 5분 주기이며 대시보드에서 1–30분으로 조정 가능.
  - API 조회 실패 시(토큰 만료, 스키마 변경 등) `~/.claude/projects/**/*.jsonl`을 파싱해 최근 5시간 사용 토큰 추정치(`✳ ~1.2M`)로 폴백.
- **대시보드**(메뉴바 클릭): 5시간/주간/Opus 게이지 + 리셋 시각, CPU·메모리 스파크라인(최근 5분), 갱신 주기·경고 임계값 설정, 지금 갱신, 로그인 시 시작.
- 경고 임계값(기본 80%) 초과 시 메뉴바에 `⚠` 표시.

## 빌드 / 실행

```sh
./setup-signing.sh    # 최초 1회 (머신당): 코드서명용 자체 인증서 생성/등록
./build.sh            # dist/VinceStat.app 생성
./build.sh install    # /Applications 에 복사까지
open dist/VinceStat.app
```

개발 중에는 `swift run` 으로도 실행 가능 (독 아이콘 없이 메뉴바에만 뜸).

### 새 머신에서 셋업 (git clone/pull 후)

1. `./setup-signing.sh` — "VinceStat Signing" 자체 인증서를 생성해 로그인 키체인에 등록한다.
   신뢰 등록 단계에서 macOS 암호 확인 창이 한 번 뜰 수 있다.
2. `./build.sh install` — 인증서가 있으면 자동으로 고정 서명, 없으면 ad-hoc 서명으로 폴백.
3. 앱 실행 후 Keychain 허용 팝업에서 **"항상 허용"** — 이후로는 재빌드해도 다시 묻지 않는다.

## Keychain 안내

Claude Code는 자격증명을 Keychain 항목 `Claude Code-credentials`에 저장한다.
VinceStat이 처음 이를 읽을 때 macOS 허용 대화상자가 뜨며, **"항상 허용"**을 눌러야
이후 갱신 때 다시 묻지 않는다. 거부하면 로컬 추정 모드로만 동작한다.

ad-hoc 서명(`codesign --sign -`)은 빌드마다 서명이 달라져 macOS가 새 빌드를 다른 앱으로
취급하므로 "항상 허용"이 유지되지 않는다. `./setup-signing.sh` 로 만든 고정 identity
("VinceStat Signing")로 서명하면 서명 주체가 동일해 재빌드 후에도 권한이 유지된다.

## 구조

```
Sources/VinceStat/
├── VinceStatApp.swift        # MenuBarExtra 진입점
├── AppState.swift            # @Observable 상태 + 타이머 + 메뉴바 텍스트 조립
├── SystemStatsService.swift  # CPU/메모리 샘플러 (Mach)
├── ClaudeUsageService.swift  # usage API + Keychain/파일 자격증명 + JSONL 추정 폴백
└── DashboardView.swift       # 팝오버 대시보드 (SwiftUI)
Support/Info.plist            # LSUIElement 등 번들 메타
build.sh                      # .app 번들 생성 스크립트 (고정 identity 서명, 없으면 ad-hoc)
setup-signing.sh              # 코드서명용 자체 인증서 생성/등록 (머신당 최초 1회)
```

## 알려진 한계

- usage API(`api.anthropic.com/api/oauth/usage`)는 비공식이라 스키마가 바뀔 수 있다. 파서는 방어적으로 작성했고 실패 시 추정 폴백이 동작한다.
- OAuth 토큰이 만료된 경우 직접 리프레시하지 않는다(Claude Code의 토큰 로테이션과 충돌 방지). Claude Code를 한 번 실행하면 갱신된다.
- 로컬 추정치는 5시간 윈도우 내 토큰 합산일 뿐 실제 플랜 한도 대비 %가 아니다.
