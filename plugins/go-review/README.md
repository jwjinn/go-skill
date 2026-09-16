# go-review (플러그인 내부 문서)

> 설치·개요는 저장소 루트 [README](../../README.md) 를 보라. 이 문서는 **동작과 근거**를 담는다.

계획 → 승인 → 구현 → **문맥 없는 교차 리뷰** → 병합·기각 → 반영. 각 단계를 **훅이 집행**한다.

```
/plan <요구사항>     계획을 세우고 .claude/plans/<slug>/draft.md 로 남긴다
/go   <범위>         초안을 승인 → 같은 디렉토리의 plan.md (목표 계약 + 체크박스)
   … 구현 …          매 턴 목표 계약이 문맥에 재주입된다(드리프트 방지)
/review-loop         리뷰어 3종 병렬 + 병합 에이전트가 검증·기각
   … 반영 …          확정 결함을 안 고치면 턴이 끝나지 않는다
```

## 왜 이 모양인가

**자기 리뷰는 측정상 나쁘다.** 신선한 문맥의 리뷰어 F1 **28.6%** > 자기 리뷰 24.6% >
의도까지 받은 리뷰 23.8% > 같은 세션 2회차 21.7%(arXiv 2603.12123 · ⚠ 프리프린트).
그래서 리뷰어를 **서로 다른 인식론적 위치**에 세운다:

| 리뷰어 | 받는 것 | 묻는 것 |
|---|---|---|
| `reviewer-contract` | 브리핑 전부 + diff | 요구 충족 · 목표 이탈 · **구현자의 주장이 사실인가** |
| `reviewer-blind` | diff **만** | 이 코드에 무엇이 잘못됐나(편향 0) |
| `codex` | 목표 + diff | 다른 모델 계열의 눈 |
| `review-merger` | 세 JSON | **검증 · 기각 · 중복 병합** |

⭐ **자리와 모델은 다른 축이다.** A(계약)·B(무편향)를 가르는 것은 **받는 정보**이지 모델이
아니다 — 어느 모델이든 어느 자리에나 앉을 수 있다. 그 선택은 지시문이 아니라 **구성 파일**에서
한다(스킬 파일을 고치면 플러그인 업데이트에 덮인다).

```bash
python3 review/_config.py     # 누구를 어느 자리에 앉힐지 + 그 선택의 대가를 말해 준다
```

| preset | 계약 | 무편향 | 교차 | 병합 | 언제 |
|---|---|---|---|---|---|
| `P1` | claude | claude | codex | claude | Claude 소비가 높지만 되돌리는 자리 |
| `P2` ⭐기본 | codex | codex | — | codex | 리뷰를 codex 에 맡기고 Claude 는 구현·반영만 |
| `P2c` | codex | codex | — | claude | P2 의 오탐이 감당 안 될 때 첫 후퇴선 |
| `P3` | — | codex | — | codex | 작고 위험이 낮은 변경 |

**구성 파일은 프로젝트가 이긴다** — `<프로젝트>/.claude/review/config.json` 이 있으면 그것,
없으면 플러그인의 `review/config.default.json`. 스크립트가 **어느 쪽을 읽었는지 출력한다**
(프로젝트 설정이 없는데 있는 것처럼 보이면 「왜 내 설정이 안 먹나」를 아무도 못 찾는다).

⚠ 사슬이 **전부 한 계열**이면 도구가 경고한다 — 같은 계열끼리의 합의는 「독립 동의」가 아니다.
실측 1건: codex 두 자리가 **합의한 blocker 가 오탐**이었다. 그 구성의 안전장치는 사람 판정
(`verdict.sh`)이고, 안 채우면 그 결정이 옳았는지 재는 수단이 없다.

셋은 `review/finding-schema.json` **하나**를 공유한다(Codex 는 `--output-schema` 로 강제된다).
오탐을 막는 필수 필드 둘:

- **`failure_scenario`** — 구체적 재현 경로를 못 쓰면 그것은 결함이 아니라 취향이다
- **`introduced_by_this_change`** — false 면 `pre_existing`(남의 부채로 머지를 막지 않는다)

