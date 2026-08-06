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
3. 첫 갱신에서 Keychain 대화상자가 한 번 뜨면 **"항상 허용"** 을 누른다(아래 참조).

## 인증 / Keychain 팝업

### 자격증명 조회 순서

1. **VinceStat 자체 Keychain 항목** (`com.vince.vincestat.token`) — 생성자가 VinceStat
   자신이라 읽을 때 대화상자가 뜨지 않는다.
2. `~/.claude/.credentials.json` (파일 저장 방식을 쓰는 머신)
3. **Claude Code Keychain 항목**(`Claude Code-credentials`) — 대화상자가 뜰 수 있는 유일한
   경로. 여기서 읽은 토큰은 곧바로 1번 항목에 복사(미러)해 두므로, 그 토큰이 만료될 때까지
   다시 묻지 않는다.

고정 코드서명 identity는 별개의 필요 조건이다. ad-hoc 서명은 빌드마다 서명이 달라져
macOS가 새 빌드를 다른 앱으로 취급하므로, `./setup-signing.sh` 로 만든 "VinceStat Signing"
identity 로 서명해야 1번 항목 접근과 3번의 "항상 허용"이 재빌드 후에도 유지된다.

### 팝업은 ↻ 를 누를 때만 뜬다

미러 토큰이 만료되면 3번 경로를 다시 타야 하는데, **자동 갱신(타이머·앱 시작)은 3번을 아예
읽지 않는다.** 조용히 로컬 JSONL 추정 모드로 내려갈 뿐이다. 3번 조회는 사용자가 대시보드에서
↻ 를 누른 경우(`refreshClaude(userInitiated: true)`)에만 일어난다. 오랜만에 앱을 볼 때
예고 없이 암호 창이 튀어나오는 걸 막기 위한 설계다.

### "항상 허용"은 유지되는가

유지된다고 보인다. 이전 README는 "Claude Code가 토큰 갱신마다 항목을 삭제·재생성해서 ACL이
날아간다"고 적었지만, 실제 항목 속성은 그렇지 않다 — 2026-08-06 기준 `Claude Code-credentials`
의 `cdat`(생성)은 2026-07-09, `mdat`(수정)은 당일이다. 즉 **한 달째 같은 항목을 제자리에서
갱신**하고 있고, 그렇다면 ACL도 함께 남는다. 대화상자에서 "허용"이 아니라 **"항상 허용"** 을
눌렀는지 확인할 것.

(그래도 위의 "↻ 를 누를 때만" 정책은 유지한다. ACL이 어떤 이유로 무효화돼도 최악의 경우가
"내가 누를 때만 묻는다"에서 그치기 때문이다.)

### 하면 안 되는 것: `claude setup-token` 장기 토큰

대시보드 인증 탭에 입력란이 남아 있지만 **쓰지 말 것.** 그 토큰(`sk-ant-oat01-…`)은 인증은
통과하지만 usage API가 **상시 429로 거절**한다(2026-08-06 확인 — 3시간 연속 429, 미러 토큰으로
되돌리자 즉시 200). 넣으면 팝업은 사라지지만 숫자가 추정 모드로만 나온다. 이 상태를 일시적
레이트리밋과 헷갈리지 않도록 별도 오류 메시지(`manualTokenUnsupported`)로 구분해 표시한다.

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
