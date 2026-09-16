#!/usr/bin/env bash
# _planpath.sh — 계획 파일의 **경로·소유자 파싱** 공용 함수. `source` 로 쓴다(실행 파일이 아니다).
#
# ⭐⭐ 왜 뽑았나(2026-09-03): 같은 두 가지를 `plan-file-gate.sh` 와 `go-precheck.sh` 가
# **각자** 하고 있었고, 실제로 갈라져 있었다 — owner 파싱의 sed 체인이 서로 달라서
# 한쪽만 고치면 다른 쪽이 계속 오진했다. 이 레포가 19행 밟은 「정본이 둘」이다.
#
# ⚠ **경로는 「나」를 기준으로 잡는다.** 한 세션에서 같은 부류를 세 번 밟았다:
#   ① 훅이 `$CLAUDE_PROJECT_DIR` 만 봐서 워크트리의 계획을 못 찾고 **조용히 통과**했다
#   ② 훅 테스트가 다른 워크트리 절대 경로를 박아 둬서 20/29 가 FAIL 이었다(훅이 아니라 테스트 결함)
#   ③ `codex-ro.sh --schema` 가 호출자 cwd 기준이라 리뷰가 통째로 실패했다
#   ⇒ 규약: **ambient 값보다 자기 위치를 믿어라.**
#
# ⚠⚠ **단, 「자기 위치」 규칙은 플러그인 배포에서 뒤집힌다**(2026-09-03 이식 시 발견).
#   로컬 사본이던 시절 `dirname $0/..` 는 프로젝트의 `.claude` 였지만, 플러그인에서는
#   **코드 디렉토리**(`~/.claude/skills/go-review/hooks/..`)를 가리킨다. 상태(계획·리뷰 파일)는
#   언제나 **프로젝트**에 있어야 하므로 마지막 폴백은 `$PWD/.claude` 다.
#   ⇒ 코드는 자기 위치를 믿고, **상태는 프로젝트를 믿는다.** 둘을 섞지 마라.

# plan_base — 계획 파일들이 있는 `.claude` 디렉토리.
#
# ⚠ 우선순위가 계약이다: CLAUDE_PROJECT_DIR > cwd. (명시 파일 지정은 호출부의
#   `CLAUDE_PLAN_FILE`·`CLAUDE_PLAN_DRAFT_FILE` 가 이 값보다 먼저 이긴다.)
plan_base() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR/.claude"
    return 0
  fi
  printf '%s' "${PWD}/.claude"
}

# plan_owner_of <파일> — 머리말 `작업 위치:` 의 **경로만** 뽑는다(없으면 빈 문자열).
#
# ⚠⚠ **첫 공백에서 끊는다.** 그전에는 `**` 와 ` (…)`(또는 ` ·…`)만 벗기고 나머지를 그대로
#	비교해서, 사람이 경로 뒤에 설명을 붙이면 **자기 계획을 남의 것으로 오진**했다.
#	그 진단은 「멈춰라」라고 지시하므로 오진의 대가가 곧 작업 중단이다(2026-09-03 실측).
# ⚠ 공백 있는 경로는 **인용해서** 적는다 — 인용을 먼저 벗기므로 그때는 끊기지 않는다.
plan_owner_of() {
  grep -m1 -E '^[[:space:]]*(작업 위치|Work dir)[[:space:]]*:' "$1" 2>/dev/null \
    | sed -e 's/.*: *//' -e 's/\*\*//g' -e 's/^[[:space:]]*//' \
          -e 's/^`\([^`]*\)`.*/\1/' -e "s/^'\([^']*\)'.*/\1/" -e 's/^"\([^"]*\)".*/\1/' \
          -e 's/[[:space:]].*//' -e 's/[[:space:]]*$//'
}

