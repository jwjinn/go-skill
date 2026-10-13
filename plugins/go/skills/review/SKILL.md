---
name: review
description: 구현이 끝난 뒤의 마무리 한 사이클을 한 번에 돈다 — codex 리뷰(민감 영역이면 adversarial 추가) → web 변경이면 AI 슬롭 스캔 → 확정 결함 반영 → 머지 전 검사(기본 브랜치로 가는 PR 만) → 커밋·PR. 리뷰어는 codex 하나다(Claude 토큰을 아끼려는 사용자 결정). 사용자가 「리뷰 돌려」「마무리해」「리뷰하고 PR 올려」「/go:review」라고 할 때 쓴다. /go:start 와 병렬 워커가 마무리 단계에서 부른다. 코드 작성 중에는 쓰지 않는다.
argument-hint: "[--base <ref>] [--no-pr] [--merge] [집중 영역 한 문장]"
---

# /go:review — 마무리 한 사이클

구현은 끝났다. 지금부터는 다른 눈으로 보고, 확정된 것만 고치고, 검사하고, 올린다.
**한 단계에 한 사이클이다.** 반영한 뒤 다시 리뷰를 돌리지 않는다(반복 리뷰에서 좋은 결과를 얻지 못했다).
인자 `$ARGUMENTS` 를 먼저 읽어라: `--base <ref>`(기본 `origin/main`) · `--no-pr`(PR 을 만들지 않는다) ·
`--merge`(머지까지 · 기본 브랜치로 가면 squash, 아니면 merge 커밋) · 나머지 문장은 codex adversarial 리뷰의 집중 영역이다.

## 0. 범위

- `git fetch -q origin` 뒤 `git diff --stat <base>...HEAD` 와 `git status --short` 로 리뷰 대상을 센다.
  둘 다 비어 있으면 「리뷰할 변경이 없다」고 말하고 끝낸다.
- base 가 없으면(원격이 없거나 ref 가 없으면) `HEAD~1` 을 base 로 쓰고 그 사실을 보고에 적는다.
- **기본 브랜치로 가는 PR 인지** 가른다. 기본 브랜치 이름은 `git symbolic-ref --short refs/remotes/origin/HEAD`
  (없으면 `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`)로 얻는다. base 가 그 브랜치(`origin/<이름>` 또는
  `<이름>`)이고 `--no-pr` 가 아니면 「기본 브랜치로 가는 PR」이다. 작업 브랜치로 가는 PR 과 병렬 워커(`--no-pr --base <시작 커밋>`)는
  아니다. 이 판정이 6단계 검사와 7단계 머지 방식을 정한다.
- 저장소에 `.claude/review-rules.md` 가 있으면 읽는다. 그 저장소의 함정·심각도 기준이고, 아래 두 리뷰의
  발견을 분류할 때 그 기준을 쓴다.
- 변경 파일 목록에서 **민감 영역**을 가른다: 인증·인가·과금·마이그레이션·시크릿·컨테이너 권한
  (`auth|iam|login|session|billing|quota|migration|secret|credential|Dockerfile|securityContext|runAs` 가
  경로나 diff 에 있으면). 하나라도 있으면 3단계의 adversarial 리뷰를 추가한다.

## 1. 리뷰어는 codex 하나다

**`/code-review` 를 부르지 마라.** 리뷰어를 Claude 와 codex 둘로 두면 리뷰마다 Claude 토큰이 한 세션분
더 든다(2026-10-11 사용자 결정: 「이걸 하나만 하자. claude 토큰을 너무 쓰는 거 같은데」). 이 세션의 Claude 는
리뷰어가 아니라 **codex 발견을 검증하고 고치는 쪽**이다. 그 검증(4단계)은 해당 파일의 해당 구간만 열므로 싸다.

## 2. codex 리뷰

**먼저 계정을 확인한다.** 저장소의 CLAUDE.md 또는 AGENTS.md 에 「codex 허용 계정」 줄(예: `codex 허용 계정: @example.com`)이
있으면 그 도메인으로 이 스킬 폴더의 확인 스크립트를 돌린다.