⚠⚠ **Codex 단독 발견은 `must_fix` 직행 금지.** 교차 모델 리뷰는 **비대칭**이다 —
Claude 코드를 Codex 가 리뷰한 조건이 **−8.6pp**(3 수정 / 13 회귀), 반대 방향은 +18.1pp
(arXiv 2607.21656 · ⚠ 프리프린트). 병합자가 **직접 코드를 열어 확인**해야 CONFIRMED 다.

## codex 리뷰어는 **구조적으로** 읽기 전용이다

`codex exec` 의 기본 샌드박스는 `workspace-write` 이고 **workdir 은 작업 중인 프로젝트**다 —
즉 플래그를 빼먹으면 리뷰어가 자기가 리뷰하는 코드를 고칠 수 있다. 역할 문서에 "고치지 마라"
라고 적는 것은 **주석이지 통제가 아니다**.

그래서 codex 호출은 래퍼를 지나간다:

```bash
bash review/codex-ro.sh --schema review/finding-schema.json -o out.json "<프롬프트>"
```

래퍼가 읽기 전용 샌드박스와 스키마 강제를 붙인다. `bash review/codex-ro.test.sh` (16종)가
**이 문서·명령 파일에 맨 `codex exec` 가 남아 있으면 실패**한다 — 우회로를 문서에서 막는다.

## 설치

⚠ **먼저 알아야 할 것**: Claude Code 는 이 저장소의 **로컬 작업 클론을 보지 않는다.**
GitHub 에서 받아 둔 별도 클론(`~/.claude/plugins/marketplaces/<마켓플레이스>/`)을 읽는다.
그래서 **푸시하기 전에는 설치할 수 없다** — 로컬에서 파일을 만든 것만으로는 목록에 안 뜬다.

```bash
# 1) 이 저장소에서 — 플러그인을 원격에 올린다
git add plugins/go-review .claude-plugin/marketplace.json
git commit -m "feat(go-review): 계획 승인 + 병렬 교차 리뷰 플러그인"
git push

# 2) 쓰려는 프로젝트의 Claude Code 세션에서
/plugin marketplace add jwjinn/go-skill   # 처음 한 번만
/plugin marketplace update jwjinn-go-skill  # 이미 추가돼 있다면 이것
/plugin install go-review@jwjinn-go-skill
```

설치 확인: `~/.claude/plugins/installed_plugins.json` 에 항목이 생기고
`~/.claude/plugins/cache/<마켓플레이스>/go-review/<버전>/` 에 파일이 놓인다.

### ⚠⚠ 이미 `.claude/` 에 직접 넣어 쓰던 저장소라면 — 이관 절차

**공존시키지 마라.** 세 가지가 동시에 깨진다:

1. **게이트 2중 실행** — 같은 Stop 훅이 두 번 돌아 차단 메시지가 두 배가 되고,
   세션당 상한 8회도 두 배 속도로 소모된다.
2. **에이전트 이름 충돌** — `reviewer-contract`·`reviewer-blind`·`review-merger` 는
   이름이 같다. 어느 쪽이 뜨는지는 당신이 고르지 않는다.
3. **정본이 둘** — 한쪽만 고치면 조용히 어긋난다(이 파이프라인이 잡으려는 함정 그 자체다).

**옮길 것(코드)** — 지운다. 플러그인이 이것을 제공한다:

```
.claude/commands/{plan,go,review-loop}.md
.claude/agents/{reviewer-contract,reviewer-blind,review-merger}.md
.claude/hooks/{goal-echo,go-precheck,plan-file-gate,review-gate,todo-completion-gate}.sh (+ .test.sh)
.claude/review/  ← _*.py · *.sh · *-schema.json · eval/ (스크립트 전부)
```

그리고 `.claude/settings.json` 에서 **그 훅 5개의 등록을 지운다**(다른 훅은 그대로 둔다).

**남길 것(그 프로젝트의 것)** — 지우면 안 된다:

| 남기는 것 | 왜 |
|---|---|
| `.claude/plans/<slug>/{draft,plan,review}.md` (레거시 `plan-active.md` · `review-active.md`) | 진행 중인 계획·리뷰 상태 — 계획마다 디렉토리 하나 |
| `.claude/review/runs/` | 라운드 원본(diff·리뷰어 JSON) |
| `.claude/review/config.json` | 그 프로젝트의 리뷰 **구성**(preset·모델·split_lines) — **플러그인 기본을 이긴다** |
| `.claude/review-rules.md` | 그 프로젝트의 리뷰 규칙(없으면 이번에 만들어라) |
| `.claude/review/eval/cases/<프로젝트>.jsonl` | 특화 회귀 케이스 — **플러그인에 싣지 마라** |
| `docs/리뷰-이력/` | 측정 이력(`CLAUDE_REVIEW_HISTORY_DIR` 로 옮길 수 있다) |

