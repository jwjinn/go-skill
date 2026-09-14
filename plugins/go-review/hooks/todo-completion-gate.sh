#!/usr/bin/env bash
# Stop 훅 — 미완료 TodoWrite 항목이 남은 채로 턴을 끝내려 하면 종료를 거부한다.
#
# 왜: 다단계 계획("C1~C6 다 해라")을 승인받고도 1단계만 하고 "이어할까요?" 로 멈추는 일이
# 반복됐다. 방어가 이미 둘 있었는데 둘 다 규율이었다 —
#   ① memory/multiphase-run-to-completion.md : 관련 판단될 때만 소환돼 정작 단계 경계에 없다
#   ② CLAUDE.md 전역 불변식 10             : 항상 로드되지만 지키는 주체가 여전히 모델이다
# 이 훅이 세 번째이자 유일한 구조적 계층이다. 하네스가 종료를 거부하므로 규율에 의존하지 않는다.
# (근거: "규율이 아니라 구조로" — 지킬 것을 사람의 기억이 아니라 타입·구조에 담는다)
#
# stdin : Stop 훅 JSON(session_id·transcript_path·stop_hook_active)
# stdout: {"decision":"block","reason":…} 또는 없음(통과)
# 항상 exit 0 — 훅 자체 오류로 정상 종료를 막지 않는다(관측이 서비스를 죽이면 안 된다).

#
# ⛔ **브랜치 게이팅을 여기에 복사하지 마라** (2026-08-24).
#   `notion-sync-gate`·`arch-report-gate` 는 **공유 표면**(Notion 현황판·as-is 보고서)에
#   올리는 일을 재촉하므로 main 에서만 말한다. 이 훅은 다르다 — **지금 해야 하는 일**을
#   말한다(라이브를 바꿨으면 지금 선언해야 하고, 계획 완주는 브랜치 문제가 아니다).
#   피처 브랜치에서 조용해지면 그 순간 이 게이트의 존재 이유가 사라진다.
set -u

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

# ⛔ **jq 가 없으면 이 축은 아무것도 보지 않는다** — 아래의 모든 판정이 jq 를 거친다.
#   종전에는 `… | jq … || exit 0` 로 떨어져 **출력 0바이트 · rc=0** 이었다(조용한 fail-open).
#   막지는 않되(도구 부재는 사람이 고칠 일이다) **침묵하지는 않는다**. 근거는 `_deps.sh` 머리말.
if ! command -v jq >/dev/null 2>&1; then
  . "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_deps.sh" 2>/dev/null || exit 0
  deps_jq_missing_notice "계획 완주 게이트(도구 축 — 마지막 TodoWrite)"
  exit 0
