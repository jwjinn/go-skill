#!/usr/bin/env bash
# coordinator-inbox-gate.sh — 코디네이터가 **인박스를 안 읽은 채** 턴을 끝내는 것을 막는다.
#
# ⚠ 2026-09-16 에 `worker-question-gate.sh` 에서 개명했다. 옛 이름은 축 하나(미답변 질문)만
#   말했고, 그 이름으로 완료 보고·에스컬레이션까지 막으면 받는 사람이 오독한다.
#
# # 왜 있나 — 실측이 셋을 말한다 (2026-09-16 · 인박스 695건)
#
#   · worker_done 40건 중 **13건 미읽음** · 34건 미소비 · run 7 중 6 에서 소비 0
#   · escalation 15건 중 **8건 미읽음**(한 run 은 7/7) · 미답변 question 2
#   · 코디→워커 단독 `send` 55건 중 54건 미읽음 — 이쪽은 게이트가 아니라 래퍼가 맡는다
#
# 원인은 규율이 아니라 절차였다. §5 의 대기 루프가 `check`(인박스 소비자) 대신 `worker-list`
# 폴링으로 되어 있었고, `worker-list` 는 **상태만 보여주고 메시지를 안 보여준다.** 워커는
# 말했고 코디네이터는 듣지 않았다. ⇒ 「집행은 규율이 아니라 구조다」.
#
# # 축 셋 — 셋 다 차단이다 (사용자 결정 D1 · 2026-09-16)
#
#   ① 미답변 question   — 워커가 답을 기다리며 **멈춰 있다**
#   ② 미읽음 worker_done — 끝난 워커의 보고를 못 봤다(자원 회수·다음 파도의 근거다)
#   ③ 미읽음 escalation  — 워커가 문제를 알렸는데 못 봤다
#
# ⚠ 「알림」이 아니라 「차단」인 이유: 미읽음 13·8 이 **조용히 넘어갔기** 때문이다. 알림이었다면
#   그 13건도 같은 자리에서 지나갔을 것이다. 무한 차단은 상한 8 이 막는다.
#
# # 해법 문구에 `inbox` 를 적지 마라
#
# `orca orchestration inbox` 는 **읽음 표시를 바꾸지 않는다.** 처음에는 인박스 695건을 세어
# 얻은 추정이었고, 2026-09-16 에 `--help` 로 확인했다 — `inbox` 는 「Show messages」일 뿐이고
# 읽음을 다루는 것은 `check` 뿐이다(`--peek`·`--all` 만 「does not mark read」라고 따로 적혀 있다).
# 해법에 `inbox` 를 적으면 코디네이터가 그것을 부르고, 미읽음은 그대로 남아 다음 턴에 또 막힌다 —
# 게이트가 「풀 수 없는 게이트」가 된다.
#
# ⭐ 소비는 **두 걸음**이다(같은 `--help` 의 Notes): 기본 `check` 가 FIFO 배치를 돌려주며 읽음으로
#   표시하고, `--ack` 가 그 배치를 닫는다. 「A bound Run replays the same Delivery until --ack」라
#   적혀 있으므로 **ack 하지 않으면 같은 배치가 계속 돌아온다.** 그래서 문구는 둘을 다 말한다.
#
# # run 스코프 — 이 세션이 관여한 run 만 (사용자 결정 D2)
#
# 판별은 `_runs.sh` 하나가 한다(완주 게이트와 같은 함수). 옛 run 의 잔여가 새 세션을 막으면
# 그 세션은 풀 방법이 없다 — 실측으로 훅을 점검하던 세션이 지난 사흘의 세 차수로 매 턴 막혔다.
# ⚠ transcript 를 못 읽으면 **좁히지 않는다**(종전대로 전부 본다). 모르는 것을 근거로 게이트를
#   좁히면 그것은 게이트를 끄는 것이다.
#
# # heartbeat 공백 축 — 알림만 (사용자 결정 D5)
#
# settled 가 아닌 워커의 마지막 heartbeat 이 30분(`CLAUDE_WORKER_HB_GAP_MIN`) 전이면 알린다.
# 차단하지 않는 이유는 **정상 공백이 있기 때문**이다 — `ask`·`check --wait` 로 막힌 워커는
# heartbeat 을 건너뛴다(Orca 계약). 실측 분포: 395 표본 · 중앙 3.7분 · p95 26분 · 30분 초과 14.
#
# # 원칙 셋 — 이 저장소의 다른 게이트와 공유한다
#
#   ① 훅 고장은 통과한다(orca 없음·런타임 없음·JSON 깨짐 → 조용히 exit 0).
#   ② 세션당 상한이 있다(CLAUDE_WORKER_Q_GATE_MAX · 기본 8) — 무한 차단을 만들지 않는다.
#   ③ 판정 불가는 **통과**다. ⚠ 다른 게이트(계획 완주)와 반대인데, 그 이유는 이 게이트가 막는
#      대상이 「내가 놓친 메시지」이지 「내가 안 한 일」이 아니기 때문이다. orca 를 안 쓰는
#      세션에서 이것이 차단하면 그 세션은 통째로 멈춘다.
#
# 산문 정본: 이 플러그인의 `skills/fanout/SKILL.md` §5(대기 루프).
#   ⚠ 그 절차를 여기 복사하지 않았다 — 이 훅은 「안 봤을 때 잡는 그물」이고 절차가 아니다.

