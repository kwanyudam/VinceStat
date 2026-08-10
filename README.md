# VinceStat

macOS 메뉴바에 세 가지 수치를 상시 표시하는 개인용 상태바 앱.

```
 42%  18.3G  ✳ 71%
 CPU   MEM   Claude 5h 블록 잔여
```

## 기능

- **CPU / 메모리**: Mach 호출(`host_statistics`)로 3초마다 샘플링. 권한 불필요.
- **Claude 잔여**: OAuth 자격증명으로 usage API를 조회해 5시간 블록 잔여 %를 표시. 기본 5분 주기이며 대시보드에서 1–30분으로 조정 가능.
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
3. 메뉴바 → **인증 → "Anthropic 계정으로 로그인"** 을 한 번 누른다. 이후 Keychain 대화상자는
   뜨지 않는다(아래 참조).

## 인증 / Keychain 팝업

### 권장: 자체 OAuth 로그인 (팝업이 영구히 사라진다)

대시보드 **인증 → "Anthropic 계정으로 로그인"** 을 한 번 누르면 VinceStat이 자기 이름으로
access/refresh 토큰 쌍을 발급받아 자체 Keychain 항목(`com.vince.vincestat.oauth`)에 넣는다.
이후에는 만료 5분 전에 refresh token으로 스스로 갱신하므로

- `Claude Code-credentials` 항목을 **다시 읽지 않는다** → 허용 대화상자가 뜰 일이 없다.
- Claude Code의 토큰을 빌려 쓰지 않으니 refresh token 로테이션이 **Claude Code 로그인
  세션을 건드리지 않는다**.

플로우는 Claude Code와 같은 public 클라이언트 + PKCE(S256)다.

플로우 파라미터는 Claude Code 2.1.226 바이너리의 로그인 경로에서 확인한 값이다
(`CLIENT_ID`, `CLAUDE_AI_AUTHORIZE_URL`, `TOKEN_URL`, `MANUAL_REDIRECT_URL`).

| 항목 | 값 |
| --- | --- |
| client_id | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` — **UUID 여야 한다.** client-id metadata document URL(`https://claude.ai/oauth/claude-code-client-metadata`)을 넣으면 `Input should be a valid UUID` 로 거절된다 |
| authorize | `https://claude.com/cai/oauth/authorize` (Claude 구독 계정용. 콘솔 계정은 `https://platform.claude.com/oauth/authorize`) |
| token | `https://platform.claude.com/v1/oauth/token` (JSON POST) |
| redirect_uri | `http://localhost:54545/callback` — Claude Code 와 같은 포트를 먼저 쓰고, 점유돼 있으면 임의 포트로 물러난다. 앱이 루프백에 1회용 HTTP 리스너를 띄운다 (IPv4/IPv6 둘 다 응답) |
| scope | `user:profile user:inference` (Claude Code 는 `org:create_api_key` 등을 더 요청하지만 상태 표시에 필요 없어 받지 않는다) |
| 기타 | authorize 에 `code=true` 를 반드시 붙인다. refresh 요청에는 `scope` 를 함께 보낸다 |

리다이렉트가 돌아오지 않는 환경이면 **인증 → "브라우저가 되돌아오지 않을 때"** 를 펼쳐
`https://platform.claude.com/oauth/code/callback` 로 받은 코드(`code#state`)를 붙여넣는
폴백 경로를 쓴다.

refresh token이 죽으면(`invalid_grant`) 항목을 지우지 않고 refresh만 비워서 대시보드가
"로그인이 만료됨 — 다시 로그인해 주세요"를 구분해 보여준다. 그 상태에서도 아래 폴백 경로로
숫자는 계속 나온다.

### 자격증명 조회 순서

0. **자체 OAuth 토큰** (`com.vince.vincestat.oauth`) — 만료 임박 시 refresh. 팝업 없음.
1. **자체 미러 항목** (`com.vince.vincestat.token`) — 생성자가 VinceStat 자신이라 팝업 없음.
2. `~/.claude/.credentials.json` (파일 저장 방식을 쓰는 머신)
3. **Claude Code Keychain 항목**(`Claude Code-credentials`) — 대화상자가 뜰 수 있는 유일한
   경로. 여기서 읽은 토큰은 곧바로 1번 항목에 복사(미러)해 두므로, 그 토큰이 만료될 때까지
   다시 묻지 않는다.

0번이 살아 있으면 1~3번은 아예 실행되지 않는다. 1~3번은 로그인하지 않았을 때의 폴백이다.

고정 코드서명 identity는 별개의 필요 조건이다. ad-hoc 서명은 빌드마다 서명이 달라져
macOS가 새 빌드를 다른 앱으로 취급하므로, `./setup-signing.sh` 로 만든 "VinceStat Signing"
identity 로 서명해야 0·1번 항목 접근이 재빌드 후에도 유지된다.