# plan_other_worktrees <이 base> — **다른 워크트리**에 있는 계획 파일 경로들(미완료 개수 포함).
#
# ⭐ 왜 필요한가(2026-09-03 실측): 세션 프로젝트와 코드 작업 워크트리가 다르면 계획이
#	「훅이 보는 곳」에 없고, 그때 도구는 「계획이 없다」와 「다른 데 있다」를 **같은 문장**으로
#	말했다. 사용자는 그것을 「계획을 다 닫았구나」로 읽었고, 게이트가 꺼진 채 12단계가 돌았다.
# ⚠ 이 함수는 **알리기만** 한다 — 남의 워크트리 계획을 자동으로 채택하지 않는다.
#	그것은 사람의 판단이고(워크트리를 나눈 이유가 있을 수 있다) 자동 채택은 fail-open 이다.
plan_other_worktrees() {
  base="$1"; root=''; list=''; dir=''; f=''; left=''
  root=$( CDPATH='' cd -- "$base/.." 2>/dev/null && pwd ) || return 0
  command -v git >/dev/null 2>&1 || return 0
  list=$(git -C "$root" worktree list --porcelain 2>/dev/null) || return 0
  printf '%s\n' "$list" | sed -n 's/^worktree //p' | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ "$dir" = "$root" ] && continue
    # ⭐ 고유화(2026-09-16) — 레거시 한 자리와 `plans/*/plan.md` 를 다 본다
    for f in "$dir/.claude/plan-active.md" "$dir"/.claude/plans/*/plan.md; do
      [ -f "$f" ] || continue
      left=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[[^xX]\]' "$f" 2>/dev/null || printf '0')
      case "$left" in ''|*[!0-9]*) left=0 ;; esac
      # ⚠ 미완료 0 인 계획은 **알리지 않는다**(2026-09-03 리뷰가 지목). 다 닫힌 지난주 잔재까지
      #   「다른 워크트리에 계획이 있다」로 말하면 그 문장이 거짓이고, 호출부가 그것 때문에
      #   「승인할 계획이 없다」 안내를 삼킨다.
      [ "$left" -gt 0 ] || continue
      printf '%s|%s\n' "$f" "$left"
    done
  done
}

# ── 결정 절(`## 결정 필요(승인 전)`) 파싱 — go-precheck 과 goal-echo 가 **공유**한다 ────
#
# ⚠⚠ 두 훅이 각자 정규식을 갖고 있었다(2026-09-03 리뷰가 지목). owner 파싱이 갈라졌던 것과
#   **같은 부류**이고, 여기서 갈라지면 한쪽은 「열림 1건」 다른 쪽은 「전부 닫힘」이 된다.
#
# ⚠ 표는 **마지막 열**을 본다. 처음엔 「파이프 4개 뒤」로 5번째 열을 고정했는데, 사용자가 근거
#   열을 하나 더 붙이면(6열) 정규식이 아무것도 못 잡아 **0** 이 되고, 0 을 「없음」으로 읽으면
#   미결 결정을 안은 채 착수한다 — 「0 이 나오면 탐지기부터 의심하라」를 이 파서가 밟을 뻔했다.

plan_decision_block() {   # <파일> — 결정 절 본문(없으면 빈 출력)
  awk '
    /^##[[:space:]]*결정 필요/ { inblk=1; next }
    inblk && /^##[[:space:]]/  { exit }
    inblk                      { print }
  ' "$1" 2>/dev/null
}

# plan_decision_count <본문> <open|done> — 열린/닫힌 결정 수.
# 체크박스(`- [ ]`/`- [x]`)와 표(마지막 열이 열림·⏳ / 닫힘·✅) 둘 다 센다.
plan_decision_count() {
  printf '%s\n' "$1" | awk -v want="$2" '
    # 체크박스
    /^[[:space:]]*[-*+][[:space:]]+\[[xX]\]/ { if (want=="done") n++; next }
    /^[[:space:]]*[-*+][[:space:]]+\[[^xX]\]/ { if (want=="open") n++; next }
    # 표 — 구분선·헤더는 건너뛰고 **마지막 셀**을 본다(열 수에 무관하다)
    /^[[:space:]]*\|/ {
      line=$0
      if (line ~ /^[[:space:]]*\|[[:space:]]*-+/) next          # |---|---| 구분선
      sub(/[[:space:]]*\|[[:space:]]*$/, "", line)              # 끝 파이프 제거
      k=split(line, cells, "|")
      last=cells[k]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", last)
      gsub(/\*/, "", last)
      if (want=="open" && last ~ /^(열림|⏳)/) n++
      else if (want=="done" && last ~ /^(닫힘|✅)/) n++
      next
    }
  END { print n+0 }'
}