⚠ **플러그인은 세션 시작 시 로드된다.** 즉 지우기 → 설치 → **세션 재시작**까지가 한 묶음이고,
그 사이에는 `/review-loop` 가 어느 쪽에도 없다. 진행 중인 리뷰가 있으면 **그것을 먼저 닫아라.**

⚠ **측정 이력의 `prompt_version` 이 한 번 바뀐다.** 지시문 파일의 기준점이 프로젝트 루트에서
플러그인 루트로 옮겨졌기 때문이다(경로가 해시에 들어간다). 이관 전후를 같은 버전으로 묶어
비교하지 마라 — 값이 달라진 것은 지시문 내용이 아니라 **위치**다.

## ⚠ 한 저장소에서 세션을 여럿 돌리면 — 가장 먼저 읽을 것

계획·리뷰 상태는 `<프로젝트>/.claude/` 에 **파일 하나**로 산다. 같은 디렉토리에서 세션을
둘 이상 띄우면 그 파일을 공유하고, **B 세션이 A 세션의 미완료 계획으로 차단된다.**

> 개발 중 한 세션에서 이 차단을 **네 번** 겪었다. 실제로 흔하다.

게이트는 그때 이렇게 말한다(계획 머리말의 `작업 위치` 와 현재 프로젝트를 대조한다):

```
⚠ 이 계획은 다른 세션의 것일 수 있다.
   계획 머리말의 작업 위치: /path/to/other-worktree
   지금 세션의 프로젝트  : /path/to/this-repo
```

⚠⚠ **그래도 차단은 유지된다. 이건 결함이 아니라 결정이다** — 소유자를 가릴 신호가 없어서
불일치를 근거로 열면 **진짜 주인의 완주 게이트까지 함께 꺼진다**(fail-open).
그래서 게이트는 열지 않고 **진단만 정확히** 한다. 푸는 것은 사람의 몫이다.

**해결(권장 순)**

1. ⭐ **`git worktree` 로 세션마다 디렉토리를 나눈다.** `CLAUDE_PROJECT_DIR` 가 달라지므로
   계획 파일도 자연히 분리된다. **이것이 유일한 구조적 해결이다.**
   ⚠ 흔한 실수: 파일은 워크트리에서 고치면서 세션은 메인 트리에서 띄우는 것.
   그러면 계획 파일만 메인 트리에 남아 충돌이 그대로다 — **세션을 그 워크트리에서 띄워라.**
2. 한 트리를 고집해야 하면 세션마다 `CLAUDE_PLAN_FILE` · `CLAUDE_REVIEW_FILE` 를 지정해 띄운다.
3. 그 계획을 끝내거나 파일을 지운다(끝났으면 지우는 것이 규약이다).

### ⭐⭐ 2026-09-16 — 게이트가 **이 세션이 채택한 계획만** 막는다

위 안내는 계속 유효하지만, 가장 잦은 경우 하나는 이제 도구가 스스로 가른다. 같은 워크트리에서
세션 A 가 계획을 진행하는 동안 세션 B 가 **별건**을 하면(예: 훅을 점검한다), B 는 A 의 미완료로
매 턴 막혔다. 낡음 판별은 그것을 못 본다 — 계획이 B 의 시작 뒤에도 갱신되기 때문이다.

게이트가 재려던 것은 「승인받은 계획을 완주했나」이고 **승인은 세션이 한 행위**다. 그래서 그
행위의 흔적을 transcript 에서 본다. 어느 하나면 채택이다:

- 그 파일을 **쓴** 도구 — `Write`/`Edit`/`MultiEdit` (파일 경로가 그 계획 파일로 끝난다)
- **레거시 단일 자리(`plan-active.md` 류)에만**: 사람 프롬프트의 go 호출(`/go-review:go` · `/go` ·
  `<command-name>` 래핑) 또는 `Skill` 도구로 `go-review:go` · `go-review:review-loop` 호출 — 그 자리는
  워크트리에 하나뿐이라 「go 를 불렀다」가 곧 「그 계획」이다. `plans/<slug>/` 계획은 여럿일 수 있어
  go 호출로는 어느 것인지 모르므로 쓰기 흔적만 본다(2026-09-16 실증: 다른 세션의 `/go` 1회가
  이 세션의 slug 계획을 잡았다 — 대조군 s-uq6·s-uq7)