set -uo pipefail

MAX="${CLAUDE_WORKER_Q_GATE_MAX:-8}"
# ⚠ 이름을 바꿀 수 있게 둔다. 대조군에서 「orca 가 없다」를 재려면 PATH 에서 지우는 것으로는
#   부족하다 — 시스템 orca 가 뒤에 남아 있어 **진짜 인박스를 읽는다**. 실측으로 그 검사가
#   그때그때의 파도 상태에 따라 붉었다 초록이었다 했다(2026-09-15). 다른 스크립트와도 맞춘다.
ORCA_BIN="${ORCA_BIN:-orca}"
# ⭐ 안내 문구가 **실제로 실행되는 경로**를 말해야 한다 — 심링크 설치와 마켓플레이스 설치에서
#   경로가 다르므로 고정 문자열을 적지 마라.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}"
# ⚠ 상한 카운터는 **세션 단위**다(2026-09-16 리뷰가 잡았다). 사용자 단위로 두면 세션 A 가 8회를
#   소진했을 때 같은 기계의 세션 B 에서 게이트가 조용히 꺼진다 — run 스코프를 세션별로 좁힌
#   결정(D2)과 반대 방향의 누수다. session_id 를 못 얻으면 종전 이름으로 떨어지고, 그 사실을
#   차단 문구에 남긴다.
STAMP_FALLBACK=0
STAMP="${TMPDIR:-/tmp}/coordinator-inbox-gate.$(id -u).count"
HB_GAP_MIN="${CLAUDE_WORKER_HB_GAP_MIN:-30}"

# ⚠⚠ stdin 읽기에 **시간 상한**을 둔다. `cat` 으로 받으면 stdin 이 열린 채 넘어온 호출에서 훅이
#   영영 멈추고, 그것은 게이트가 아니라 **턴이 서는** 것이다(완주 게이트가 같은 함정을 밟았다).
#   ⚠ 마지막 줄에 개행이 없으면 `read` 는 0 이 아닌 값을 돌려주면서 데이터는 담아 준다.
IN=''
if [ ! -t 0 ]; then
  IN=$( { while IFS= read -r -t "${CLAUDE_WAVE_STDIN_TIMEOUT:-2}" _l || [ -n "$_l" ]; do printf '%s\n' "$_l"; _l=''; done; } 2>/dev/null )
fi
TR=''
if [ -n "$IN" ] && command -v jq >/dev/null 2>&1; then
  TR=$(printf '%s' "$IN" | jq -r '.transcript_path // ""' 2>/dev/null || true)
