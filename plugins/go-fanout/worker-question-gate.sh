#!/usr/bin/env bash
# worker-question-gate.sh — 병렬 워커가 **답을 기다리는데** 코디네이터가 턴을 끝내는 것을 막는다.
#
# # 왜 있나 (2026-09-15 실측)
#
# go-fanout §5 에 대기 루프 절차가 **이미 있었다**:
#   orca orchestration check --wait --types worker_done,escalation,question --timeout-ms 900000
# 그런데 그것은 **블로킹**이다. 코디네이터가 그 사이 다른 단계를 진행하려면 못 쓴다.
# 그래서 나는 비블로킹 `worker-list` 폴링을 택했고, 그것은 **상태만 보여주고 질문은 안
# 보여준다**. 폴링 루프가 끝난 뒤 실적 보고서를 쓰는 동안 워커 하나가 「코디네이터가 아직
# 답하지 않았습니다」를 화면에 적은 채 **멈춰 있었다.**
#
# ⚠ 워커 프리앰블이 「답 없이 진행하지 마라」라고 지시하므로, 코디네이터가 안 보면 워커는
#   타임아웃(기본 10~15분)까지 아무것도 못 한다. 실측: 한 워커가 5분 35초, 다른 워커가
#   4분 33초를 그렇게 버렸다.
#
# ⇒ 규율로는 안 된다. 절차는 이미 있었고 내가 안 따랐다.
#   이 저장소의 원칙 그대로다 — **「집행은 규율이 아니라 구조다」**(AGENTS.md 불변식 10).
#
# # 무엇을 보나
#
#   type == "question" 인 메시지 가운데, 같은 thread_id 를 가진 답변(type=status,
#   to_handle 이 dispatch: 로 시작)이 **없는** 것.
#
# # 원칙 셋 — 이 저장소의 다른 게이트와 공유한다
#
#   ① 훅 고장은 통과한다(orca 없음·런타임 없음·JSON 깨짐 → 조용히 exit 0).
#   ② 세션당 상한이 있다(CLAUDE_WORKER_Q_GATE_MAX · 기본 8) — 무한 차단을 만들지 않는다.
#   ③ 판정 불가는 **통과**다. ⚠ 다른 게이트(계획 완주)와 반대인데, 그 이유는
#      이 게이트가 막는 대상이 「내가 놓친 질문」이지 「내가 안 한 일」이 아니기 때문이다.
#      orca 를 안 쓰는 세션에서 이것이 차단하면 그 세션은 통째로 멈춘다.
#
# 산문 정본: ~/.claude/skills/go-fanout/SKILL.md §5(대기 루프).
#   ⚠ 그 절차를 여기 복사하지 않았다 — 이 훅은 「안 봤을 때 잡는 그물」이고 절차가 아니다.

set -uo pipefail

MAX="${CLAUDE_WORKER_Q_GATE_MAX:-8}"
# ⚠ 이름을 바꿀 수 있게 둔다. 대조군에서 「orca 가 없다」를 재려면 PATH 에서 지우는 것으로는
#   부족하다 — 시스템 orca 가 뒤에 남아 있어 **진짜 인박스를 읽는다**. 실측으로 그 검사가
#   그때그때의 파도 상태에 따라 붉었다 초록이었다 했다(2026-09-15). 다른 스크립트와도 맞춘다.
ORCA_BIN="${ORCA_BIN:-orca}"
STAMP="${TMPDIR:-/tmp}/worker-question-gate.$(id -u).count"

command -v "$ORCA_BIN" >/dev/null 2>&1 || exit 0          # ① orca 가 없다 → 이 세션은 대상이 아니다

# ⛔⛔ ①-b **워커 세션에서는 돌지 않는다** (2026-09-15 실측 — 워커 둘이 독립 보고)
#   이 훅은 브랜치에 커밋돼 모든 워크트리에 퍼진다. 그런데 워커 세션도 `orca` 를 갖고 있고
#   자기 인박스에도 `question` 이 있어서, **남의 질문 때문에 워커의 턴이 막혔다.** 그 워커는
#   코디네이터 문맥이 없어 답할 수도 없다 — 막기만 하고 풀 방법이 없는 게이트였다.
#   실측으로 한 워커가 세션당 상한 8회 중 2회를 그렇게 소모했다.
#   ⇒ 판별은 **터미널 핸들**이다. 이 세션의 핸들이 `worker-list` 의 `agentTerminalHandle`
#     집합에 있으면 나는 워커다. 코디네이터의 핸들은 거기 없다(실측으로 확인했다).
#   ⚠ 판별에 실패하면 **통과**한다(원칙 ③). 모르는 것을 근거로 남의 턴을 막지 않는다.
if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
  WL=$("$ORCA_BIN" orchestration worker-list --json 2>/dev/null) || WL=""
  if [ -n "$WL" ]; then
    printf '%s' "$WL" | ORCA_TERMINAL_HANDLE="$ORCA_TERMINAL_HANDLE" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)                                  # 판정 불가 → 게이트를 계속 돈다