읽기(`cat`·`grep`)는 채택이 아니다 — 점검하는 세션이 딱 그것을 한다. Bash 의 `> <파일>` 재지향도
채택이 아니다(게이트를 테스트하는 세션의 픽스처 문자열이 걸렸다 · `5b29ada`). `/go-review:plan` 도
채택이 아니다(초안을 만드는 단계다). 판별 불가(transcript 부재·사람 발화 0)는 **차단 유지**다.

남의 계획일 때는 막지 않되 **세션당 한 번** 그 사실을 알린다. 조용한 통과와 검사한 통과는 다르다.
같은 판별을 `goal-echo.sh`(목표 재주입)와 `review-gate.sh`(리뷰 반영·경고 축)도 쓴다 — 같은
사실을 세 훅이 다르게 알면 안 되기 때문이다.

**절대 하지 마라**: 남의 계획을 `[x]` 로 위장하거나 줄을 지우는 것. 그 세션의 완주 추적이
사라지고, 그쪽은 자기 작업이 왜 게이트에서 빠졌는지 알 수 없다.

⭐ 그래서 `/go` 는 계획 머리말에 **`작업 위치` 를 항상 쓴다.** 그 줄이 없으면 게이트는
판별할 수 없어 진단 없이 차단만 한다(모르는 것을 근거로 게이트를 열지 않는다).

### ⭐⭐ 2026-09-16 — 계획마다 디렉토리 하나 (`.claude/plans/<slug>/`)

채택 판별이 있어도 파일이 **하나**면 두 세션의 계획은 같은 자리를 다툰다(한쪽의 `/go` 가 남의
`plan-draft.md` 를 옮기려 든다). 그래서 자리를 나눴다 — 사용자 지시 「확실히 보장이 필요해. 다른
세션의 플랜과 이 세션의 플랜이 겹치지 않는 것이 필요해」.

| 무엇 | 어디 | 누가 고른다 |
|---|---|---|
| 초안 | `.claude/plans/<slug>/draft.md` | `go-precheck.sh` — **이 세션이 쓴** 초안만(`draft_pick`) · 남의 것만 있으면 「옮기지 마라」 |
| 계획 | `.claude/plans/<slug>/plan.md` | 게이트·재주입·사전 확인 공통 `plan_pick` — 후보(env → `plans/*/plan.md` → 레거시) 가운데 이 세션이 채택한 첫 것 |
| 리뷰 | `.claude/plans/<slug>/review.md` | `review-gate.sh` — 고른 계획 옆(`review_of`) |

slug 는 `YYYYMMDD-<제목 kebab>`. 레거시 자리(`plan-active.md`·`plan-draft.md`·`review-active.md`)는
그대로 인식된다. `CLAUDE_PLAN_FILE`·`CLAUDE_PLAN_DRAFT_FILE`·`CLAUDE_REVIEW_FILE` 은 후보를 그 파일
하나로 좁히지만 **채택 판별을 건너뛰지는 않는다**(대조군: 좁힌 파일이 남의 것이면 알림).
go-tester 는 계획을 `CLAUDE_PLAN_FILE` 로 받으므로 `/go` 가 옵트인 때 그 경로를 넘긴다(`go.md` §0-d).

실증(2026-09-16 · 같은 워크트리의 실제 transcript 둘): 이 세션의 기록으로 돌리면 이 세션의 slug
계획만 막고 다른 세션의 `plan-active.md` 는 문구에 없다 · 다른 세션의 기록으로 돌리면 그 반대 ·
재주입도 각자의 목표 계약만 · `/go` 사전 확인도 각자의 계획을 「기존 계획」으로 지목한다.
「세션별 파일은 만들 수 없다(2026-09-02)」는 안내는 폐기됐다 — 그때는 세션 번호가 필요했고,
지금은 행위 흔적으로 가르므로 이름만 고유하면 된다.

## 프로젝트별 규칙 — `.claude/review-rules.md`