fi

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null) || exit 0
session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null) || exit 0
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# 이 세션의 마지막 TodoWrite 상태. 없으면(계획을 안 세운 턴) 관여하지 않는다.
todos=$(jq -c 'select(.type=="assistant")
               | .message.content[]?
               | select(.type=="tool_use" and .name=="TodoWrite")
               | .input.todos' "$transcript" 2>/dev/null | tail -1)
[ -n "$todos" ] || exit 0

left=$(printf '%s' "$todos" | jq '[.[] | select(.status != "completed")] | length' 2>/dev/null) || exit 0
[ "${left:-0}" -gt 0 ] 2>/dev/null || exit 0

# ⭐⭐ **낡은 계획은 붙잡지 않는다** — 이 게이트의 맹점이었다(2026-08-19 실사고).
#
# 이 훅은 transcript 의 **마지막 TodoWrite** 를 본다. 그런데 세션 중 TodoWrite 도구가 사라지면
# (MCP 서버 단절 — 실제로 일어났다) 모델은 목록을 닫을 수단이 없고, 훅은 **영구히 낡은 목록**을
# 읽어 상한(8회)까지 정상 종료를 거부한다. 그 항목들이 다 끝나고 배포까지 됐는데도.
#
# 판별 기준은 **사용자가 그 계획 이후로 말했는가** 하나다:
#   · 원래 잡으려던 경우(요청 → 계획 → 1단계만 하고 멈춤)에는 계획이 **마지막 사용자 메시지
#     뒤**에 있으므로 **그대로 차단**된다(기존 동작 그대로다).
#   · 사용자가 새 지시를 여러 번 준 뒤라면 계획은 그 앞에 있다 — 그 목록은 지금 요청의 계획이
#     아니고, 붙잡는 것은 오탐이다.
#
# ⚠ 게이트를 느슨하게 하는 것이 아니라 **입력 채널이 죽었을 때의 동작을 정하는** 것이다.
#   이 파일 머리말의 원칙을 그대로 확장한다: "훅 자체 오류로 정상 종료를 막지 않는다
#   (관측이 서비스를 죽이면 안 된다)". 입력 고장도 훅의 고장이다.
# ⚠ 줄 번호로 비교한다 — transcript 는 JSONL 이라 줄 순서가 곧 시간 순서다. 둘 중 하나라도
#   못 구하면 판별을 포기하고 기존 동작(차단)으로 간다 — 모르는 것을 근거로 게이트를 열지 않는다.
#
# ⭐⭐ **"사용자 메시지" 는 사람이 쓴 것만이다**(2026-08-22 — 이 판별이 게이트를 통째로 죽였다).
#   최초 구현은 `grep '"type":"user"'` 였는데, **도구 결과도 `type:"user"` 로 기록된다**.
#   실측: 한 세션의 user 행 2,070개 중 **1,922개(92.9%)가 도구 결과**(`toolUseResult` 보유).
#   TodoWrite 호출 뒤에는 그 턴 안에서 반드시 도구가 더 돌므로 그 결과 행이 뒤에 쌓이고,
#   Stop 시점에는 **언제나** user_at > todo_at 이 되어 「낡은 계획」으로 오판했다.
#   라이브 재현: 미완료 TodoWrite 를 가진 transcript **12개 전부**가 그 턴의 Stop 에서 통과
#   (TodoWrite 와 다음 사람 프롬프트 사이에 도구결과가 1~34행). 즉 2026-08-19 의 오탐 수정이
#   게이트를 **무장해제**했고, 컴파일도 테스트도 통과하는 채로 조용히 그랬다.
#   ⚠ 대조군 테스트가 못 잡은 이유: 그때 만든 t6/t7 가 user 행을 **사람 프롬프트만으로** 구성해
#   도구결과가 섞인 실제 모양을 재현하지 않았다(그래서 아래 t9 를 추가했다).
# ⚠ 제외 대상 둘: `toolUseResult` 보유(도구 결과) · `isMeta:true`(스킬·슬래시명령 주입).
#   실측으로 isMeta 행은 스킬 프롬프트·`<local-command-caveat>` 였다 — 사람의 지시가 아니다.
# ⚠ grep 이 아니라 jq `input_line_number` 로 센다 — 필터 조건이 JSON 구조라서
#   문자열 매칭으로는 같은 줄의 다른 필드를 잘못 집을 수 있다.
todo_at=$(jq -r 'select(.type=="assistant")
                 | select(any(.message.content[]?; .type=="tool_use" and .name=="TodoWrite"))
                 | input_line_number' "$transcript" 2>/dev/null | tail -1)
# ⭐ `head -1` — 세션의 **첫** 사람 발화 줄이다(2026-09-02 개정).
#   ⚠⚠ 이전에는 `tail -1`(마지막)이었고 그것이 이 게이트를 구조적으로 무력화했다:
#     대화형 세션에서 사용자는 작업 내내 말하므로 `마지막 발화 줄 > TodoWrite 줄` 이
#     거의 항상 참이 되어 **목록을 만든 그 턴에만 무장**됐다. 2026-08-22 에 도구 결과를
#     안 걸러 3일간 죽어 있던 것과 **다른 원인·같은 결과**다.
#   TodoWrite 는 언제나 이 transcript 안에 있으므로 첫 발화보다 뒤다 → 미완료 목록이
#   있으면 무장한다. 그것이 이 축이 재려던 것이다.
user_at=$(jq -r 'select(.type=="user" and (has("toolUseResult")|not) and (.isMeta != true))
                 | input_line_number' "$transcript" 2>/dev/null | head -1)
case "${todo_at:-x}" in ''|*[!0-9]*) todo_at='' ;; esac
case "${user_at:-x}" in ''|*[!0-9]*) user_at='' ;; esac
if [ -n "$todo_at" ] && [ -n "$user_at" ] && [ "$todo_at" -lt "$user_at" ] 2>/dev/null; then
  exit 0   # 첫 사람 발화보다 앞선 TodoWrite → 이 세션의 것이 아니다(구조상 드물다)
fi

# 무한루프 방지: 세션당 차단 횟수 상한. stop_hook_active 만 보면 단 1회만 붙잡게 되어
# 3단계짜리 계획을 완주시키지 못한다 — 그래서 카운터로 상한을 둔다.
max=${CLAUDE_TODO_GATE_MAX:-8}
cnt_file="${TMPDIR:-/tmp}/claude-todo-gate-${session}"
cnt=$(cat "$cnt_file" 2>/dev/null || printf '0')
case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
[ "$cnt" -lt "$max" ] || exit 0
printf '%s' "$((cnt + 1))" > "$cnt_file" 2>/dev/null

total=$(printf '%s' "$todos" | jq 'length' 2>/dev/null || printf '?')
list=$(printf '%s' "$todos" \
  | jq -r '[.[] | select(.status != "completed")
            | "  - [\(.status)] \(.content)"] | join("\n")' 2>/dev/null)

reason="계획 ${total}단계 중 ${left}개가 미완료인데 턴을 끝내려 했다.

${list}

승인된 다단계 계획은 완주한다(CLAUDE.md 전역 불변식 10). 단계 경계는 멈춤 지점이 아니다 —
\"이어할까요?\" 를 묻지 말고 다음 항목을 in_progress 로 바꾸고 계속 진행하라.

정말 멈춰야 하는 경우는 둘뿐이고, 그때는 멈추기 전에 그 사유를 말해야 한다:
  ① 사용자 답 없이는 진행이 무의미한 설계 갈림길 → AskUserQuestion 으로 물어라
  ② 남은 항목이 이 요청의 범위가 아님(사용자가 \"C2까지만\" 이라 했거나 계획이 낡음)
     → 해당 항목을 completed 가 아니라 목록에서 제거하고, 왜 뺐는지 사용자에게 말하라"

jq -n --arg r "$reason" '{decision: "block", reason: $r}' 2>/dev/null

exit 0