# plan_decision_lines <본문> — 열린 항목 줄(사람이 읽는 목록용)
plan_decision_lines() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*[-*+][[:space:]]+\[[^xX]\]/ { print; next }
    /^[[:space:]]*\|/ {
      line=$0
      if (line ~ /^[[:space:]]*\|[[:space:]]*-+/) next
      sub(/[[:space:]]*\|[[:space:]]*$/, "", line)
      k=split(line, cells, "|"); last=cells[k]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", last); gsub(/\*/, "", last)
      if (last ~ /^(열림|⏳)/) print
    }'
}

# plan_boxes_excluding_decisions <파일> <all|done> — 계획 **본문**의 체크박스 수.
#
# ⚠⚠ 결정 절의 `- [ ] Q1 …` 을 「해야 할 단계」로 세면 안 된다(2026-09-03 리뷰가 지목).
#   그러면 완주 게이트가 「다음 항목을 진행하고 [x] 로 닫아라」라고 지시하는데, 그 항목은
#   **사용자에게 물어야 할 결정**이다 — 모델이 대신 정하고 닫게 되고, 그것이 이 기능이
#   막으려던 드리프트다. 같은 턴에 goal-echo 는 「먼저 닫아라(물어라)」를 낸다: 정반대 지시.
plan_boxes_excluding_decisions() {
  awk -v want="$2" '
    /^##[[:space:]]*결정 필요/ { skip=1; next }
    skip && /^##[[:space:]]/   { skip=0 }
    skip                       { next }
    want=="done" && /^[[:space:]]*[-*+][[:space:]]+\[[xX]\]/ { n++; next }
    want=="all"  && /^[[:space:]]*[-*+][[:space:]]+\[.\]/    { n++ }
  END { print n+0 }' "$1" 2>/dev/null
}