리뷰어는 보편 함정 점검표(탐지기 고장 · 대조군 없는 보호 · 정직 공백 · fail-open ·
정본 이중화 · 주석 거짓말 · 관측이 서비스를 죽임)를 갖고 있다. 여기에 **프로젝트가 실제로
반복해서 밟은 함정**을 얹어라:

```markdown
# 리뷰 규칙

## 이 프로젝트가 반복해서 밟은 함정
1. CSS 클래스를 쓰기 전에 그 화면의 CSS 그래프에 정의가 있는지 확인하라(7번 밟았다).
2. infra/ 변경이면 `kubectl diff` 로 라이브와 대조했는지 확인하라.

## 심각도 재정의
- `scripts/` 아래는 확실하고 심각할 때만 보고한다.

## 건너뛸 것
- 생성 코드 · lockfile · CI 가 이미 강제하는 것(린트·포맷·타입)
```

리뷰어는 이 파일이 있으면 **보편 점검표보다 우선**해서 따른다. 없으면 `not_reviewed` 에
그 사실을 적는다(정직 공백).

## ⭐ 비용은 재서 결정하라

근거 논문은 전부 프리프린트다. **당신 코드에서 직접 재라** — 라운드마다 자동으로 쌓인다:

```bash
bash review/record-round.sh <라운드 디렉토리> "한 줄 목표" "claude-blind=118861,..."
bash review/verdict.sh <라운드> mf1=a mf2=r:오탐 c3=d   # ⛔ 사람이 채운다
bash review/measure.sh
```

`measure.sh` 가 계산하는 것 둘:

- **절제(ablation)** — "이 리뷰어를 빼면 놓쳤을 must_fix 가 몇 건인가"
- **정밀도 · 1인 기준선** — "올린 것 중 몇 건이 실제 결함이었나". ⭐ 리뷰어 구성을 정하는 것은
  이쪽이다 — **많이 올리는 리뷰어가 좋은 리뷰어는 아니다.**

⚠ **여기서 못 재는 것이 하나 있다 — 재현율.** 실사용 라운드는 「올린 것」만 보여주므로
**있었는데 아무도 못 본 결함**은 나타나지 않는다 → 아래 회귀 평가가 그 자리다.

⭐⭐ **정밀도는 `verdict.sh` 없이는 계산되지 않는다.** 발견 수는 자동으로 쌓이지만
「그중 몇 건이 옳았나」는 사람만 안다. 라벨이 없으면 도구는 숫자를 지어내지 않고 그렇게 말한다:

```
■ ⭐ 정밀도 — 올린 것 중 몇 건이 실제 결함이었나
  ⛔ 계산하지 않았다 — 사람 판정이 0건이다(대상 17건).
```

⚠ **일괄 승인 플래그를 일부러 만들지 않았다.** 모델이 이 값을 채우면 병합자가 자기 판정을
자기가 채점하는 것이 되고, 그러면 이 로그는 「리뷰가 잘 됐다」를 항상 말하는 장식이 된다.
판정 하나하나가 명령줄에 드러나야 승인창에서 사람이 그것을 본다(**부재가 통제다**).
그래서 `/review-loop` ⑦-b 는 모델에게 **`r`(오탐)만은 사용자 동의 없이 쓰지 말라**고 한다 —
`a`·`d` 는 "리뷰어가 옳았다"는 방향이지만 `r` 만이 "리뷰어가 틀렸다"고 말하기 때문이다.

```
■ ⭐ 절제 — 리뷰어 조합별 must_fix 커버리지
  contract+blind             5/5      0  ⭐ 이것으로 충분했다
  blind+codex                4/5      1
  codex 를 빼면: 토큰 19% 절약 · 놓치는 must_fix 0건
```

⚠ 표본이 5라운드 미만이면 도구가 **「결론을 내리지 마라」고 말한다.** 그 경고가 사라질 때까지
숫자를 근거로 쓰지 마라.

## 토큰을 줄이려면

1라운드 실측 기준 재료 구성: **리뷰 대상 diff 47%** · 리뷰어 산출 JSON 22% ·
**지시문(역할 정본+프롬프트) 8%**.