```bash
python3 <이 스킬 폴더>/codex-account.py <허용 도메인>
```

종료 코드가 0 이 아니면(다른 도메인 1 · 확인 불가 2) **리뷰를 돌리지 말고 멈춰서** 사용자에게 알린다. 코드는 다른 계정으로
보내지 않는다. 안내할 것: `codex logout` 뒤 허용 계정으로 `codex login`(Orca 세션이면 Orca 의 codex 계정 전환). 줄이 없으면
이 확인은 건너뛴다.

codex 플러그인의 companion 스크립트를 **직접** 실행한다(슬래시 명령 `/codex:review` 는 모델이 부를 수 없게
막혀 있다. 그래서 이 스킬이 있다).

```bash
C=$(ls -d "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | tail -1)
node "$C" review --wait --base <base>
```

민감 영역이 있거나 집중 영역 문장이 주어졌으면 한 번 더:

```bash
node "$C" adversarial-review --wait --base <base> <집중 영역 문장>
```

출력(`# Codex Review` 아래 `[P1]`·`[P2]`… 목록)을 그대로 받아 둔다. 스크립트가 없거나 「Reviewer failed」면
**여기서 멈추고 사용자에게 묻는다** — codex 를 고쳐 다시 돌릴지, 이번만 `/code-review`(Claude · 토큰이 든다)로
대신할지. 리뷰 없이 5단계로 넘어가지 말고, 묻지 않고 Claude 리뷰로 바꾸지도 마라.
모델은 `~/.codex/config.toml`(Orca 세션은 `$CODEX_HOME` 의 것)의 기본값을 쓴다. 바꾸려면 `--model <이름>`.

## 3. web 변경이면 슬롭 스캔

변경 파일에 `web/` 이 있고 `.claude/skills/kill-ai-slop/scripts/scan.mjs` 가 있으면:

```bash
node .claude/skills/kill-ai-slop/scripts/scan.mjs web/src --json
```

결과 중 **이번에 바꾼 파일**의 적중만 추린다. 적중마다 파일을 열어 슬롭인지 의도된 선택인지 가른다
(브랜드 토큰·로고·일부러 넣은 것은 슬롭이 아니다). 슬롭으로 판정한 것만 4단계의 발견에 넣는다.

## 4. 검증과 판정

codex 의 발견(슬롭 스캔 적중 포함)을 `파일:줄` 로 묶어 중복을 지운다. 판정 기준:

- 발견마다 그 파일의 **해당 구간만** 열어(`Read offset/limit`) 재현 경로가 실재하는지 확인한다. 파일 전체나
  모듈을 다시 읽지 마라 — 여기서 토큰이 새면 리뷰어를 하나로 줄인 뜻이 없다.
- **must_fix**: 확인됐고, blocker·major(`[P1]`·`[P2]`)이며, 이번 변경이 만든 것.
- 확인되지 않은 발견은 보류로 적는다(교차 모델 리뷰는 대칭이 아니라는 보고가 있다 — codex 의 말만으로 고치지 않는다).
- 이번 변경 전부터 있던 결함은 **pre_existing** 으로 따로 적는다. 남의 부채로 머지를 막지 않는다.
- 실패 시나리오를 구체적으로 쓸 수 없는 지적은 취향이다. consider 로 적고 고치지 않는다.

## 5. 반영

must_fix 만 고친다. 고치면서 범위를 넓히지 않는다. 고친 뒤 **다시 리뷰를 돌리지 않는다.**
보호 로직을 고쳤으면 그 로직을 깨서 테스트가 붉어지는 것을 한 번 본다(대조군 없는 테스트는 근거가 아니다).

## 6. 검사 — 기본 브랜치로 가는 PR 에서만

작업 브랜치는 빠르게 가고, 검사는 기본 브랜치에 들어갈 때 한 번 한다. 기본 브랜치로 가는 PR 이 아니면(0단계)
이 단계를 건너뛰고 보고에 「검사 건너뜀 — 작업 브랜치」라고 적는다.

