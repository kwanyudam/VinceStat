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
- **데스크톱 펫**(대시보드에서 켜기/끄기): 화면에 떠 있는 리아코가 발밑에 Claude 잔여를 띄우고, 잔여가 줄면 느려지다가 졸고 얼어붙는다. 마우스오버하면 CPU·MEM 이 펼쳐지고, 우클릭하면 대시보드가 뜬다. 아래 "데스크톱 펫" 참고.

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
├── DashboardView.swift       # 팝오버 대시보드 (SwiftUI)
├── PetController.swift       # 펫 창 수명 관리 + 우클릭 대시보드 팝오버
├── PetWindow.swift           # 테두리 없는 투명 always-on-top 창
├── PetView.swift             # 프레임 재생 + 마우스 조작 + AppState 읽기
├── PetSpriteSheet.swift      # spritesheet.png 를 애니메이션별 프레임으로 슬라이스
├── PetManifest.swift         # pet.json (.codex-pet 매니페스트) 파서
├── PetAnimation.swift        # 상황 → 재생할 행 + 덧입힐 스킨 선택 (순수 함수)
├── PetSkin.swift             # 졸음·얼음 스킨을 런타임에 입히는 렌더러
├── PetHUD.swift              # 발밑 수치 패널 + 갱신 카운트다운
├── PetVitality.swift         # Claude 잔여 % → 재생 속도 배수 (순수 계산)
├── PetDebugLog.swift         # VINCESTAT_PET_DEBUG 진단 로그
└── Resources/                # spritesheet.png + pet.json (리아코 번들)
Support/Info.plist            # LSUIElement 등 번들 메타
build.sh                      # .app 번들 생성 스크립트 (고정 identity 서명, 없으면 ad-hoc)
setup-signing.sh              # 코드서명용 자체 인증서 생성/등록 (머신당 최초 1회)
```

## 데스크톱 펫 (리아코)

대시보드의 **펫 표시** 스위치로 켠다. 켜면 화면에 리아코(Totodile)가 떠서 모든 Space 에서 다른 창
위에 보이고, 드래그해서 어디로든(다른 모니터 포함) 옮길 수 있다. 위치는 기억한다. 끄면 창뿐 아니라
재생 타이머까지 없앤다.

메뉴바 숫자는 메뉴바를 봐야 읽히고, 대시보드 게이지는 열어야 보인다. 펫은 그 사이를 메운다 —
**시선을 주지 않아도 주변시로 잡히는 채널**이라서, 잔량이 줄었다는 걸 숫자가 아니라 움직임의
둔함과 표정으로 먼저 알아채게 하는 것이 목적이다.

스프라이트는 [connor-pet](https://github.com/Connor-Supplies/connor-pet) 의
`totodile.codex-pet` 번들(800×1800, 4칸 × 9행, 프레임 200×200)을 그대로 가져왔다.
`Sources/VinceStat/Resources/` 의 `spritesheet.png` + `pet.json` 두 파일만 갈아끼우면 다른
`.codex-pet` 번들로 바꿀 수 있다 — 로더가 Orca 의 매니페스트 스키마를 그대로 읽는다.

### 발밑 패널

펫 바로 아래에 **Claude 수치만** 한 줄(`✳ 31%`) 띄운다. 펫은 흘긋 보는 물건이라 상시 정보가
많으면 배경 소음이 된다. CPU·MEM 은 **마우스를 올렸을 때만** 아랫줄로 펼친다.

다음 Claude 갱신까지 **60초 이하로 남으면** 카운트다운(`↻ 41s`)이 한 줄 더 붙는다. 기준 시각은
반복 타이머의 다음 발화 시각(`AppState.nextClaudeRefreshAt`)이라, ↻ 수동 갱신을 눌러도 주기가
밀리지 않는다. 임계값은 `PetHUD.countdownLeadTime` 하나만 고치면 된다.

임의의 배경 위에 뜨므로 시스템 색을 따르지 않고 반투명 검정 캡슐 + 흰 글자로 고정한다.

### 우클릭 — 대시보드

펫을 우클릭하면 메뉴바에서 쓰는 것과 **같은** `DashboardView` 가 팝오버로 뜬다. 메뉴를 따로
만들지 않은 이유는 두 벌을 유지하면 반드시 어긋나기 때문이다.

팝오버 안의 입력란(토큰·코드 붙여넣기)이 키 입력을 받아야 하므로 이때만 펫 창이 key 창이 된다
(`PetWindow.wantsKey`). 평소에는 `canBecomeKey` 가 false 라, 펫을 만져도 터미널·에디터의 포커스를
뺏지 않는다.

### 잔여량에 따른 상태 (PetVitality + PetAnimation)

5시간 블록 잔여 %가 **재생 속도**와 **어떤 행을 재생할지** 둘 다를 정한다. 리아코 시트에는
포켓몬 상태이상 스킨이 이미 구워져 있어서, 그것을 잔량 단계에 그대로 붙였다.

| 잔여 | 속도 배수 | 모습 |
| --- | --- | --- |
| 60% 이상 | 1.0 | 정면, 평소 |
| 60 → 30% | 1.0 → 0.7 (선형) | 서서히 둔해짐 |
| 30 → 10% | 0.7 → 0.4 | **졸음** — 어두운 `idle` 행 |
| 10 → 0% | 0.4 → 0.25 | **얼어붙음** — 얼음 스킨 `waiting` 행 |

임계값에서 뚝 끊지 않고 60%부터 서서히 깎다가 30% 아래에서 기울기를 급하게 꺾었다. 30% 하나로
on/off 하면 29%가 되는 순간에만 알아채는데, 그러면 "미리 알려준다"는 목적을 못 채운다.

로컬 JSONL 추정 모드에서는 플랜 한도 대비 %를 알 수 없어 `petRemainingPercent` 가 `nil` 이고,
이때는 활력을 깎지 않는다 — 데이터가 없다는 이유로 느려지면 "잔량이 떨어졌다"로 오독된다.

### 상태별 재생 행

우선순위는 **조작 → 작업 → 잔량** 순이다. 만지고 있을 때는 그 반응이 먼저 보여야 하고, 잔량은
가만히 두었을 때 드러나면 충분하다.

| 상황 | 재생 행 | 방향 |
| --- | --- | --- |
| 평상시 | `jumping` (row 4) | 정면 — 얼굴이 보인다 |
| 마우스 호버 | `waving` (row 3) | 반대편으로 돌아섬 |
| Claude 갱신 중 | `running` (row 7) | 정면 |
| 드래그 | `running-left` / `running-right` | 커서 방향 |
| 잔여 30% 이하 | `idle` (row 0) | 졸음 스킨 |
| 잔여 10% 이하 | `waiting` (row 6) | 얼음 스킨 |

시트의 행 이름은 Orca 펫 규약을 따른 것이라 여기서 쓰는 의미와 다르다 — 이름이 아니라 **실제 그림의
방향과 스킨**을 기준으로 골랐다.

### 없는 조합은 런타임에 만든다 (PetSkin)

졸음·얼음 스킨은 시트에 **정면 포즈에만** 구워져 있다. 그래서 졸거나 얼어 있는 펫에 마우스를 올려
뒷모습으로 돌아세우면 갑자기 멀쩡해 보이는 문제가 있었다. 시트를 다시 굽는 대신, 구울 때 쓴 것과
같은 파라미터를 런타임에 적용해 없는 조합을 만든다 (`PetSkin.swift`).

- 졸음: `desaturate(sat 0.4, bright 0.62)` + 떠오르는 "Zzz"
- 얼음: `tint(desaturate(sat 0.35, bright 1.1), (170,215,250), 0.6)` + 각진 얼음 결정

수치는 connor-pet `scripts/build_sheet.py` 에서 그대로 가져왔고, 정면 포즈에 적용해 구워진 행과
나란히 비교해 거의 일치하는 것을 확인했다. 이미 스킨이 구워진 행(`idle`·`waiting`)에는 다시 입히지
않는다 — 두 번 입으면 뭉갠다.

한 가지 함정: Pillow 의 `ImageDraw` 는 도형을 오버레이에 **덮어쓰고** 마지막에 한 번만
`alpha_composite` 한다. Core Graphics 에서 그대로 겹쳐 그리면 반투명 도형끼리 알파가 누적돼
얼음 결정 안이 안 보일 만큼 불투명해진다. 그래서 별도 레이어에 `.copy` 블렌드로 그린 뒤 한 번만
합성한다.

### 디버깅

```sh
VINCESTAT_PET_DEBUG=1 ./dist/VinceStat.app/Contents/MacOS/VinceStat
VINCESTAT_PET_REMAINING=25 ./dist/VinceStat.app/Contents/MacOS/VinceStat   # 잔여 % 강제 주입
```

펫이 안 보일 때는 대개 창이 다른 모니터나 화면 밖에 생긴 경우다. `VINCESTAT_PET_DEBUG=1` 이
찍는 `show frame=… screens=…` 로 좌표를 먼저 확인한다. 스프라이트 번들이 `.app` 에 안 들어가도
조용히 안 뜨는데, 그 경우도 같은 로그가 알려준다.

**주의: `swift run`/`swift build` 로 만든 디버그 바이너리는 코드서명이 없다.** 그래서 실행할
때마다 macOS 가 새 앱으로 취급해 Keychain 허용 창을 다시 띄우고, "항상 허용"을 눌러도 다음
빌드에서 또 뜬다. **테스트도 `./build.sh` 로 만든 `dist/VinceStat.app` 을 쓰는 편이 낫다** —
고정 identity 로 서명되므로 팝업이 뜨지 않는다.

### 스프라이트 크레딧

캐릭터 스프라이트는 Nintendo/Game Freak/Creatures Inc. 의 포켓몬 에셋을 PokeAPI 경유로 받아
connor-pet 이 시트로 구운 것이다. 개인 용도로만 쓰고 독립된 에셋으로 재배포하지 않는다.

## 알려진 한계

- usage API(`api.anthropic.com/api/oauth/usage`)는 비공식이라 스키마가 바뀔 수 있다. 파서는 방어적으로 작성했고 실패 시 추정 폴백이 동작한다.
- **자체 OAuth 토큰만** 스스로 리프레시한다. 폴백 경로의 미러 토큰(Claude Code에서 복사한 것)은 리프레시하지 않는다 — Claude Code의 토큰 로테이션과 충돌하지 않기 위해서다. 그 경우 Claude Code를 한 번 실행하면 갱신된다.
- 자체 OAuth 토큰이 usage API에서 429로 거절될 가능성은 남아 있다(스코프 가설이 틀렸을 경우). 그때는 폴백 경로가 그대로 동작하고, 인증 탭에서 로그아웃하면 예전 동작으로 돌아간다.
- 로컬 추정치는 5시간 윈도우 내 토큰 합산일 뿐 실제 플랜 한도 대비 %가 아니다.
- 펫 창은 스프라이트와 수치 패널 영역에서만 마우스를 받고 나머지 투명 여백은 클릭을 통과시키지만, 판정이 20Hz 폴링이라 경계에서 최대 50ms 늦게 반영된다.