- ✅ **리뷰 범위를 좁혀라** — 47% 가 여기 있다. 큰 diff 는 나눠 돌려라.
- ✅ **리뷰어를 줄여라** — `measure.sh` 의 절제 결과가 근거를 준다.
- ✅ **마크다운은 최종 산출물에만** — 병합자는 JSON 만 쓰고 `review/_render.py` 가
  사람이 읽는 보고서를 결정론적으로 렌더한다(LLM 이 쓰면 출력 토큰을 두 번 쓴다).
- ❌ **지시문을 압축하지 마라** — 8% 뿐이고, 그 8% 가 결함의 바와 함정 목록을 담아
  오탐을 막는다. 줄이면 토큰은 조금 아끼고 리뷰 품질을 잃는다.

## ⭐ 회귀 평가 — 리뷰어를 채점한다 (`review/eval/`)

정밀도의 반대쪽(**있었는데 놓친 것**)은 정답을 아는 diff 로만 잰다. 그리고 그것이 있어야
**「리뷰어 지시문을 고쳤더니 좋아졌다」가 의견이 아니라 숫자**가 된다.

```bash
bash review/eval/eval.sh list                                   # 케이스 25건(대조군 9건 포함)
bash review/eval/eval.sh codex review/eval/cases/universal.jsonl runs/cx-1
bash review/eval/eval.sh score review/eval/cases/universal.jsonl runs/cx-1 codex
```

⭐⭐ **대조군이 이 도구의 3분의 1이 넘는다.** 25건 중 **9건은 결함이 없는 diff** 이고 정답은
「보고하지 않는 것」이다. 없으면 **「전부 결함이라고 답하는」 리뷰어가 재현율 100% 로 만점**을
받는다 — `eval.test.sh` 의 t8 이 대조군을 빼서 그것을 실제로 재현해 보인다.
대조군은 **그럴듯하게 의심스러워야** 값을 한다(의도된 fail-open · 근거가 적힌
`insecureSkipVerify` · 프로토콜 규약의 PUT · 정직 공백).

읽는 법 — **위치 재현율**(믿을 만함) · **사유까지/위치만**(옳은 줄을 엉뚱한 이유로 지적한 것이
만점으로 묻히지 않게 분리) · **오탐률** · **미측정**(놓침이 아니라 도달 실패라 분모에서 뺀다) ·
**부류별**(약한 부류가 곧 프롬프트를 고칠 자리).

⚠ **오픈북에 주의.** 정답(`why`·`expect`·`class`)은 프롬프트로 나가지 않지만
(`_prepare.py` 화이트리스트 · `eval.test.sh` t10 이 잠근다), **`.claude/review-rules.md` 는
다르다** — 그 함정 목록이 케이스와 같은 출처에서 왔다면 참고서를 준 셈이다.
규칙 파일을 준 조건과 안 준 조건으로 나눠 재라.

⚠ 이것은 `go test` 가 아니다. 리뷰어는 확률적이라 통과/실패가 아니라 **비율을 기준선과 비교**한다.
`bash review/eval/eval.test.sh` (24종 — 채점기 자신의 대조군)

## 게이트 4종

| 훅 | 이벤트 | 무엇을 | 차단? |
|---|---|---|---|
| `go-precheck.sh` | UserPromptSubmit | 초안 없는 `/go` | 경고 |
| `goal-echo.sh` | UserPromptSubmit | 목표 계약 재주입 | — |
| `todo-completion-gate.sh` | Stop | 계획 미완료(**도구 축** — 마지막 `TodoWrite`) | **차단** |
| `plan-file-gate.sh` | Stop | 계획 미완료(**파일 축** — 이 세션이 채택한 `plans/<slug>/plan.md` · 레거시) | **차단** |
| `review-gate.sh` | Stop | 확정 결함 미해결 | **차단** |

⭐ **완주 축이 둘인 이유**: `TodoWrite` 도구가 **하네스 빌드에 아예 없는 세션**이 있다. 그때
도구 축은 "계획을 안 세운 턴" 으로 보고 조용히 통과한다 — 12단계 계획이 1단계만 하고 끝나도
잡히지 않는다. 파일 축은 도구가 아니라 **파일**을 보므로 그 조건에서도 작동한다.
**다단계 계획을 승인받으면 둘 중 하나는 반드시 남겨라.**

원칙 3종을 공유한다: **낡은 기록 자동 만료** · **세션당 상한 8회**(하네스 상한과 같다) ·
**훅 고장은 통과**(관측이 작업을 죽이면 안 된다).

