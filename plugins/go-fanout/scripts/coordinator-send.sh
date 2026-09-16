#!/usr/bin/env bash
# coordinator-send.sh — 코디네이터가 워커에게 말하는 **유일한 자리**.
#
# # 왜 있나 (2026-09-16 실측 · 인박스 695건)
#
#   · 코디네이터가 워커에게 보낸 단독 `send` 55건 중 **54건이 미읽음**(98%)
#   · 같은 기간 `reply` 는 600초 안에 보낸 57건이 **57건 다 읽혔다**
#   · 600초가 넘어서 보낸 `reply` 4건 중 1건은 미읽음
#
# 차이는 **워커가 그때 무엇을 하고 있었나**다. `reply` 는 `ask` 로 막혀 기다리는 워커에게
# 가므로 반환값으로 즉시 닿는다. 단독 `send` 는 inbox 메일이고, 워커는 자기 일이 막히지
# 않으면 `check` 를 부르지 않는다 — 그래서 98%가 도착하지 않았다.
#
# ⇒ inbox 로 보내고(기록·스레드·읽음 추적) **터미널로 깨운다**(도착). 사용자 결정 D3:
#   「inbox send + 터미널 깨우기 둘 다」.
#
# ⚠ 깨우기 문구는 **짧고 권위가 없다.** 본문을 터미널에 타이핑하지 마라 — 터미널에 넣은 글자는
#   기록도 스레드도 읽음 추적도 남기지 않고, 길면 워커의 화면을 망가뜨린다. 터미널이 하는 일은
#   「인박스를 봐라」 한 마디뿐이다.
#
# 쓰는 법:
#   coordinator-send.sh --to dispatch:<id> --subject "..." --body "..."
#   coordinator-send.sh --reply <msg_id> --body "..."
#   coordinator-send.sh --to terminal:<handle> --nudge-only        # 죽은 워커 깨우기(§819)
# 선택:
#   --no-nudge            터미널을 건드리지 않는다(inbox 만)
#   --wait-read <초>      보낸 뒤 그 초만큼 읽음 여부를 폴링해 결과를 출력에 적는다
#   --type <타입>         기본 status
#
# 종료 코드: 0 보냈다 · 2 못 보냈다(orca 없음·인자 부족·send 실패)

set -uo pipefail
ORCA_BIN="${ORCA_BIN:-orca}"
NUDGE_TEXT="${CLAUDE_FANOUT_NUDGE_TEXT:-코디네이터 메시지가 왔다. orca orchestration check --ack --json 을 불러라.}"
# ⭐ 실측 경계 — `reply` 는 이 초 안이면 ask 반환으로 닿는다(57/57). 넘으면 워커가 이미
#   빠져나와 있어 inbox 에만 쌓인다(4 중 1 미읽음) ⇒ 그때는 깨우기가 필수다.
REPLY_FRESH_SEC="${CLAUDE_FANOUT_REPLY_FRESH_SEC:-600}"

to=''; subject=''; body=''; reply_id=''; typ='status'
nudge=auto; nudge_only=0; wait_read=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)         to="${2:-}"; shift 2 ;;
    --subject)    subject="${2:-}"; shift 2 ;;
    --body)       body="${2:-}"; shift 2 ;;
    --reply)      reply_id="${2:-}"; shift 2 ;;
    --type)       typ="${2:-}"; shift 2 ;;
    --wait-read)  wait_read="${2:-0}"; shift 2 ;;
    --no-nudge)   nudge=no; shift ;;
    --nudge-only) nudge_only=1; nudge=yes; shift ;;
    -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "모르는 인자: $1" >&2; exit 2 ;;
  esac
done

command -v "$ORCA_BIN" >/dev/null 2>&1 || { echo "orca 가 없다 — 이 자리에서는 보낼 수 없다." >&2; exit 2; }
[ -n "$to$reply_id" ] || { echo "--to 나 --reply 가 필요하다." >&2; exit 2; }
[ "$nudge_only" -eq 1 ] || [ -n "$body" ] || { echo "--body 가 필요하다." >&2; exit 2; }

# ── 대상 해석 ────────────────────────────────────────────────────────────────
dispatch=''; handle=''
case "$to" in
  dispatch:*) dispatch="${to#dispatch:}" ;;
  terminal:*) handle="${to#terminal:}" ;;
esac

