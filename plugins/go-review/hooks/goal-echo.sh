#!/usr/bin/env bash
# goal-echo.sh — UserPromptSubmit 훅. 활성 계획의 **목표 계약**을 매 턴 문맥에 다시 넣는다.
#
# 왜 필요한가:
#   긴 다단계 작업에서 드리프트는 "딴짓을 하기로 결심해서" 생기지 않는다. 원 요청이 문맥
#   뒤로 밀려나 **무엇을 위해 이걸 하는지가 흐려질 때** 생긴다. 그때부터 "김에 고친 것"이
#   조용히 쌓이고, 리뷰에서야 범위 밖 변경으로 드러난다.
#   체크박스는 "무엇을 하는가"를 남기지만 "무엇을 위해"는 남기지 않는다 — 이 훅이 그 자리다.
#
#   ⚠ 이것은 **재촉이 아니라 재정렬**이다. 할 일을 늘리지 말고 원 요청과 범위 밖만 되읽어 준다.
#     길어지면 매 턴 비용이 되고, 비용이 되면 사람이 훅을 끈다.
#
# 조건(좁게 잡는다 — 넓히면 소음이고, 소음이 되면 아무도 안 읽는다):
#   ㉠ 계획 파일이 있고  ㉡ 미완료 항목이 남아 있고  ㉢ 파일이 최근 것이다(기본 48h)
#   셋 중 하나라도 아니면 **조용히 통과**한다. 특히 ㉡ — 다 끝난 계획은 재정렬할 목표가 없다.
#
# stdin : UserPromptSubmit JSON(session_id·prompt·transcript_path…)
# stdout: 평문 → Claude 의 문맥에 주입된다(이 이벤트는 평문 stdout 이 곧 컨텍스트다)
# 항상 exit 0 — 훅 고장이 프롬프트를 막으면 안 된다(exit 2 는 프롬프트를 **지운다**).
set -u

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

# ⛔ jq 가 없으면 목표 계약이 문맥에 재주입되지 않는다 — 근거는 `_deps.sh` 머리말.
if ! command -v jq >/dev/null 2>&1; then
  . "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_deps.sh" 2>/dev/null || exit 0
  deps_jq_missing_text "매 턴 목표 재주입(goal-echo)"
  exit 0
fi

session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null) || exit 0

# ── 계획 파일 경로 — plan-file-gate.sh 와 **같은 규칙**이어야 한다 ──────────────
# ⚠ 두 훅이 다른 파일을 보면 "게이트가 잡는 계획"과 "화면에 되읽히는 목표"가 어긋난다.
#   같은 사실을 두 곳에서 다르게 알면 안 된다 — 반복해서 밟히는 함정이다.
# ⚠ 세션별 계획 파일 분기는 **의도적으로 없다**(2026-09-02 에 넣었다가 되돌렸다) —
#   모델이 자기 session_id 를 알 수단이 없어 아무도 그 파일을 만들지 못했다. 근거는
#   plan-file-gate.sh 머리말에 있다. 세 훅이 **정확히 같은 규칙**이어야 게이트가 잡는 계획과
#   여기서 되읽는 목표가 어긋나지 않는다.
# ⭐ 경로·결정 절 파싱은 **공용 함수**를 쓴다(`_planpath.sh`). 세 훅이 각자 하면 갈라진다 —
#   실제로 owner 파싱이 그랬고, 2026-09-03 리뷰가 결정 절 정규식에서 같은 부류를 다시 지목했다.
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_planpath.sh" 2>/dev/null || true
if [ -n "${CLAUDE_PLAN_FILE:-}" ]; then
  plan="$CLAUDE_PLAN_FILE"
elif command -v plan_base >/dev/null 2>&1; then
  plan="$(plan_base)/plan-active.md"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  plan="$CLAUDE_PROJECT_DIR/.claude/plan-active.md"
else
  plan="${PWD}/.claude/plan-active.md"
fi
[ -f "$plan" ] || exit 0