차단과 경고를 가르는 기준: **근거가 명확하면 차단, 판정이 애매하면 경고.**
거부하는 검사에서 오탐 비용이 미탐보다 즉각적이기 때문이다.

## 게이트 자신의 테스트 — 14스위트 439검사

```bash
for t in hooks/*.test.sh review/*.test.sh review/eval/*.test.sh scripts/*.test.sh; do
  bash "$t" >/dev/null 2>&1 || echo "⛔ $t"
done
bash hooks/doctor.sh --stamp    # 통과했다고 표시한다(세션 시작 진단 ⑦ 이 그 표시를 본다)
```

| 스위트 | 검사 | 스위트 | 검사 |
|---|---|---|---|
| `hooks/doctor.test.sh` | 19 | `review/config.test.sh` | 53 |
| `hooks/go-precheck.test.sh` | 57 | `review/dedup.test.sh` | 24 |
| `hooks/goal-echo.test.sh` | 32 | `review/measure.test.sh` | 25 |
| `hooks/plan-file-gate.test.sh` | 55 | `review/scope.test.sh` | 19 |
| `hooks/review-gate.test.sh` | 26 | `review/verdict.test.sh` | 29 |
| `hooks/todo-completion-gate.test.sh` | 18 | `review/eval/eval.test.sh` | 25 |
| `review/codex-ro.test.sh` | 16 | `scripts/deps-check.test.sh` | 41 |

각 스위트에 **사보타주 대조군**이 있다 — 보호를 지우면 실제로 실패하는지 확인한다.
대조군 없는 테스트는 근거가 아니다.

## 요구사항 — 설치 직후 한 번 세어라

```bash
bash scripts/deps-check.sh          # 있는지 본다(1초 · 판정 0/1/2)
bash scripts/deps-check.sh --deep   # + codex 를 실제로 한 번 불러 돌아가는지 본다
```

| 도구 | 구분 | 없으면 |
|---|---|---|
| `bash` · `git` | 필수 | 실행기 자신 · 리뷰 범위 산정(diff) · 워크트리 판별 |
| `jq` | **필수** | ⛔ Stop 게이트 3축과 목표 재주입이 **붙어 있는 채로 아무것도 보지 않는다** |
| `python3`(3.6+) | 필수 | 구성 해석 · 중복 제거 · 측정 · 회귀 평가 전량 |
| `codex` | 선택 | 교차 모델 자리. 스크립트가 preset 을 P1 로 내리고 그 자리를 비운다 |
| `timeout` | 선택 | codex 호출의 시간 상한. `gtimeout` 이 있으면 그것을 쓰고, 둘 다 없으면 상한 없이 부른다 |

⛔⛔ **`jq` 가 필수인 이유는 실측이다.** 미완료 2개짜리 계획을 두고 PATH 에서 jq 만 뺐더니
`plan-file-gate.sh` 가 **출력 0바이트 · 종료코드 0** 이었다. 훅은 등록돼 있고 계획도 있고
미완료도 남아 있는데 아무 일도 일어나지 않았고, 그 사실을 아무도 몰랐다. 지금은 그 조건에서
게이트가 통과하되 **침묵하지 않는다**(`hooks/_deps.sh`) — 침묵하는 fail-open 과 알려진
fail-open 은 다르다. 대조군은 `scripts/deps-check.test.sh` 41검사에 있다.

⚠ **codex 부재는 스크립트가 처리한다.** 기본 preset `P2` 는 계약·무편향·병합 **세 자리 전부**가
codex 라, 없으면 강등이 아니라 **리뷰가 0회**가 된다(fail-open 방향). 그래서 `_config.py` 가
`command -v codex` 를 보고 preset 을 **P1 로 내리고 codex 자리를 비운다.** 종전에는 이것이
`review-loop.md` 의 한 줄 규율이었고, 빠뜨리면 그대로 리뷰가 사라졌다.
⭐ 어느 구성이 실제로 도는지는 `python3 review/_config.py` 가 말해 준다 — 짐작하지 마라.
⚠⚠ 그리고 **설치돼 있다고 도는 것이 아니다**(codex 0.152.0 실측: 기본 모델이 CLI 업그레이드를
요구해 한 줄도 못 돌았다). 그 구분은 `deps-check.sh --deep` 이 한다.