# ── 세션 스코프 — 이 세션이 그 파일을 「자기 것」으로 삼았나 (2026-09-16) ─────────────
#
# ⭐⭐ 왜 생겼나: 계획 파일은 **워크트리에 하나**다. 같은 워크트리에서 세션 A 가 계획을 진행하는
#   동안 세션 B 가 별건(예: 훅 점검)을 하면, B 의 Stop 마다 완주 게이트가 A 의 미완료로 B 를
#   막았다(2026-09-16 실측 — B 는 계획 파일을 한 번도 쓰지 않았고 go-review:go 도 부르지 않았다).
#   낡음 판별(계획 mtime ↔ 세션 첫 발화)은 「세션 시작 전 잔재」만 걸러서 이 경우를 못 본다.
#   게이트가 재려던 것은 「승인받은 계획을 완주했나」이고, 승인은 **세션이 한 행위**다. 그래서
#   그 행위의 흔적을 transcript 에서 본다.
#
# 흔적 셋 — 어느 하나면 채택이다:
#   ① 사람 프롬프트의 go 체인 호출 — `<command-name>/go-review:go</command-name>` ·
#      `<command-name>/go</command-name>` · 원문 `/go …` · (리뷰 파일용) `…/go-review:review-loop`
#   ② `Skill` 도구로 `go-review:go` · `go-review:review-loop` 호출
#   ③ 그 파일을 **쓴** 도구 호출 — Write/Edit/MultiEdit 의 file_path.
#      ⚠ 읽기(`cat`·`head`·`grep`)는 채택이 아니다 — 점검하는 세션이 딱 그것을 한다.
#      ⛔ Bash 의 `> <파일>` 재지향은 **보지 않는다**(2026-09-16 오후 · 첫 판에서 봤다가 뺐다).
#        이유: 그 판별은 명령 **문자열**을 보므로, 게이트를 점검·테스트하는 세션이 픽스처로
#        `printf '… cat > .claude/plan-active.md …'` 를 치면 그것을 「계획 파일을 썼다」로 읽는다.
#        실측: 그 세션이 남의 계획 35개로 세 번 막혔다 — Write/Edit 0회 · go 호출 0회였다.
#        「안전한 방향의 오탐」이라 두었는데, 게이트를 고치는 세션이 정확히 그 함정에 걸린다.
#        Bash 로 계획 파일을 쓰는 세션은 사실상 없다(/go·/plan 이 Write 를 쓴다) — 잃는 것이 없다.
#   ⚠ `/go-review:plan` 은 채택이 아니다(초안을 만드는 단계다).
#
# 반환: 0 = 채택 흔적 있음(무장) · 1 = 사람 발화는 있는데 흔적 없음(남의 것) ·
#       2 = 판별 불가(transcript 부재·읽기 실패·사람 발화 0·jq 없음)
# ⚠⚠ 호출부는 2 를 **0 처럼** 다뤄라 — 모르는 것을 근거로 게이트를 열지 않는다(기존 규약).
#
# ⚠ 한계를 알고 써라: ③은 **파일 이름**(basename)으로 맞춘다. 같은 세션이 앞 계획을 채택했다면
#   같은 워크트리의 다음 계획(같은 이름)도 채택한 것으로 본다 — 이름이 같은 파일을 두 번 쓰는
#   세션은 실제로 그 계획을 이어 쓰는 세션이므로 오탐 비용은 작다.
plan_session_claims() {   # <transcript> <파일 basename …>
  _sc_tr="$1"; shift
  command -v jq >/dev/null 2>&1 || return 2
  [ -n "$_sc_tr" ] && [ -f "$_sc_tr" ] || return 2
  _sc_names=""
  for _sc_n in "$@"; do _sc_names="$_sc_names $_sc_n"; done
  _sc_names="${_sc_names# }"
  [ -n "$_sc_names" ] || return 2
  _sc_out=$(jq -rR --arg names "$_sc_names" '
    def human: (.type=="user" and (has("toolUseResult")|not) and (.isMeta != true));
    def text: (.message.content
               | if type=="string" then .
                 elif type=="array" then (map(select(.type=="text") | (.text // "")) | join("\n"))
                 else "" end);
    # ⛔⛔ **이어하기 요약은 사람 발화가 아니다**(2026-09-16 실측). 대화가 길어지면 하네스가
    #   「This session is being continued…」로 시작하는 요약을 user 행으로 넣는데, 그 요약은
    #   지난 대화를 **인용**하므로 `/go` 문자열이 그대로 들어 있다. 그것을 세면 go 를 부른 적
    #   없는 세션이 레거시 계획의 주인이 된다 — 실제로 이 세션이 그렇게 남의 계획에 막혔다.
    #   같은 부류를 오늘만 두 번째 밟았다(Bash 재지향 · `5b29ada`). 자기 문맥이 자기 근거가
    #   되는 자리는 전부 의심해야 한다.
    # ⇒ ① 이어하기 요약 행은 제외한다 ② go 호출은 **프롬프트 앞머리**에서만 인정한다.
    #   실제 호출은 `<command-name>…` 이 첫 줄이다. 긴 문서 한가운데의 인용은 호출이 아니다.
    def is_resume: (text | test("^This session is being continued from a previous conversation")
                         or test("^이 세션은 이전 대화에서 이어집니다"));
    def head: (text | .[0:400]);
    def go_call: ((is_resume | not) and (head
               | test("<command-name>/go(-review:go|-review:review-loop)?</command-name>")
                 or test("(^|\n)[[:space:]]*/go(-review:go|-review:review-loop)?([[:space:]]|$)")));
    def names: ($names | split(" "));
    # ⭐⭐ 고유화(2026-09-16 실증이 잡았다) — 「/go 를 불렀다」·「Skill go-review:go 를 썼다」는 흔적은
    #   **레거시 단일 자리**(이름에 / 가 없는 plan-active.md 류)에만 채택이다. 그 자리는 워크트리에 하나라
    #   go 호출 = 그 계획이지만, `plans/<slug>/plan.md` 는 여럿이라 go 호출로는 어느 것인지 모른다.
    #   실측: 다른 세션(genOS · /go 1회)의 기록으로 돌리자 이 세션의 slug 계획이 첫 후보라서 잡혔다.
    #   slug 계획은 Write/Edit/MultiEdit 흔적으로만 채택된다(/go 가 초안을 plan.md 로 옮길 때 Write 를 쓴다).
    def legacy_asked: (names | any(contains("/") | not));
    def hits_name($p): (names | any(. as $n | ($p == $n) or ($p | endswith("/" + $n))));
    def claims_tool: (.type=="assistant" and any(.message.content[]?;
        .type=="tool_use" and (
          (legacy_asked and .name=="Skill" and ((.input.skill // "") | test("^go-review:(go|review-loop)$")))
          or ((.name=="Write" or .name=="Edit" or .name=="MultiEdit") and hits_name(.input.file_path // ""))
        )));
    fromjson?
    | if (human and go_call and legacy_asked) or claims_tool then "yes"
      elif human then "human"
      else empty end
  ' "$_sc_tr" 2>/dev/null | sort -u | tr '\n' ' ')
  case " $_sc_out" in
    *" yes "*)   return 0 ;;
    *" human "*) return 1 ;;
    *)           return 2 ;;
  esac
}

# ── 계획 파일 고유화 — 계획마다 디렉토리 하나 (2026-09-16) ──────────────────────
#
# ⭐⭐ 왜: 계획 상태가 워크트리마다 **고정 경로 넷**(plan-draft·plan-active·review-active·tester/opt-in)에
#   살아서, 같은 워크트리에서 세션이 둘이면 그대로 겹쳤다. 2026-09-02 에 세션별 파일로 나누려다
#   되돌린 이유는 「모델이 자기 session_id 를 알 수 없다」였다. 오늘 만든 채택 판별
#   (`plan_session_claims`)은 세션 번호가 아니라 **행위 흔적**으로 소유를 가르므로, 파일 이름만
#   고유하면 그 흔적도 고유해진다. 사용자 지시(2026-09-16): 「확실히 보장이 필요해. 다른 세션의
#   플랜과 이 세션의 플랜이 겹치지 않는 것이 필요해.」
#
# 규약:
#   정본   : <base>/plans/<slug>/{draft.md,plan.md,review.md}   ← 계획 하나 = 디렉토리 하나
#   레거시 : <base>/plan-draft.md · plan-active.md · review-active.md ← 단일 계획 자리. 그대로 인식한다
#   덮어쓰기: CLAUDE_PLAN_FILE · CLAUDE_PLAN_DRAFT_FILE · CLAUDE_REVIEW_FILE 이 있으면 **그것 하나만**
#   slug   : YYYYMMDD-<제목 kebab>(한글 허용 · 공백→- · 짧게). /plan 이 정한다. 여기서는 글롭만 한다.
#
# ⚠ 「채택」의 판정은 이 파일 위의 `plan_session_claims` 하나다 — 여기서 다시 정의하지 않는다.
#   후보의 이름을 그 함수에 맞게 만들어 넘기는 것(`plan_claim_name`)이 이 절의 일이다.

# plan_candidates <base> — 계획 파일 후보를 줄마다. 우선순위: env 하나 → plans/*/plan.md → 레거시
plan_candidates() {
  if [ -n "${CLAUDE_PLAN_FILE:-}" ]; then printf '%s\n' "$CLAUDE_PLAN_FILE"; return 0; fi
  _pc_d="$1"
  for _pc_f in "$_pc_d"/plans/*/plan.md; do [ -f "$_pc_f" ] && printf '%s\n' "$_pc_f"; done
  [ -f "$_pc_d/plan-active.md" ] && printf '%s\n' "$_pc_d/plan-active.md"
  return 0
}

# draft_candidates <base> — 초안 후보를 줄마다. 우선순위 같음
draft_candidates() {
  if [ -n "${CLAUDE_PLAN_DRAFT_FILE:-}" ]; then printf '%s\n' "$CLAUDE_PLAN_DRAFT_FILE"; return 0; fi
  _dc_d="$1"
  for _dc_f in "$_dc_d"/plans/*/draft.md; do [ -f "$_dc_f" ] && printf '%s\n' "$_dc_f"; done
  [ -f "$_dc_d/plan-draft.md" ] && printf '%s\n' "$_dc_d/plan-draft.md"
  return 0
}

# review_of <plan 경로> <base> — 그 계획의 리뷰 파일 경로(존재 여부 무관). env 가 있으면 그것.
review_of() {
  if [ -n "${CLAUDE_REVIEW_FILE:-}" ]; then printf '%s' "$CLAUDE_REVIEW_FILE"; return 0; fi
  case "$1" in
    */plans/*/plan.md) printf '%s' "${1%/plan.md}/review.md" ;;
    *)                 printf '%s' "$2/review-active.md" ;;
  esac
}

# plan_claim_name <파일> — `plan_session_claims` 에 넘길 이름. plans/<slug>/x.md 는 그 셋을 통째로
#   (basename 만 넘기면 모든 계획의 plan.md 가 같아진다 — 고유화의 의미가 사라진다).
plan_claim_name() {
  case "$1" in
    */plans/*/*.md) _cn="${1%/*}"; _cn="${_cn##*/plans/}"; printf 'plans/%s/%s' "$_cn" "${1##*/}" ;;
    *)              printf '%s' "${1##*/}" ;;
  esac
}

# plan_pick <base> <transcript> — 후보 가운데 **미완료가 있고 이 세션이 채택한** 첫 계획을 stdout 에.
#   채택 = claims rc 0, 또는 rc 2(판별 불가 → 모르는 것으로 게이트를 열지 않는다).
#   남의 것(rc 1)은 stderr 에 `foreign:<경로>|<미완료>` 로 낸다 — 호출부가 알림에 쓴다.
#   반환: 0 하나 골랐다 · 1 채택한 것 없음(남의 것만이거나 후보 없음)
plan_pick() {
  _pp_base="$1"; _pp_tr="$2"; _pp_picked=''
  while IFS= read -r _pp_f; do
    [ -n "$_pp_f" ] && [ -f "$_pp_f" ] || continue
    if command -v plan_boxes_excluding_decisions >/dev/null 2>&1; then
      _pp_all=$(plan_boxes_excluding_decisions "$_pp_f" all); _pp_done=$(plan_boxes_excluding_decisions "$_pp_f" done)
    else
      _pp_all=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[.\]' "$_pp_f" 2>/dev/null || printf '0')
      _pp_done=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[[xX]\]' "$_pp_f" 2>/dev/null || printf '0')
    fi
    case "$_pp_all"  in ''|*[!0-9]*) _pp_all=0 ;; esac
    case "$_pp_done" in ''|*[!0-9]*) _pp_done=0 ;; esac
    _pp_left=$((_pp_all - _pp_done))
    # ⚠ 체크박스 0개 파일은 **후보에 남긴다** — 호출부가 「판정 불가」 경고를 내야 한다(탐지기를 먼저 의심하라).
    #   전부 닫힌 파일(박스>0 · 남음 0)만 건너뛴다.
    [ "$_pp_all" -eq 0 ] || [ "$_pp_left" -gt 0 ] || continue
    # ⚠ CLAUDE_PLAN_FILE 도 채택 검사를 거친다 — 환경은 **어느 파일**만 좁히고 「이 세션의 것인가」는 흔적이 말한다
    #   (종전 동작이고 대조군이 그 계약을 잠근다 · 첫 판에 환경을 무조건 채택으로 두었다가 13건이 붉어졌다).
    plan_session_claims "$_pp_tr" "$(plan_claim_name "$_pp_f")"; _pp_rc=$?
    if [ "$_pp_rc" -ne 1 ]; then _pp_picked="$_pp_f"; break; fi
    printf 'foreign:%s|%s\n' "$_pp_f" "$_pp_left" >&2
  done <<EOF
$(plan_candidates "$_pp_base")
EOF
  [ -n "$_pp_picked" ] || return 1
  printf '%s' "$_pp_picked"
}

# draft_pick <base> <transcript> — 초안 후보 가운데 **이 세션이 쓴** 첫 것. 없으면 rc 1 · 남의 것은 stderr.
#   ⚠ 초안은 미완료 수를 보지 않는다(초안은 다 미완료다). 판별 불가(rc 2)도 채택으로 본다.
draft_pick() {
  _dp_base="$1"; _dp_tr="$2"; _dp_picked=''
  while IFS= read -r _dp_f; do
    [ -n "$_dp_f" ] && [ -f "$_dp_f" ] || continue
    plan_session_claims "$_dp_tr" "$(plan_claim_name "$_dp_f")"; _dp_rc=$?
    if [ "$_dp_rc" -ne 1 ]; then _dp_picked="$_dp_f"; break; fi
    printf 'foreign:%s\n' "$_dp_f" >&2
  done <<EOF
$(draft_candidates "$_dp_base")
EOF
  [ -n "$_dp_picked" ] || return 1
  printf '%s' "$_dp_picked"
}