# ㉡ 미완료가 남았는가 — 다 끝난 계획은 되읽을 목표가 없다
# ⚠⚠ **결정 절의 체크박스는 「해야 할 단계」가 아니다**(2026-09-03 리뷰가 지목).
#   그것을 세면 완주 게이트가 「다음 항목을 진행하고 [x] 로 닫아라」라고 지시하는데, 그 항목은
#   사용자에게 **물어야 할 결정**이다 — 모델이 대신 정하고 닫게 되고 그것이 드리프트다.
if command -v plan_boxes_excluding_decisions >/dev/null 2>&1; then
  boxes=$(plan_boxes_excluding_decisions "$plan" all)
  done_n=$(plan_boxes_excluding_decisions "$plan" done)
else
  boxes=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[.\]' "$plan" 2>/dev/null || printf '0')
  done_n=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[[xX]\]' "$plan" 2>/dev/null || printf '0')
fi
case "$boxes"  in ''|*[!0-9]*) boxes=0 ;; esac
case "$done_n" in ''|*[!0-9]*) done_n=0 ;; esac
left=$((boxes - done_n))
[ "$boxes" -gt 0 ] && [ "$left" -gt 0 ] || exit 0

# ㉢ 최근 것인가 — 지난주 잔재가 새 세션마다 말을 걸면 그것이 오탐이다
max_age=${CLAUDE_GOAL_ECHO_MAX_AGE_H:-48}
mt=$(stat -f %m "$plan" 2>/dev/null || stat -c %Y "$plan" 2>/dev/null)
case "${mt:-x}" in ''|*[!0-9]*) mt='' ;; esac
if [ -n "$mt" ]; then
  now=$(date +%s 2>/dev/null || printf '0')
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  if [ "$now" -gt 0 ]; then
    age_h=$(( (now - mt) / 3600 ))
    [ "$age_h" -le "$max_age" ] || exit 0
  fi
fi

# ── 목표 계약 추출 ───────────────────────────────────────────────────────────
# 「## 목표 계약」 다음부터 다음 「## 」 전까지. 없으면 그 사실 자체를 말한다
# (계약 없는 계획은 드리프트를 판정할 근거가 없다는 뜻이므로 조용히 넘기지 않는다).
contract=$(awk '
  /^##[[:space:]]*목표 계약/ { inblk=1; next }
  inblk && /^##[[:space:]]/  { exit }
  inblk                      { print }
' "$plan" 2>/dev/null | sed -e 's/[[:space:]]*$//' | grep -v '^$')

printf '[활성 계획 — 목표 재정렬]\n'
if [ -n "$contract" ]; then
  # ── 절단은 줄 수가 아니라 **절 단위**로 한다 ──────────────────────────────
  # ⚠ 처음엔 `head -12` 였다. go.md 규약대로 쓴 계약은 원 요청 인용만 8줄이 넘어서
  #   「범위 밖」 블록이 통째로 잘렸다 — **드리프트를 막으려고 만든 바로 그 항목**이
  #   매 턴 사라졌고, 절단 표시가 없어 읽는 쪽은 계약에 범위 밖이 없다고 읽었다.
  #   리뷰어가 실행으로 재현했다(`grep -c '범위 밖'` = 0).
  #   그래서: 넘치면 앞부분을 자르되 **범위 밖은 반드시 살리고 잘렸다는 사실을 말한다.**
  max_lines=${CLAUDE_GOAL_ECHO_MAX_LINES:-24}
  case "$max_lines" in ''|*[!0-9]*) max_lines=24 ;; esac
  [ "$max_lines" -ge 8 ] || max_lines=8
  total=$(printf '%s\n' "$contract" | grep -c .)
  if [ "$total" -le "$max_lines" ]; then
    printf '%s\n' "$contract"
  else
    keep=$((max_lines - 4))          # 절단 표시 1줄 + 범위 밖 최대 3줄 자리를 남긴다
    printf '%s\n' "$contract" | head -"$keep"
    printf '… (계약 %s줄 중 %s줄 생략 — 전문은 %s)\n' "$total" "$((total - keep))" "$plan"
    # 범위 밖이 이미 살아남았으면 다시 찍지 않는다(중복은 그 자체로 소음이다)
    so_line=$(printf '%s\n' "$contract" | grep -n '^범위 밖' | head -1 | cut -d: -f1)
    if [ -n "$so_line" ] && [ "$so_line" -gt "$keep" ]; then
      printf '%s\n' "$contract" | awk '/^범위 밖/{f=1} f{print}' | head -3
    fi
  fi
