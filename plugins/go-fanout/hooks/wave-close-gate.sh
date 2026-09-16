#!/usr/bin/env bash
# wave-close-gate.sh — 파도가 **끝났는데 마감하지 않은 채** 턴을 끝내는 것을 막는다.
#
# # 왜 있나 (2026-09-13 실측)
#
# 워커 13명이 전부 끝난 뒤에도 터미널 **15개**와 워크트리 **13개**가 밤새 살아 있었다.
# `worker-release` 규약도 `cleanup.sh` 도 **이미 있었다.** 빠진 것은 그것을 부르는 시점이고,
# 맨 끝 단계에 두었더니 그 단계에 닿기 전에 밤이 갔다.
#
# ⇒ 이 훅은 「할 일이 남았다」를 세는 것이 아니라 **「자원이 살아 있다」를 센다.**
#   계획 체크박스와 독립이다 — 계획을 다 닫아도 워크트리는 남을 수 있다.
#
# # 무엇을 보나
#
#   이 run 의 워커 가운데 ①아직 도는 것이 **없고** ②회수되지 않은 자원이 **있는** 상태.
#   그 둘이 동시에 참이면 「파도는 끝났는데 아무도 안 치웠다」이다.
#
# # 원칙 넷 — 이 저장소의 다른 게이트와 공유한다
#
#   ① 훅 고장은 통과한다(orca 없음·JSON 깨짐 → 조용히 exit 0).
#   ② 세션당 상한이 있다(CLAUDE_WAVE_CLOSE_GATE_MAX · 기본 8).
#   ③ 판정 불가는 통과다 — 이 게이트가 막는 것은 「내가 안 치운 것」이고, 모르는 것을 근거로
#      막으면 orca 를 안 쓰는 세션이 통째로 멈춘다.
#   ④ ⛔⛔ **워커 세션에서는 돌지 않는다.** 2026-09-15 에 같은 부류의 훅이 워커의 턴을
#      막았고, 워커는 코디네이터 문맥이 없어 그것을 풀 수단이 없었다. 판별은 터미널 핸들이다.
set -uo pipefail

MAX="${CLAUDE_WAVE_CLOSE_GATE_MAX:-8}"
STAMP="${TMPDIR:-/tmp}/wave-close-gate.$(id -u).count"

# ⭐ 이 플러그인의 루트 — 안내 문구가 **실제로 실행되는 경로**를 말해야 한다 (2026-09-16 포장).
#   `CLAUDE_PLUGIN_ROOT` 는 훅으로 불릴 때 하네스가 준다. 직접 실행·테스트에서는 없으므로
#   자기 위치에서 구한다(`hooks/` 의 부모). ⚠ 심링크 설치와 마켓플레이스 설치에서 경로가
#   다르므로 **고정 문자열을 적지 마라** — 그러면 받는 쪽이 없는 경로를 친다.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}"
ORCA_BIN="${ORCA_BIN:-orca}"

# ⭐⭐ 세션 스코프 (2026-09-16) — **이 세션이 관여한 run** 만 막는다.
#   실측: 훅을 점검하던 세션이 지난 사흘의 fan-out 세 차수(잔여 컨텍스트 11개)로 매 턴 막혔다.
#   그 세션은 그 run 을 띄우지도 본 적도 없었다. 판별은 transcript 다 — 코디네이터는 run_id 를
#   도구 호출(`--run …`)이나 도구 결과(`worker-list` 출력)로 반드시 만난다. 인계로 코디네이션을
#   이어받은 세션도 `worker-list` 를 한 번 부르면 그때부터 막힌다(인계문이 그것을 시킨다).
#   ⚠ **사람 발화 행은 보지 않는다** — 이 게이트의 차단 문구 자체가 사람 발화 행으로 transcript 에
#     남으므로, 그것을 세면 한 번 막힌 세션은 영원히 「관여한 세션」이 된다.
#   ⚠ stdin 이 없거나 transcript 를 못 읽으면 **종전대로 전부 본다**(판별 불가로 게이트를 좁히지 않는다).
#   ⚠⚠ 읽기에 **시간 상한**을 둔다. `cat` 으로 받으면 stdin 이 열린 채로 넘어온 호출에서 훅이
#     영영 멈추고, 그것은 게이트가 아니라 **턴이 서는** 것이다(2026-09-16 자기 대조군 t4 에서 재현).
IN=''
if [ ! -t 0 ]; then
  #   ⚠ 마지막 줄에 개행이 없으면 `read` 는 **0 이 아닌 값을 돌려주면서 데이터는 담아 준다** —
  #     그 경우를 안 받으면 개행 없는 JSON 한 줄이 통째로 버려진다(실측: 대조군 t17 이 잡았다).
  IN=$( { while IFS= read -r -t "${CLAUDE_WAVE_STDIN_TIMEOUT:-2}" _l || [ -n "$_l" ]; do printf '%s\n' "$_l"; _l=''; done; } 2>/dev/null )