### 폴백 경로에서 팝업은 ↻ 를 누를 때만 뜬다

로그인하지 않은 상태에서 미러 토큰이 만료되면 3번 경로를 다시 타야 하는데, **자동 갱신
(타이머·앱 시작)은 3번을 아예 읽지 않는다.** 조용히 로컬 JSONL 추정 모드로 내려갈 뿐이다.
3번 조회는 사용자가 대시보드에서 ↻ 를 누른 경우(`refreshClaude(userInitiated: true)`)에만
일어난다.

### "항상 허용"이 왜 다시 물어보는가

확실하지 않다. 항목 속성만 보면 유지될 것처럼 보인다 — 2026-08-10 기준
`Claude Code-credentials` 의 `cdat`(생성)은 2026-07-09, `mdat`(수정)은 당일이라 **한 달째
같은 항목을 제자리에서 갱신**하고 있고, Claude Code는 `security add-generic-password -U` 로
쓴다. 그런데도 팝업이 재발한다면 그 `-U` 갱신이 ACL/파티션 목록을 다시 쓰는 것으로 보인다.

원인을 더 파지 않고 **3번 경로 자체에 의존하지 않는 쪽(위의 자체 OAuth 로그인)으로 해결**했다.
확인하고 싶으면: `security dump-keychain -a ~/Library/Keychains/login.keychain-db` 출력에서
`Claude Code-credentials` 항목의 trusted application 목록을 본다.

### 하면 안 되는 것: `claude setup-token` 장기 토큰

대시보드 인증 탭에 입력란이 남아 있지만 **쓰지 말 것.** 그 토큰(`sk-ant-oat01-…`)은 인증은
통과하지만 usage API가 **상시 429로 거절**한다(2026-08-06 확인 — 3시간 연속 429, 미러 토큰으로
되돌리자 즉시 200). 원인으로 보이는 것은 **스코프**다: Claude Code 로그인은
`user:profile user:inference user:sessions:claude_code user:mcp_servers` 를 받는데
setup-token은 `user:inference` 계열만 받고, usage API는 `user:profile` 을 요구한다.
그래서 자체 OAuth 로그인은 `user:profile` 을 포함해 요청한다.

### 거부했을 때

대화상자에서 "거부"를 누르면 그 사실을 기억해 **자동 갱신에서는 다시 묻지 않는다**
(로컬 추정 모드로 동작). 다시 시도하려면 대시보드의 갱신 버튼(↻)이나
**인증 → 다시 시도**를 누른다 — 사용자가 명시적으로 요청한 경우에만 묻는다.
애초에 묻지 않게 하려면 자체 OAuth 로그인을 하면 된다.

## 구조

```
Sources/VinceStat/
├── VinceStatApp.swift        # MenuBarExtra 진입점
├── AppState.swift            # @Observable 상태 + 타이머 + 메뉴바 텍스트 조립
├── SystemStatsService.swift  # CPU/메모리 샘플러 (Mach)
├── ClaudeUsageService.swift  # usage API + 자격증명 조회 순서 + JSONL 추정 폴백
├── OAuthService.swift        # 자체 OAuth 로그인 (PKCE + 루프백 콜백 서버) + refresh
├── TokenStore.swift          # VinceStat 자체 Keychain 항목 (팝업 없는 토큰 보관소)
└── DashboardView.swift       # 팝오버 대시보드 (SwiftUI)
Support/Info.plist            # LSUIElement 등 번들 메타
build.sh                      # .app 번들 생성 스크립트 (고정 identity 서명, 없으면 ad-hoc)
setup-signing.sh              # 코드서명용 자체 인증서 생성/등록 (머신당 최초 1회)
```

## 알려진 한계

- usage API(`api.anthropic.com/api/oauth/usage`)는 비공식이라 스키마가 바뀔 수 있다. 파서는 방어적으로 작성했고 실패 시 추정 폴백이 동작한다.
- **자체 OAuth 토큰만** 스스로 리프레시한다. 폴백 경로의 미러 토큰(Claude Code에서 복사한 것)은 리프레시하지 않는다 — Claude Code의 토큰 로테이션과 충돌하지 않기 위해서다. 그 경우 Claude Code를 한 번 실행하면 갱신된다.
- 자체 OAuth 토큰이 usage API에서 429로 거절될 가능성은 남아 있다(스코프 가설이 틀렸을 경우). 그때는 폴백 경로가 그대로 동작하고, 인증 탭에서 로그아웃하면 예전 동작으로 돌아간다.
- 로컬 추정치는 5시간 윈도우 내 토큰 합산일 뿐 실제 플랜 한도 대비 %가 아니다.