else
  printf '⚠ 이 계획 파일에 「## 목표 계약」 절이 없다 — 원 요청·수용 기준·범위 밖이 어디에도\n'
  printf '  적혀 있지 않으므로 「범위를 벗어났는가」를 판정할 근거가 없다. /go 규약대로 추가하라.\n'
fi
# ── ⭐ 확정 결정 재주입(G9 · 2026-09-03) ────────────────────────────────────────
# 승인 전에 닫은 결정(목업 선택·배포 주체 등)은 계획의 나머지가 의존하는 사실이다. 긴 작업에서
# 그것이 문맥 밖으로 밀리면 모델이 「다시 정한다」 — 사용자가 이미 답한 것을 또 묻거나 다르게 간다.
# 그래서 「## 결정 필요(승인 전)」 절의 **닫힌** 항목만 짧게 되읽는다(열린 항목은 있을 수 없다 —
# go.md §0-c 가 전부 닫힌 뒤에만 옮긴다. 있다면 그것 자체가 이상이라 함께 말한다).
dec=$(plan_decision_block "$plan" 2>/dev/null)
if [ -n "$dec" ]; then
  max_dec=${CLAUDE_GOAL_ECHO_MAX_DECISIONS:-8}
  case "$max_dec" in ''|*[!0-9]*) max_dec=8 ;; esac
  n_closed=$(plan_decision_count "$dec" done)
  opened=$(plan_decision_count "$dec" open)
  case "$n_closed" in ''|*[!0-9]*) n_closed=0 ;; esac
  case "$opened" in ''|*[!0-9]*) opened=0 ;; esac
  if [ "$n_closed" -gt 0 ]; then
    printf '**확정 결정**(승인 전에 닫힘 — 다시 묻지 말고 이대로 간다):\n'
    printf '%s\n' "$dec" | awk '
      /^[[:space:]]*[-*+][[:space:]]+\[[xX]\]/ { sub(/^[[:space:]]*[-*+][[:space:]]*\[[xX]\][[:space:]]*/,""); print; next }
      /^[[:space:]]*\|/ {
        line=$0
        if (line ~ /^[[:space:]]*\|[[:space:]]*-+/) next
        sub(/[[:space:]]*\|[[:space:]]*$/, "", line)
        k=split(line, cells, "|"); last=cells[k]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", last); gsub(/\*/, "", last)
        if (last ~ /^(닫힘|✅)/) { sub(/^[[:space:]]*\|[[:space:]]*/, "", $0); print }
      }' | cut -c1-120 | head -"$max_dec" | sed -e 's/^/  ✔ /'
    [ "$n_closed" -gt "$max_dec" ] && printf '  … 외 %s건(전문은 계획 파일)\n' "$((n_closed - max_dec))"
  elif [ "$opened" -eq 0 ]; then
    # ⚠ 절은 있는데 한 줄도 못 읽었다 — 0 을 「없음」으로 단언하지 않는다(탐지기를 먼저 의심하라).
    printf '⚠ 결정 필요 절이 있는데 **한 줄도 파싱되지 않았다**(열림·닫힘 둘 다 0) — 형식을 확인해라.\n'
  fi
  [ "$opened" -gt 0 ] && printf '⚠ 결정 필요 절에 **열린 항목 %s건**이 승인 뒤에도 남아 있다 — 계획 안에서 사용자 답을 기다리게 된다. 먼저 닫아라.\n' "$opened"
fi
printf -- '― 남은 항목 %s/%s · 계획: %s\n' "$left" "$boxes" "$plan"
printf '이 요청이 위 목표에 속하지 않으면, 계획에 끼워 넣지 말고 별건임을 사용자에게 말해라.\n'

exit 0