fi
SESSION_ID=''
if [ -n "$IN" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$IN" | jq -r '.session_id // ""' 2>/dev/null || true)
fi
if [ -n "$SESSION_ID" ]; then
  STAMP="${TMPDIR:-/tmp}/coordinator-inbox-gate.$(id -u).${SESSION_ID}.count"
else
  STAMP_FALLBACK=1
fi

. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_runs.sh" 2>/dev/null || true
# ⛔⛔ 관여 판별의 재료는 **파일로** 넘긴다. 환경변수로 넘겼더니 긴 세션에서 `python3 -c` 호출이
#   통째로 실패했고(인자 길이 상한), 그 실패는 `|| exit 0` 을 타고 **조용한 통과**가 됐다.
#   실측(2026-09-16): 이 세션의 기록으로 돌리자 미읽음 5건이 있는데도 rc 0 이었다. 게이트가
#   꺼지는 조건이 「세션이 길어지는 것」이면 그것은 가장 필요할 때 꺼지는 게이트다.
SEEN_FILE=''
SCOPED=0
if [ -n "$TR" ] && command -v session_seen >/dev/null 2>&1; then
  SEEN_FILE="${TMPDIR:-/tmp}/coordinator-inbox-gate.seen.$$"
  # ⚠ 재료가 **비어 있으면 좁히지 않는다.** 읽기에는 성공했어도 run 흔적이 하나도 없으면
  #   「관여한 run 이 없다」가 아니라 「이 기록으로는 못 가른다」로 읽는 것이 안전한 방향이다.
  if session_seen "$TR" > "$SEEN_FILE" 2>/dev/null && [ -s "$SEEN_FILE" ]; then
    SCOPED=1
  else
    rm -f "$SEEN_FILE"; SEEN_FILE=''
  fi
fi
cleanup_seen() { [ -n "$SEEN_FILE" ] && rm -f "$SEEN_FILE"; }
trap cleanup_seen EXIT

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

# ⚠ `--limit` 을 명시한다(2026-09-16 리뷰가 잡았다). 기본 반환 건수가 인박스 전량보다 작으면
#   **오래된 미읽음**이 잘린 구간에 남아 게이트가 「막을 것 0」을 낸다. 이 게이트가 잡으려는
#   「run 7 중 6 에서 소비 0」이 정확히 그 오래된 쪽이다. 같은 레포의 다른 자리도 200 을 쓴다.
# 실측(2026-09-16): 이 기계의 인박스가 695건이고 그중 63%가 heartbeat 이다. 500 이면
#   상한에 닿아 오래된 미읽음이 잘린다 — 넉넉히 잡고, 그래도 닿으면 아래에서 말한다.
INBOX_LIMIT="${CLAUDE_INBOX_LIMIT:-2000}"
OUT=$("$ORCA_BIN" orchestration inbox --limit "$INBOX_LIMIT" --json 2>/dev/null) || exit 0
[ -n "$OUT" ] || exit 0
# ⚠ 반환이 상한에 닿았으면 전수를 못 본 것이다 — 조용히 넘기지 않는다.
N_MSG=$(printf '%s' "$OUT" | python3 -c 'import json,sys
try: print(len((json.load(sys.stdin).get("result") or {}).get("messages") or []))
except Exception: print(0)' 2>/dev/null)
case "$N_MSG" in ''|*[!0-9]*) N_MSG=0 ;; esac
[ "$N_MSG" -ge "$INBOX_LIMIT" ] && \
  echo "⚠ 인박스를 ${INBOX_LIMIT}건까지만 읽었다(상한에 닿았다) — 더 오래된 미읽음은 이 판정에 들어오지 않았다. CLAUDE_INBOX_LIMIT 을 올려라." >&2
WL=$("$ORCA_BIN" orchestration worker-list --json 2>/dev/null) || WL=''

# ⭐ 판정은 한 곳에서 한다 — 축 셋 + heartbeat 공백. 출력 형식:
#     BLOCK<TAB>축<TAB>id<TAB>from<TAB>요약
#     HB<TAB>dispatchId<TAB>경과분<TAB>핸들
WL_FILE="${TMPDIR:-/tmp}/coordinator-inbox-gate.wl.$$"
printf '%s' "$WL" > "$WL_FILE" 2>/dev/null || WL_FILE=''
cleanup_seen() { [ -n "$SEEN_FILE" ] && rm -f "$SEEN_FILE"; [ -n "$WL_FILE" ] && rm -f "$WL_FILE"; }
PENDING=$(printf '%s' "$OUT" | GATE_SEEN_FILE="$SEEN_FILE" GATE_SCOPED="$SCOPED" GATE_WL_FILE="$WL_FILE" \
          GATE_HB_GAP_MIN="$HB_GAP_MIN" GATE_TEST_NOW="${CLAUDE_GATE_NOW:-}" python3 -c '
import io, json, os, sys, datetime

try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)                                  # ③ 판정 불가는 통과
ms = (d.get("result") or {}).get("messages") or []

scoped = os.environ.get("GATE_SCOPED") == "1"
seen = ""
if scoped:
    try:
        with io.open(os.environ.get("GATE_SEEN_FILE") or "", encoding="utf-8", errors="replace") as f:
            seen = f.read()
    except Exception:
        scoped = False                                   # 재료를 못 읽으면 좁히지 않는다

# ⛔⛔ 「지금 살아 있는 워커가 있는 run」은 **transcript 와 무관하게 본다**(2026-09-16 리뷰).
#   인계를 막 받은 세션의 첫 턴에는 run_id 가 기록에 없다 — 인계문을 읽고 보고를 쓰는 것이
#   전부다. 그때 스코프가 모든 메시지를 걸러내면, 살아 있는 파도의 미읽음을 안은 채 턴이
#   끝난다. 이 게이트가 막으려는 바로 그 턴이다.
#   ⇒ 좁히는 목적은 「끝난 옛 run 의 잔여로 막지 않는 것」(D2)이므로, 아직 도는 run 은 예외다.
live_runs = set()
try:
    with io.open(os.environ.get("GATE_WL_FILE") or "", encoding="utf-8", errors="replace") as f:
        _ws = (json.loads(f.read() or "{}").get("result") or {}).get("workers") or []
    for _w in _ws:
        if str(_w.get("workerState") or "").lower() not in (
                "succeeded", "failed", "stopped", "cancelled", "canceled"):
            r = _w.get("runId")
            if r:
                live_runs.add(str(r))
except Exception:
    pass

def mine(m):
    """이 세션이 관여한 run 인가. 좁힐 수 없으면 전부 본다(게이트를 끄지 않는다)."""
    r = str(m.get("run_id") or "")
    if r and r in live_runs:
        return True                                      # 지금 도는 파도는 누구의 것이든 본다
    if not scoped:
        return True
    if not r:
        return True                                      # run 을 모르는 메시지는 좁히지 않는다
    return r in seen

def _ord(m):
    s = m.get("sequence")
    if isinstance(s, int):
        return (0, s)
    return (1, str(m.get("created_at") or ""))

# ── 축 ① 미답변 question ────────────────────────────────────────────────────
# 답변: type=status 이고 to_handle 이 dispatch: 로 시작하며 thread_id 를 가진 것.
# ⚠ 스레드가 아니라 **질문보다 나중에 온 답**만 답변으로 센다 (2026-09-15).
#   종전에는 스레드 단위였다. 같은 스레드에 질문이 두 번 오면 첫 답이 두 번째 질문까지
#   「답했다」로 만들어, 워커가 답을 기다리는데 게이트가 조용해진다.
answers = {}
for m in ms:
    if m.get("type") == "status" and str(m.get("to_handle") or "").startswith("dispatch:"):
        t = m.get("thread_id")
        if t:
            o = _ord(m)
            if t not in answers or o > answers[t]:
                answers[t] = o

def summary(m):
    q = ""
    try:
        q = (json.loads(m.get("payload") or "{}") or {}).get("question") or ""
    except Exception:
        pass
    q = q or str(m.get("subject") or "") or str(m.get("body") or "")
    return q.replace("\n", " ").replace("\t", " ")[:160]

out = []
for m in ms:
    if m.get("type") != "question" or not mine(m):
        continue
    tid = m.get("thread_id") or m.get("id")
    # ⚠ 순서를 못 재면(둘 다 sequence·created_at 부재) 답으로 센다 — `>=` 다.
    #   `>` 로 두면 시각이 없는 런타임에서 답한 질문까지 미답변으로 읽혀 늘 막힌다.
    if tid in answers and answers[tid] >= _ord(m):
        continue
    out.append(("question", m))

# ── 축 ②③ 미읽음 worker_done · escalation ───────────────────────────────────
# ⚠ `read` 를 바꾸는 것은 `check --ack` 하나다. `inbox` 로는 아무리 봐도 0 이다(실측).
for m in ms:
    t = m.get("type")
    if t not in ("worker_done", "escalation") or not mine(m):
        continue
    if m.get("read"):
        continue
    out.append((t, m))

for axis, m in out:
    print("BLOCK\t%s\t%s\t%s\t%s" % (
        axis, m.get("id"), str(m.get("from_handle") or "")[:24], summary(m)))

# ── heartbeat 공백 축(차단 아님) ─────────────────────────────────────────────
# settled 가 아닌 워커인데 마지막 heartbeat 이 오래됐다. ask·check --wait 로 막힌 워커는
# heartbeat 을 건너뛰므로(Orca 계약) 이것은 「죽었다」가 아니라 「봐라」다.
# ⛔⛔ 이 축은 **알림**이라 차단 축보다 약하다. 그런데 여기서 예외가 나면 python 이 rc≠0 으로
#   끝나고, 셸의 `|| exit 0` 이 **이미 찍은 BLOCK 줄까지 버린다** — 알림 축 하나가 차단 축 셋을
#   통째로 끄는 모양이다(2026-09-16 리뷰가 잡았다). 그래서 통째로 감싼다.
try:
  SETTLED = {"succeeded", "failed", "stopped", "cancelled", "canceled"}
  try:
      gap_min = int(os.environ.get("GATE_HB_GAP_MIN") or 30)
  except Exception:
      gap_min = 30

  def parse_ts(v):
      """타임존이 없는 값은 UTC 로 본다 — aware 와 naive 를 빼면 TypeError 가 나고,
      그 예외가 차단 축의 출력까지 버린다(2026-09-16 리뷰가 잡았다)."""
      if not v:
          return None
      try:
          t = datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00").replace(" ", "T", 1))
      except Exception:
          return None
      if t.tzinfo is None:
          t = t.replace(tzinfo=datetime.timezone.utc)
      return t

  now = parse_ts(os.environ.get("GATE_TEST_NOW")) or datetime.datetime.now(datetime.timezone.utc)

  last_hb = {}
  for m in ms:
      if m.get("type") != "heartbeat" or not mine(m):
          continue
      try:
          did = (json.loads(m.get("payload") or "{}") or {}).get("dispatchId")
      except Exception:
          did = None
      ts = parse_ts(m.get("created_at"))
      if did and ts and (did not in last_hb or ts > last_hb[did]):
          last_hb[did] = ts

  try:
      with io.open(os.environ.get("GATE_WL_FILE") or "", encoding="utf-8", errors="replace") as f:
          ws = (json.loads(f.read() or "{}").get("result") or {}).get("workers") or []
  except Exception:
      ws = []
  for w in ws:
      if str(w.get("workerState") or "").lower() in SETTLED:
          continue
      if scoped and str(w.get("runId") or "") and str(w.get("runId")) not in seen:
          continue
      did = w.get("dispatchId")
      ts = last_hb.get(did)
      if not ts:
          # ⚠ 「못 봤다」를 「괜찮다」로 읽지 마라(2026-09-16 리뷰). heartbeat 은 인박스의
          #   3분의 2 를 차지하므로 조회 창이 좁으면 **가장 조용한 워커부터** 창 밖으로 밀린다.
          #   그러면 알림이 필요한 순간에만 침묵한다. 따로 세어 말한다.
          print("HB?\t%s\t%s" % (did, w.get("agentTerminalHandle") or ""))
          continue
      mins = int((now - ts).total_seconds() // 60)
      if mins >= gap_min:
          print("HB\t%s\t%s\t%s" % (did, mins, w.get("agentTerminalHandle") or ""))
except Exception:
  pass                                                 # 알림 축의 실패가 차단 축을 끄지 않는다
' 2>/dev/null) || exit 0

BLOCKS=$(printf '%s\n' "$PENDING" | grep -c '^BLOCK	' 2>/dev/null || printf '0')
HBS=$(printf '%s\n' "$PENDING" | grep -cE '^HB\??	' 2>/dev/null || printf '0')
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=0 ;; esac
case "$HBS" in ''|*[!0-9]*) HBS=0 ;; esac

hb_lines() {
  printf '%s\n' "$PENDING" | grep '^HB	' | while IFS='	' read -r _ did mins handle; do
    echo "  · $did — 마지막 heartbeat ${mins}분 전 (터미널 $handle)"
  done
  printf '%s\n' "$PENDING" | grep '^HB?	' | while IFS='	' read -r _ did handle; do
    echo "  · $did — heartbeat 을 조회 창 안에서 **못 봤다**(죽었는지 조용한지 모른다 · 터미널 $handle)"
  done
}

if [ "$BLOCKS" -eq 0 ]; then
  : > "$STAMP"                                           # 막을 것이 없다 → 카운터 리셋
  # ⭐ heartbeat 공백만 있으면 **알림**이다(차단 아님 · 사용자 결정 D5).
  if [ "$HBS" -gt 0 ]; then
    {
      echo "⏱ ${HB_GAP_MIN}분 넘게 조용한 워커가 ${HBS}명이다(차단이 아니라 알림):"
      hb_lines
      echo
      echo "확인: orca orchestration worker-show --dispatch <id> --json"
      echo "⚠ ask·check --wait 로 막힌 워커는 heartbeat 을 건너뛴다 — 죽은 것과 기다리는 것은 다르다."
    } >&2
  fi
  exit 0
fi

echo "$((N+1))" > "$STAMP" 2>/dev/null || true

axis_block() { # <축> <제목> <해법>
  n=$(printf '%s\n' "$PENDING" | grep -c "^BLOCK	$1	" 2>/dev/null || printf '0')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ] || return 0
  echo "  【$2 · ${n}건】"
  printf '%s\n' "$PENDING" | grep "^BLOCK	$1	" | while IFS='	' read -r _ _ id from body; do
    echo "    · $id  (from ${from}…)"
    [ -n "$body" ] && echo "        $body"
  done
  echo "    → $3"
  echo
}