# `--reply` 는 원 메시지에서 상대를 알아낸다. 그 메시지의 나이가 깨우기 여부를 정한다.
reply_age=''
if [ -n "$reply_id" ]; then
  INFO=$("$ORCA_BIN" orchestration inbox --json 2>/dev/null | REPLY_ID="$reply_id" python3 -c '
import json, os, sys, datetime
try:
    ms = (json.load(sys.stdin).get("result") or {}).get("messages") or []
except Exception:
    raise SystemExit(0)
rid = os.environ.get("REPLY_ID")
for m in ms:
    if m.get("id") != rid:
        continue
    did = ""
    try:
        did = (json.loads(m.get("payload") or "{}") or {}).get("dispatchId") or ""
    except Exception:
        pass
    if not did:
        fh = str(m.get("from_handle") or "")
        did = fh[len("dispatch:"):] if fh.startswith("dispatch:") else ""
    age = ""
    try:
        ts = datetime.datetime.fromisoformat(str(m.get("created_at")).replace("Z", "+00:00"))
        age = str(int((datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()))
    except Exception:
        pass
    print("%s\t%s" % (did, age))
    break
' 2>/dev/null) || INFO=''
  dispatch=$(printf '%s' "$INFO" | cut -f1)
  reply_age=$(printf '%s' "$INFO" | cut -f2)
fi

# ── ① inbox 로 보낸다(기록·스레드·읽음 추적이 여기 남는다) ───────────────────
sent_ok=1
if [ "$nudge_only" -eq 0 ]; then
  if [ -n "$reply_id" ]; then
    "$ORCA_BIN" orchestration reply --id "$reply_id" --body "$body" --json >/dev/null 2>&1 && sent_ok=0
  else
    set -- orchestration send --to "$to" --type "$typ" --body "$body"
    [ -n "$subject" ] && set -- "$@" --subject "$subject"
    "$ORCA_BIN" "$@" --json >/dev/null 2>&1 && sent_ok=0
  fi
  [ "$sent_ok" -eq 0 ] || { echo "보내지 못했다(orca 가 거부했다)." >&2; exit 2; }
fi

# ── ② 깨울지 정한다 ──────────────────────────────────────────────────────────
# `--reply` 이고 원 질문이 신선하면 워커는 ask 반환으로 받는다(실측 57/57) — 깨우지 않는다.
# 오래됐으면 워커가 이미 빠져나와 있어 inbox 에만 쌓인다 — 깨운다.
if [ "$nudge" = auto ]; then
  if [ -n "$reply_id" ]; then
    case "$reply_age" in
      ''|*[!0-9]*) nudge=yes ;;                       # 나이를 모르면 깨운다(놓치는 쪽이 비싸다)
      *) [ "$reply_age" -gt "$REPLY_FRESH_SEC" ] && nudge=yes || nudge=no ;;
    esac
  else
    nudge=yes
  fi
fi

# ── ③ 터미널 핸들을 구한다 ───────────────────────────────────────────────────
if [ "$nudge" = yes ] && [ -z "$handle" ] && [ -n "$dispatch" ]; then
  handle=$("$ORCA_BIN" orchestration worker-show --dispatch "$dispatch" --json 2>/dev/null | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin).get("result") or {}
except Exception:
    raise SystemExit(0)
for node in (r, r.get("worker") or {}, r.get("terminal") or {}, r.get("projection") or {}):
    h = node.get("agentTerminalHandle") or node.get("handle")
    if h:
        print(h); break
' 2>/dev/null) || handle=''
fi

# ── ④ 깨운다 ────────────────────────────────────────────────────────────────
# ⚠ 핸들을 못 구해도 **보낸 것은 성공이다.** 여기서 rc 2 를 내면 「메시지는 갔는데 실패로
#   보고되는」 상태가 되고, 코디네이터가 같은 메시지를 다시 보낸다.
nudged=0
if [ "$nudge" = yes ]; then
  if [ -n "$handle" ]; then
    if "$ORCA_BIN" terminal send --terminal "$handle" --text "$NUDGE_TEXT" --enter --json >/dev/null 2>&1; then
      nudged=1
    else
      echo "⚠ 터미널을 깨우지 못했다(핸들 $handle) — inbox 에는 남아 있다." >&2
    fi
  else
    echo "⚠ 터미널 핸들을 못 구했다 — inbox 에는 남아 있다. 워커가 check 를 부를 때 도착한다." >&2
  fi
fi

# ── ⑤ 읽혔나 ────────────────────────────────────────────────────────────────
read_state='unknown'
case "$wait_read" in ''|*[!0-9]*) wait_read=0 ;; esac
if [ "$wait_read" -gt 0 ] && [ "$nudge_only" -eq 0 ]; then
  waited=0
  while [ "$waited" -lt "$wait_read" ]; do
    sleep 2; waited=$((waited+2))
    st=$("$ORCA_BIN" orchestration inbox --json 2>/dev/null | REPLY_ID="${reply_id:-}" python3 -c '
import json, os, sys
try:
    ms = (json.load(sys.stdin).get("result") or {}).get("messages") or []
except Exception:
    raise SystemExit(0)
rid = os.environ.get("REPLY_ID") or ""
for m in ms:
    if rid and m.get("thread_id") == rid and m.get("read"):
        print("read"); break
' 2>/dev/null)
    [ "$st" = read ] && { read_state=true; break; }
  done
  [ "$read_state" = unknown ] && read_state=false
fi

printf 'sent:%s nudged:%s handle:%s read:%s\n' \
  "$([ "$nudge_only" -eq 1 ] && echo skipped || echo true)" \
  "$([ "$nudged" -eq 1 ] && echo true || echo false)" \
  "${handle:-none}" "$read_state"
exit 0