ws = (d.get("result") or {}).get("workers") or []
mine = os.environ.get("ORCA_TERMINAL_HANDLE") or ""
handles = {w.get("agentTerminalHandle") for w in ws}
raise SystemExit(0 if mine and mine in handles else 1)
' 2>/dev/null && exit 0                                  # 내가 워커다 → 조용히 통과
  fi
fi

# ② 세션당 상한 — 같은 질문으로 무한히 막지 않는다
N=$(cat "$STAMP" 2>/dev/null || echo 0)
case "$N" in ''|*[!0-9]*) N=0 ;; esac
[ "$N" -ge "$MAX" ] && exit 0

OUT=$("$ORCA_BIN" orchestration inbox --json 2>/dev/null) || exit 0
[ -n "$OUT" ] || exit 0

PENDING=$(printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)                                  # ③ 판정 불가는 통과
ms = (d.get("result") or {}).get("messages") or []
if not ms:
    raise SystemExit(0)

# 답변: type=status 이고 to_handle 이 dispatch: 로 시작하며 thread_id 를 가진 것.
# ⚠ 스레드가 아니라 **질문보다 나중에 온 답**만 답변으로 센다 (2026-09-15).
#   종전에는 스레드 단위였다. 같은 스레드에 질문이 두 번 오면 첫 답이 두 번째 질문까지
#   「답했다」로 만들어, 워커가 답을 기다리는데 게이트가 조용해진다. 지금 구현은 질문마다
#   `thread_id` 가 자기 `id` 라 그 조건이 드러나지 않았지만, 드러나지 않는 것과 막혀 있는
#   것은 다르다. 순서는 `sequence`(없으면 `created_at`)로 본다.
def _ord(m):
    s = m.get("sequence")
    if isinstance(s, int):
        return (0, s)
    return (1, str(m.get("created_at") or ""))

answers = {}
for m in ms:
    if m.get("type") == "status" and str(m.get("to_handle") or "").startswith("dispatch:"):
        t = m.get("thread_id")
        if t:
            o = _ord(m)
            if t not in answers or o > answers[t]:
                answers[t] = o

out = []
for m in ms:
    if m.get("type") != "question":
        continue
    tid = m.get("thread_id") or m.get("id")
    # ⚠ 순서를 못 재면(둘 다 sequence·created_at 부재) 답으로 센다 — `>=` 다.
    #   `>` 로 두면 시각이 없는 런타임에서 답한 질문까지 미답변으로 읽혀 늘 막힌다.
    if tid in answers and answers[tid] >= _ord(m):
        continue
    # 질문 본문은 payload.question 에 있다(body 는 요약일 수 있다)
    q = ""
    try:
        q = (json.loads(m.get("payload") or "{}") or {}).get("question") or ""
    except Exception:
        pass
    q = (q or str(m.get("body") or "")).replace("\n", " ")[:160]
    out.append("%s|%s|%s" % (m.get("id"), str(m.get("from_handle") or "")[:24], q))
print("\n".join(out))
' 2>/dev/null) || exit 0

[ -n "$PENDING" ] || { : > "$STAMP"; exit 0; }          # 미답변 0 → 카운터도 리셋

echo "$((N+1))" > "$STAMP" 2>/dev/null || true

COUNT=$(printf '%s\n' "$PENDING" | grep -c .)
{
  echo "⛔ 병렬 워커가 답을 기다리는 질문이 ${COUNT}건 있는데 턴을 끝내려 했다."
  echo
  printf '%s\n' "$PENDING" | while IFS='|' read -r id from q; do
    echo "  · $id  (from ${from}…)"
    echo "      $q"
  done
  echo
  echo "워커 프리앰블이 「답 없이 진행하지 마라」라고 지시하므로 그 워커는 **멈춰 있다**."
  echo "지금 답해라:"
  echo "    orca orchestration reply --id <msg_id> --body \"<답>\""
  echo
  echo "⚠ 이 질문이 이미 다른 스레드에서 답해졌다면, 그 워커에게 그 사실을 알려라 —"
  echo "  워커는 자기 스레드의 답만 본다:"
  echo "    orca orchestration send --to dispatch:<ctx_id> --subject \"...\" --body \"...\""
  echo
  echo "(이 게이트는 세션당 ${MAX}회까지만 막는다 · 현재 $((N+1))회)"
} >&2
exit 2
