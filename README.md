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
3. 대시보드 → **인증**에서 장기 토큰을 넣어 둔다(아래 참조). 그러면 Keychain 팝업이 아예 뜨지 않는다.

## 인증 / Keychain 팝업

### 팝업이 반복해서 뜨는 이유

Claude Code는 자격증명을 Keychain 항목 `Claude Code-credentials`에 저장하는데, **토큰을
갱신할 때마다 그 항목을 삭제하고 다시 만든다.** 항목이 새로 생기면 ACL도 새로 생기므로
직전에 누른 "항상 허용"이 같이 날아가고, 다음 폴링에서 대화상자가 다시 뜬다.
즉 이 항목의 ACL에 의존하는 한 "한 번만 허용"은 원리적으로 불가능하다.

(고정 코드서명 identity는 별개의 필요 조건이다. ad-hoc 서명은 빌드마다 서명이 달라져
macOS가 새 빌드를 다른 앱으로 취급하므로, `./setup-signing.sh` 로 만든
"VinceStat Signing" identity 로 서명해야 VinceStat 자체 Keychain 항목 접근도 유지된다.)

### 해결: 자체 토큰 보관

VinceStat은 자격증명을 다음 순서로 찾는다. 1~3은 팝업이 뜨지 않는다.

1. **VinceStat 자체 Keychain 항목** (`com.vince.vincestat.token`) — 생성자가 VinceStat
   자신이라 읽을 때 대화상자가 뜨지 않는다.
2. `~/.claude/.credentials.json` (파일 저장 방식을 쓰는 머신)
3. **Claude Code Keychain 항목** — 대화상자가 뜰 수 있는 유일한 경로. 여기서 읽은 토큰은
   곧바로 1번 항목에 복사해 두므로, 그 토큰이 만료될 때까지 다시 묻지 않는다.

팝업을 완전히 없애려면 만료가 긴 토큰을 한 번 넣어 두면 된다.

```sh
claude setup-token    # 출력된 토큰을 복사
```

대시보드 → **인증** → 토큰 붙여넣기 → 저장. 이후 VinceStat은 1번 경로만 쓰므로
Claude Code Keychain 항목을 건드리지 않는다. Claude Code 자신의 토큰 로테이션과도
분리되어 서로 간섭하지 않는다.

### 거부했을 때

대화상자에서 "거부"를 누르면 그 사실을 기억해 **자동 갱신에서는 다시 묻지 않는다**
(로컬 추정 모드로 동작). 다시 시도하려면 대시보드의 갱신 버튼(↻)이나
**인증 → 다시 시도**를 누른다 — 사용자가 명시적으로 요청한 경우에만 묻는다.

## 구조

```
Sources/VinceStat/
├── VinceStatApp.swift        # MenuBarExtra 진입점
├── AppState.swift            # @Observable 상태 + 타이머 + 메뉴바 텍스트 조립
├── SystemStatsService.swift  # CPU/메모리 샘플러 (Mach)
├── ClaudeUsageService.swift  # usage API + 자격증명 조회 순서 + JSONL 추정 폴백
├── TokenStore.swift          # VinceStat 자체 Keychain 항목 (팝업 없는 토큰 보관소)
└── DashboardView.swift       # 팝오버 대시보드 (SwiftUI)
Support/Info.plist            # LSUIElement 등 번들 메타
build.sh                      # .app 번들 생성 스크립트 (고정 identity 서명, 없으면 ad-hoc)
setup-signing.sh              # 코드서명용 자체 인증서 생성/등록 (머신당 최초 1회)
```

## 알려진 한계

- usage API(`api.anthropic.com/api/oauth/usage`)는 비공식이라 스키마가 바뀔 수 있다. 파서는 방어적으로 작성했고 실패 시 추정 폴백이 동작한다.
- OAuth 토큰이 만료된 경우 직접 리프레시하지 않는다(Claude Code의 토큰 로테이션과 충돌 방지). Claude Code를 한 번 실행하면 갱신된다.
- 로컬 추정치는 5시간 윈도우 내 토큰 합산일 뿐 실제 플랜 한도 대비 %가 아니다.