fi
TR=''
if [ -n "$IN" ] && command -v jq >/dev/null 2>&1; then
  TR=$(printf '%s' "$IN" | jq -r '.transcript_path // ""' 2>/dev/null || true)
fi

command -v "$ORCA_BIN" >/dev/null 2>&1 || exit 0          # ①

WL="$("$ORCA_BIN" orchestration worker-list --json 2>/dev/null)" || exit 0
[ -n "$WL" ] || exit 0

# ④ 워커 세션이면 조용히 통과. 판별 실패는 게이트를 계속 돈다(모름을 면허로 쓰지 않는다).
if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
  printf '%s' "$WL" | ORCA_TERMINAL_HANDLE="$ORCA_TERMINAL_HANDLE" python3 -c '
import json, os, sys
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(1)
ws = (d.get("result") or {}).get("workers") or []
mine = os.environ.get("ORCA_TERMINAL_HANDLE") or ""
raise SystemExit(0 if mine and mine in {w.get("agentTerminalHandle") for w in ws} else 1)
' 2>/dev/null && exit 0
fi

# ② 세션당 상한
N=$(cat "$STAMP" 2>/dev/null || echo 0)
case "$N" in ''|*[!0-9]*) N=0 ;; esac
[ "$N" -ge "$MAX" ] && exit 0

OPEN=$(printf '%s' "$WL" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)                                   # ③ 판정 불가는 통과
ws = (d.get("result") or {}).get("workers") or []
if not ws:
    raise SystemExit(0)

runs = {}
for w in ws:
    r = w.get("runId")
    if not r:
        continue
    st = str(w.get("workerState") or ""); ds = str(w.get("dispatchStatus") or "")
    live = not (st in ("succeeded", "failed") or ds in ("completed", "failed"))
    res = w.get("resource") or {}
    # 회수 여부의 정본은 `releaseCompletedAt` 이다. 상태 이름은 런타임마다 달라진다.
    held = bool(res) and not res.get("releaseCompletedAt")
    # ⛔⛔ 다만 **코디네이터가 닫을 수 없는 자원**은 「안 한 것」이 아니다 (2026-09-16 실측).
    #   `worker-release` 는 사용자가 인수한 터미널을 구조적으로 닫지 않는다(그 명령의 Notes:
    #   "Never closes ... user-taken-over terminals"). 그때 자원은 영원히
    #   `releaseCompletedAt: null` 로 남고, 그것을 미회수로 세면 이 게이트가 **세션당 상한
    #   여덟 번을 다 쓸 때까지 막는다** — 코디네이터가 할 수 있는 일이 없는데도.
    #   실측: 워커 일곱을 회수하고 워크트리까지 지웠는데 일곱 전부
    #   `retainedReason: "user_takeover"` 로 남았고, `worker-release` 를 다시 불러도 같은
    #   사유만 돌아왔다. 워크트리는 사라졌으니 「자원이 살아 있다」도 사실이 아니다.
    #   ⇒ 그 사유는 **사람 몫**으로 빼고 세지 않는다. 대신 아래에서 한 줄로 알린다.
    #   ⚠⚠ 사유가 **셋**이다(2026-09-16 실측 — 처음엔 하나만 적어 두 사유가 계속 막았다).
    #     `worker-release --help` 의 Notes 가 못 닫는 것을 열거한다: "Never closes setup
    #     terminals, configured tabs, reused or pre-existing terminals, user-taken-over
    #     terminals, or unproven identities." 그것이 각각 external_terminal ·
    #     user_takeover · identity_unproven 으로 돌아온다. 하나만 면제하면 나머지 둘이
    #     세션당 상한 여덟 번을 소음으로 태운다 — 실측으로 run 둘이 그 상태였다.
    #   ⚠ 목록을 **넓히지 마라.** 여기 없는 사유는 코디네이터가 닫을 수 있다는 뜻이고,
    #     모르는 사유를 면제하면 게이트가 조용히 꺼진다(대조군 t15 가 그것을 잠근다).
    if held and str(res.get("retainedReason") or "") in ("user_takeover", "external_terminal", "identity_unproven"):
        held = False
        a_tk = runs.setdefault(r, {"live": 0, "held": [], "n": 0, "takeover": []})
        a_tk.setdefault("takeover", []).append(w.get("dispatchId"))
    a = runs.setdefault(r, {"live": 0, "held": [], "n": 0, "takeover": []})
    a["n"] += 1
    if live: a["live"] += 1
    if held: a["held"].append(w.get("dispatchId"))

