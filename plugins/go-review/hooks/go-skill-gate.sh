#!/usr/bin/env bash
# go-skill-gate.sh — PreToolUse(Skill) 훅. **모델이 스스로 `/go` 를 부르는 것**을 사전 점검한다(2026-10-05).
#
# 왜 필요한가:
#   `go-precheck.sh` 는 UserPromptSubmit 훅이라 **사람이 친** `/go` 에만 걸린다. 그런데 모델은 Skill
#   도구로 `go-review:go` 를 직접 부를 수 있고, 그 경로에는 아무 검사도 없었다.
#   2026-10-05 실측: 결정 절에 열린 항목(노드 자원 목업 선택)이 남은 채로 모델이 `/go` 를 스스로 불렀고,
#   go.md §0-c 는 「착수하지 마라」라고 적고 있었지만 지시문일 뿐이라 막지 못했다. 사용자 지시:
#   「스킬안에 플랜들이 제대로 되었는지 확인을 하는 것도 있지 않나? 지금같은 것들은 막고 싶은데」.
#
# 무엇을 막나(하나라도 걸리면 exit 2 = 그 Skill 호출을 거부한다):
#   ① 이 세션의 초안이 없다(승인할 계획이 없다 — go.md §0-b 경로 ③)
#   ② 「## 결정 필요(승인 전)」 절에 열린 항목이 있다(go.md §0-c)
#   ③ `_plancheck.py all` 위반 — 요구 추적표 · 이전 결정 대조 · 최종 검증(V) 절
#
# ⚠ 이미 채택된 계획(plans/<slug>/plan.md · 레거시 plan-active.md)이 있으면 막지 않는다 —
#   그것은 승인된 계획을 이어 가는 경로 ①이다(사람이 이미 승인했다).
# ⚠ **잴 수 없음(rc 2)은 막는다** — 「모르면 연다」면 이 게이트는 대화 기록 경로 하나만 틀려도 꺼진다.
#   다만 **훅 자체의 고장**(파이썬 부재 · 입력 깨짐)은 통과시키고 그 사실을 stderr 에 남긴다
#   (이 플러그인의 원칙: 훅 고장은 통과 · 판별 불가는 차단 유지).
#
# stdin : PreToolUse JSON(tool_name · tool_input.skill · transcript_path · session_id …)
# stdout: 없음 · stderr: 거부 사유(모델에게 보인다)
# exit  : 0 통과 · 2 거부
set -u
input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0
command -v python3 >/dev/null 2>&1 || { echo "go-skill-gate: python3 없음 — 점검 생략(훅 고장은 통과)" >&2; exit 0; }

read_field() {
  printf '%s' "$input" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
k=sys.argv[1]
v=d
for p in k.split("."):
    v=v.get(p) if isinstance(v,dict) else None
print(v if isinstance(v,str) else "")
' "$1" 2>/dev/null
}

tool=$(read_field tool_name)
[ "$tool" = "Skill" ] || exit 0
skill=$(read_field tool_input.skill)
case "$skill" in
  go-review:go|go) ;;
  *) exit 0 ;;
esac
transcript=$(read_field transcript_path)

SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SELF/_planpath.sh" 2>/dev/null || { echo "go-skill-gate: _planpath.sh 를 읽지 못함 — 점검 생략(훅 고장은 통과)" >&2; exit 0; }
base=$(plan_base) || { echo "go-skill-gate: 계획 위치를 정하지 못함 — 점검 생략" >&2; exit 0; }

# 경로 ① — 이 세션이 채택한 미완료 계획이 이미 있으면 이어 가는 것이다
if plan_pick "$base" "$transcript" >/dev/null 2>&1; then
  exit 0
fi

draft=$(draft_pick "$base" "$transcript" 2>/dev/null) || draft=''
if [ -z "$draft" ]; then
  {
    echo "⛔ /go 를 스스로 부르려 했지만 이 세션의 초안(.claude/plans/<slug>/draft.md)이 없다 — 승인할 계획이 없다(go.md §0-b 경로 ③)."
    echo "   사용자에게 계획을 보여 주고 사용자가 /go 를 승인하게 하라."
  } >&2
  exit 2
fi

reasons=''
dec=$(plan_decision_block "$draft" 2>/dev/null || printf '')
if [ -n "$dec" ]; then
  open=$(plan_decision_count "$dec" open)
  case "$open" in ''|*[!0-9]*) open=0 ;; esac
  if [ "$open" -gt 0 ]; then
    reasons="${reasons}⛔ 결정 필요(승인 전) 절에 열린 항목 ${open}건 — go.md §0-c: 닫기 전에는 착수하지 않는다.
$(plan_decision_lines "$dec" | sed -e 's/^[[:space:]]*//' | cut -c1-110 | sed -e 's/^/   · /' | head -8)
"
  fi
fi

pc_out=$(python3 "$SELF/_plancheck.py" all --draft "$draft" --transcript "$transcript" --base "$base" 2>&1); pc_rc=$?
case "$pc_rc" in
  0) ;;
  1) reasons="${reasons}⛔ 계획 점검(_plancheck.py) 위반:
${pc_out}
" ;;
  2) reasons="${reasons}⛔ 계획 점검을 **재지 못했다**(rc 2) — 모르는 것을 근거로 착수하지 않는다:
${pc_out}
" ;;
  *) echo "go-skill-gate: _plancheck.py 가 예상 밖 종료(rc ${pc_rc}) — 점검 생략(훅 고장은 통과)" >&2 ;;
esac

if [ -n "$reasons" ]; then
  {
    echo "go-review: 이 /go 자가 호출을 거부한다 — 초안: ${draft}"
    printf '%s' "$reasons"
    echo "→ 위를 고친 뒤 사용자에게 보여 주고 승인을 받아라. 사용자가 직접 /go 를 치는 경로는 이 게이트가 아니라 go.md §0 이 본다."
  } >&2
  exit 2
fi
exit 0