기본 브랜치로 가는 PR 이면: `scripts/pre-merge-check.sh` 가 있으면 `bash scripts/pre-merge-check.sh` 를 돌린다. 없으면
CLAUDE.md 의 빌드·테스트 게이트를 변경 범위에 맞게 돌린다. 붉으면 고치고 다시 돌린다(이것은 리뷰가 아니라 검사다).

## 7. 커밋 · PR

- 저장소의 커밋 규약(CLAUDE.md)대로 커밋한다. `git add -A` 대신 바꾼 파일을 지목한다.
- `--no-pr` 가 아니면 push 하고 `gh pr create --base <base 의 브랜치 이름>` 으로 PR 을 만든다(`--base` 를 빼면 gh 가
  기본 브랜치로 연다). 본문에 **리뷰 결과 원문 요약과 반영·보류 목록**을 넣는다.
- `--merge` 가 있으면: 기본 브랜치로 가는 PR 은 6단계가 통과했을 때 `gh pr merge --squash`, 작업 브랜치로 가는 PR 은
  `gh pr merge --merge`(merge 커밋 · 작업 브랜치끼리는 squash 하지 않는다). `--merge` 가 없으면 머지는 사용자가 한다.
- squash 머지한 브랜치는 다시 쓰지 않는다.

### 머지 뒤 두 가지 — 이 스킬 밖에서 머지했을 때도 똑같이 한다

**① squash 머지 표시.** squash 로 머지했으면 그 작업 브랜치 끝에 빈 커밋을 하나 남기고 push 한다. squash 는 원 브랜치의
커밋을 기본 브랜치에 남기지 않아서, 브랜치만 보면 머지됐는지 알 수 없다. 그 브랜치를 다시 쓰면 다음 PR 이 충돌한다.

```bash
git commit --allow-empty -m "chore: squash 머지됨 — <기본 브랜치> 에 #<PR 번호>(<머지 커밋 8자리>)로 들어갔다. 이 브랜치는 다시 쓰지 않는다"
git push origin <작업 브랜치>
```

원격 브랜치를 지우면 이 표시도 사라지므로 `--delete-branch` 는 쓰지 않는다. merge 커밋으로 넣은 PR 에는 남기지 않는다(원 커밋이 그대로 남는다).

**② 기본 브랜치 로컬 동기화.** 기본 브랜치로 머지했으면 그 브랜치를 체크아웃한 워크트리를 `git worktree list --porcelain` 에서
찾아(`branch refs/heads/<기본 브랜치>` 줄) `git -C <그 경로> pull --ff-only` 를 한다. 체크아웃한 워크트리가 없으면
`git fetch origin <기본 브랜치>:<기본 브랜치>` 로 브랜치만 맞춘다. 실패하면(미커밋 변경과 겹침 · 갈라짐) **stash·reset·checkout 으로
풀지 마라** — 그 변경은 다른 세션의 것일 수 있다. 막는 파일 목록을 보고에 적고 멈춘다.

## 8. 보고 — 이 순서대로, 짧게

1. codex 발견 수와 원문 요지(슬롭 스캔이 돌았으면 그 적중도)
2. 반영한 것(파일:줄)
3. 보류·기각한 것과 이유(재현 미확인 · pre_existing · 취향)
4. 검사 결과(무엇을 몇 개 돌렸나 · 건너뛰었으면 그 이유)
5. PR 링크(또는 만들지 않은 이유) · 머지했으면 squash 표시 커밋과 로컬 기본 브랜치 동기화 결과(막혔으면 막는 파일)
6. 이 사이클에서 있었던 일(codex 가 실패했다 · 스캐너 오탐 · 예상 밖의 것). 「특이사항 없음」으로 채우지 마라

## 하지 마라

- codex 플러그인의 Review Gate 를 켜지 마라(Stop 마다 리뷰가 돌아 비용이 늘고 이 사이클 규율과 충돌한다).
- `/codex:rescue` 로 고치게 하지 마라. 고치는 것은 이 세션이다.
- 사람이 판정할 질문(설계 갈림길)을 혼자 결정하지 마라 — 그 항목은 보류로 적고 보고에서 묻는다.