out = []
for r, a in runs.items():
    if a["live"] == 0 and a["held"]:
        out.append("%s\t%d\t%d\t%s" % (r, len(a["held"]), a["n"], ",".join(a["held"][:6])))
print("\n".join(out))
' 2>/dev/null) || exit 0

[ -n "$OPEN" ] || { : > "$STAMP"; exit 0; }
# ⭐ 세션 스코프 — 이 세션의 도구 호출·도구 결과에 run_id 가 없으면 그 run 은 이 세션의 일이 아니다.
#   판별은 `_runs.sh` 하나가 한다(코디네이터 인박스 게이트와 같은 함수 · 2026-09-16 P0).
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_runs.sh" 2>/dev/null || true
if [ -n "$TR" ] && command -v session_seen >/dev/null 2>&1 && SEEN="$(session_seen "$TR")"; then
  MINE=''
  while IFS=$'\t' read -r run held total ids; do
    [ -n "$run" ] || continue
    if printf '%s' "$SEEN" | grep -qF -- "$run"; then
      MINE="${MINE}${run}	${held}	${total}	${ids}
"
    fi
  done <<EOF
$OPEN
EOF
  OPEN="${MINE%"
"}"
  [ -n "$OPEN" ] || exit 0          # 남의 run 뿐이다 — 스탬프는 건드리지 않는다(그쪽 세션의 셈이다)
fi

# ⭐⭐ 보류 표식이 있으면 조용히 통과한다 (2026-09-15).
#   `wave-close.sh` 가 **재 보고** 「막힌 것이 사람을 기다리는 사유 하나뿐」일 때만 남기는 파일이다.
#   코디네이터가 손으로 쓰는 것이 아니므로 빠져나가는 문이 되지 않는다.
#   ⚠ 12시간이 지나면 무시한다. 사람이 잊은 것과 기다리는 것은 다르고, 표식이 영구면 게이트가
#     통째로 꺼진다. 그리고 표식은 **그 run 에만** 유효하다.
DEFER_DIR="${TMPDIR:-/tmp}/go-fanout"
DEFER_MAX="${CLAUDE_WAVE_DEFER_HOURS:-12}"
DEFER_ALL_HELD=1
while IFS=$'\t' read -r run held total ids; do
  [ -n "$run" ] || continue
  f="$DEFER_DIR/deferred.${run}.json"
  if [ ! -f "$f" ]; then DEFER_ALL_HELD=0; break; fi
  if [ -n "$(find "$f" -mmin +$((DEFER_MAX * 60)) 2>/dev/null)" ]; then DEFER_ALL_HELD=0; break; fi
done <<EOF
$OPEN
EOF
[ "$DEFER_ALL_HELD" = "1" ] && exit 0
echo "$((N+1))" > "$STAMP" 2>/dev/null || true

{
  echo "⛔ 파도가 끝났는데 **자원을 회수하지 않은 채** 턴을 끝내려 했다."
  echo
  printf '%s\n' "$OPEN" | while IFS=$'\t' read -r run held total ids; do
    echo "  · run $run — 워커 $total 명 전원 종료, 그런데 $held 개가 살아 있다"
    echo "      $ids"
  done
  echo
  echo "마감은 한 명령이다. **재고, 막히면 멈추고, 통과하면 회수한다**:"
  echo "    bash $PLUGIN_ROOT/scripts/wave-close.sh --run <run_id> \\"
  echo "         --base <base ref> --marker <차수 날짜>"
  echo "  통과하면 --apply 를 붙여 실제로 회수한다."
  echo
  echo "⚠ 그냥 지우지 마라 — 워커 워크트리의 미커밋은 거의 항상 **리뷰 원장과 종료 보고**다."
  echo "  실측으로 그냥 정리했으면 리뷰 이력 41건과 종료 보고 569줄이 사라졌을 것이다."
  echo
  echo "(이 게이트는 세션당 ${MAX}회까지만 막는다 · 현재 $((N+1))회)"
} >&2
exit 2