{
  echo "⛔ 인박스에 코디네이터가 처리하지 않은 메시지가 ${BLOCKS}건 있는데 턴을 끝내려 했다."
  echo
  axis_block question   "워커가 답을 기다린다(멈춰 있다)" \
    "bash $PLUGIN_ROOT/scripts/coordinator-send.sh --reply <msg_id> --body \"<답>\""
  axis_block worker_done "끝난 워커의 완료 보고를 안 읽었다" \
    "orca orchestration check --json 으로 받아 전부 처리한 뒤 --ack 를 붙여 배치를 닫아라(ack 전에는 같은 배치가 반복된다). 그 다음 자원 회수(release)나 재사용을 정해라"
  axis_block escalation  "워커가 문제를 알렸는데 안 읽었다" \
    "orca orchestration check --json 으로 읽고 조치한 뒤 --ack 로 닫아라"
  echo "⚠ 읽음 표시를 바꾸는 것은 check 다(--peek·--all 은 바꾸지 않는다). inbox 는 몇 번을 봐도 read 가 0 이다."
  if [ "$HBS" -gt 0 ]; then
    echo
    echo "⏱ 덧붙여, ${HB_GAP_MIN}분 넘게 조용한 워커가 ${HBS}명이다:"
    hb_lines
  fi
  echo
  if [ "$STAMP_FALLBACK" = "1" ]; then
    echo "(이 게이트는 ${MAX}회까지만 막는다 · 현재 $((N+1))회 — ⚠ session_id 를 못 받아 **이 기계의 모든 세션이 그 예산을 나눠 쓴다**)"
  else
    echo "(이 게이트는 세션당 ${MAX}회까지만 막는다 · 현재 $((N+1))회)"
  fi
} >&2
exit 2
