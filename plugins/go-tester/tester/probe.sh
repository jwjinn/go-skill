#!/usr/bin/env bash
# probe.sh — heartbeat. 「이 기계에서 로컬 모델이 **실제로 도는가**」를 한 번 불러서 판정한다.
#
# ⛔⛔ 왜 `command -v` 가 아닌가 (실측으로 배운 것):
#   go-review 의 codex 폴백은 `shutil.which("codex")` 하나만 봤다. 그래서 codex 가 **설치돼
#   있는데 못 도는** 조건(기본 모델이 CLI 업그레이드를 요구 · 계정이 그 모델을 미지원)에서
#   전 자리를 codex 로 둔 채 진행했고, 결과는 **리뷰 0회**였다. 아무 신호도 없었다.
#   ⇒ 존재는 가용성이 아니다. 한 번 불러 봐야 안다.
#
# 사용:
#   probe.sh [--endpoint URL] [--model NAME] [--port N] [--timeout S] [--for-plan]
#     기본     : JSON 한 줄 {available, reason, latency_ms}
#     --for-plan: 계획 초안의 「결정 필요」 절에 붙일 **한 줄 텍스트**
#
# ⚠ 이 스크립트는 프록시를 **필요하면 띄우고, 자기가 띄웠으면 내린다.**
#   옵트인 전에는 프록시가 상주하지 않는다 — 「기본은 안 씀」이 프로세스 수준에서도 참이어야 한다.
set -u

SELF="$(cd "$(dirname "$0")" && pwd)"
ENDPOINT=""; MODEL=""; PORT=""; TMO=""; FOR_PLAN=0; MKEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint) ENDPOINT="${2:-}"; shift 2 ;;
    --model)    MODEL="${2:-}";    shift 2 ;;
    --port)     PORT="${2:-}";     shift 2 ;;
    --key)      MKEY="${2:-}";     shift 2 ;;
    --timeout)  TMO="${2:-}";      shift 2 ;;
    --for-plan) FOR_PLAN=1;        shift ;;
    *) shift ;;
  esac
done

# 인자가 없으면 구성에서 읽는다.
if [ -z "$ENDPOINT" ] || [ -z "$MODEL" ]; then
  eval "$(python3 "$SELF/_config.py" 2>/dev/null | grep -E '^TESTER_(ENDPOINT|MODEL|PROXY_PORT|PROXY_KEY|PROBE_TIMEOUT)=' | sed 's/^/export /')" 2>/dev/null || true
  ENDPOINT="${ENDPOINT:-${TESTER_ENDPOINT:-}}"
  MODEL="${MODEL:-${TESTER_MODEL:-}}"
  PORT="${PORT:-${TESTER_PROXY_PORT:-4141}}"
  MKEY="${MKEY:-${TESTER_PROXY_KEY:-sk-go-tester-local}}"
  TMO="${TMO:-${TESTER_PROBE_TIMEOUT:-15}}"
fi
PORT="${PORT:-4141}"; MKEY="${MKEY:-sk-go-tester-local}"; TMO="${TMO:-15}"

emit() { # emit <available> <reason> <latency_ms>
  if [ "$FOR_PLAN" = "1" ]; then
    if [ "$1" = "true" ]; then
      printf 'heartbeat: OK %sms (%s @ %s)\n' "$3" "$MODEL" "$ENDPOINT"
    else
      printf 'heartbeat: 불가 — %s\n' "$2"
    fi
  else
    python3 -c 'import json,sys;print(json.dumps({"available":sys.argv[1]=="true","reason":sys.argv[2],"latency_ms":int(sys.argv[3]),"model":sys.argv[4],"endpoint":sys.argv[5]},ensure_ascii=False))' \
      "$1" "$2" "$3" "$MODEL" "$ENDPOINT"
  fi
}

if [ -z "$ENDPOINT" ] || [ -z "$MODEL" ]; then
  emit false "구성에 endpoint·model 이 없다(.claude/tester/config.json 에 적어라)" 0
  exit 1
fi

# ── 프록시 확보 ───────────────────────────────────────────────────────────────
started_here=0
if ! bash "$SELF/proxy.sh" status --port "$PORT" >/dev/null 2>&1; then
  if ! out=$(bash "$SELF/proxy.sh" start --port "$PORT" --endpoint "$ENDPOINT" --model "$MODEL" --key "$MKEY" 2>&1); then
    # ⚠ 프록시 기동 실패를 「모델이 죽었다」로 말하지 마라 — 원인이 다르고 고칠 곳도 다르다.
    emit false "프록시 기동 실패: $(printf '%s' "$out" | tail -1)" 0
    exit 1
  fi
  started_here=1
fi

cleanup() { [ "$started_here" = "1" ] && bash "$SELF/proxy.sh" stop --port "$PORT" >/dev/null 2>&1; }

# ── 실호출 1회 ────────────────────────────────────────────────────────────────
t0=$(python3 -c 'import time;print(int(time.time()*1000))')
body='{"model":"'"$MODEL"'","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
http=$(curl -s -m "$TMO" -o "${TMPDIR:-/tmp}/go-tester-probe.$$" -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/v1/messages" \
  -H "x-api-key: $MKEY" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
  -d "$body" 2>/dev/null)
t1=$(python3 -c 'import time;print(int(time.time()*1000))')
ms=$((t1 - t0))
resp=$(cat "${TMPDIR:-/tmp}/go-tester-probe.$$" 2>/dev/null); rm -f "${TMPDIR:-/tmp}/go-tester-probe.$$"
cleanup

if [ "$http" = "200" ]; then
  # ⚠ 200 이어도 본문이 오류일 수 있다 — 형태를 확인한다(탐지기를 먼저 의심하라).
  if printf '%s' "$resp" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get("type")=="message" else 1)' 2>/dev/null; then
    emit true "ok" "$ms"; exit 0
  fi
  emit false "200 인데 응답이 message 가 아니다: $(printf '%s' "$resp" | head -c 120)" "$ms"
  exit 1
fi
emit false "HTTP $http — $(printf '%s' "$resp" | head -c 160)" "$ms"
exit 1
