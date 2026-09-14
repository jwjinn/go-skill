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
    f="$dir/.claude/plan-active.md"
    [ -f "$f" ] || continue
    left=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[[^xX]\]' "$f" 2>/dev/null || printf '0')
    case "$left" in ''|*[!0-9]*) left=0 ;; esac
    # ⚠ 미완료 0 인 계획은 **알리지 않는다**(2026-09-03 리뷰가 지목). 다 닫힌 지난주 잔재까지
    #   「다른 워크트리에 계획이 있다」로 말하면 그 문장이 거짓이고, 호출부가 그것 때문에
    #   「승인할 계획이 없다」 안내를 삼킨다.
    [ "$left" -gt 0 ] || continue
    printf '%s|%s\n' "$f" "$left"
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
