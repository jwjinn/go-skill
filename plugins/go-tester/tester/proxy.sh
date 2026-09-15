#!/usr/bin/env bash
# proxy.sh — Anthropic Messages ↔ OpenAI chat 변환 프록시를 **멱등하게** 관리한다.
#
# 왜 필요한가: Claude Code 는 `/v1/messages` 로 말하고 서빙(vLLM 등)은 `/v1/chat/completions`
#   를 받는다. 그 사이를 litellm 이 옮긴다 — 도구 정의도 `tool_use` 로 정확히 변환된다
#   (실측 2026-09-15: Anthropic tools → OpenAI tools → tool_use 왕복 성공).
#
# ⭐ uvx 로 띄운다 — **설치하지 않는다.** 이 체인은 「설치됐다」와 「돌아간다」를 가르는 것이
#   본업이고, 전역 파이썬 환경에 무언가를 남기면 그 판정이 어려워진다. 실측 기동 8초.
#
# ⚠ 키는 이 파일에도 구성에도 없다. `~/.config/go-skill/tester.env` 의 GO_TESTER_API_KEY
#   하나만 읽는다(600). 그 파일이 없으면 기동하지 않고 **그 사실을 말한다.**
#
# 사용: proxy.sh start|stop|status [--port N] [--endpoint URL] [--model NAME] [--key K]
set -u

SELF="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${TMPDIR:-/tmp}/go-tester"
mkdir -p "$STATE_DIR"

PORT=""; ENDPOINT=""; MODEL=""; MKEY=""
CMD="${1:-status}"; shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --port)     PORT="${2:-}";     shift 2 ;;
    --endpoint) ENDPOINT="${2:-}"; shift 2 ;;
    --model)    MODEL="${2:-}";    shift 2 ;;
    --key)      MKEY="${2:-}";     shift 2 ;;
    *) shift ;;
  esac
done
PORT="${PORT:-4141}"
MKEY="${MKEY:-sk-go-tester-local}"

PID_FILE="$STATE_DIR/proxy-$PORT.pid"
LOG_FILE="$STATE_DIR/proxy-$PORT.log"
CFG_FILE="$STATE_DIR/proxy-$PORT.yaml"
ENV_FILE="$HOME/.config/go-skill/tester.env"

alive() {
  # ⚠ pid 파일만 믿지 마라 — 죽은 pid 가 남아 「돌고 있다」고 거짓말한다.
  #   포트에 실제로 응답하는지가 판정이다.
  curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health/liveliness" 2>/dev/null | grep -q 200
}

case "$CMD" in
  status)
    if alive; then
      echo "proxy: 돌고 있다 (127.0.0.1:$PORT)"
      exit 0
    fi
    echo "proxy: 돌지 않는다 (127.0.0.1:$PORT)"
    exit 1
    ;;

  stop)
    if [ -f "$PID_FILE" ]; then
      p=$(cat "$PID_FILE" 2>/dev/null)
      [ -n "$p" ] && kill "$p" 2>/dev/null
      rm -f "$PID_FILE"
    fi
    # ⭐ pid 파일이 없어도 포트를 **듣고 있는** 프로세스를 거둔다(이전 실행이 비정상 종료).
    # ⛔ `-sTCP:LISTEN` 이 없으면 그 포트에 **연결한 클라이언트까지** 잡힌다(리뷰가 지목) —
    #   즉 아직 작업 중인 형제 호출의 자식 `claude` 프로세스를 죽이게 된다. 리스너만 본다.
    for p in $(lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null); do kill "$p" 2>/dev/null; done
    sleep 1
    if alive; then echo "proxy: ⚠ 아직 살아 있다 (127.0.0.1:$PORT)"; exit 1; fi
    echo "proxy: 내렸다 (127.0.0.1:$PORT)"
    rm -f "$CFG_FILE"
    exit 0
    ;;

  start)
    if alive; then echo "proxy: 이미 돌고 있다 (127.0.0.1:$PORT)"; exit 0; fi
    if [ -z "$ENDPOINT" ] || [ -z "$MODEL" ]; then
      echo "proxy: ⛔ --endpoint 와 --model 이 필요하다(구성에 비어 있다)." >&2
      exit 64
    fi
    if [ ! -f "$ENV_FILE" ]; then
      echo "proxy: ⛔ 키 파일이 없다: $ENV_FILE" >&2
      echo "  만들어라(600):  printf 'GO_TESTER_API_KEY=<키>\\n' > $ENV_FILE && chmod 600 $ENV_FILE" >&2
      exit 65
    fi
    if ! command -v uvx >/dev/null 2>&1; then
      echo "proxy: ⛔ uvx 가 없다 — 프록시를 띄울 수 없다." >&2
      echo "  설치: brew install uv   (또는 https://docs.astral.sh/uv/)" >&2
      exit 66
    fi

    # 구성 YAML 은 **생성물**이다. 키는 들어가지 않는다(os.environ 참조만).
    # `*` 와일드카드가 필요한 이유: Claude Code 가 haiku·sonnet·opus 별칭으로도 부르고,
    # 그 전부를 같은 로컬 모델로 보내야 한 모델짜리 서빙에서 끊기지 않는다.
    {
      echo "model_list:"
      echo "  - model_name: $MODEL"
      echo "    litellm_params:"
      echo "      model: openai/$MODEL"
      echo "      api_base: $ENDPOINT"
      echo "      api_key: os.environ/GO_TESTER_API_KEY"
      echo "  - model_name: \"*\""
      echo "    litellm_params:"
      echo "      model: openai/$MODEL"
      echo "      api_base: $ENDPOINT"
      echo "      api_key: os.environ/GO_TESTER_API_KEY"
      echo "litellm_settings:"
      # ⛔⛔ `drop_params: true` 를 다시 켜지 마라 (2026-09-15 실측으로 잡았다).
      #   litellm 은 그 값이 참이면 「업스트림이 안 받는다」고 판단한 파라미터를 **조용히 버린다**.
      #   그 대상에 `response_format` 이 들어가서, `tester.sh` 의 `--json-schema` 강제가
      #   업스트림에 닿지 않았다 — 자식은 스키마 없이 **산문**을 돌려주고 `tester.sh` 는
      #   rc 65 `result_not_json` 으로 닫힌다. 요청은 200 이라 **아무 신호도 없다.**
      #   ⚠ 그때 사람이 내리는 결론이 「작은 모델이라 스키마를 못 지킨다」인데 **틀렸다** —
      #     같은 게이트웨이에 `response_format: json_schema` 를 직접 보내면 정확히 지킨다(실측).
      #   ⭐ 대조군: `drop_params: false` 로 띄운 프록시에서 같은 호출이
      #     `{"passed":2,"note":"…"}` 를 돌려줬다. 켜고 끄는 것만으로 재현된다.
      #   ⚠ 끄면 업스트림이 모르는 파라미터에 400 이 날 수 있다 — 그때는 버리지 말고
      #     그 파라미터를 **이름으로** 지정해 빼라(`additional_drop_params`).
      echo "  drop_params: false"
      echo "general_settings:"
      echo "  master_key: $MKEY"
    } > "$CFG_FILE"

    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    if [ -z "${GO_TESTER_API_KEY:-}" ]; then
      echo "proxy: ⛔ $ENV_FILE 에 GO_TESTER_API_KEY 가 없다." >&2
      exit 65
    fi

    nohup uvx --from 'litellm[proxy]' litellm --config "$CFG_FILE" \
      --port "$PORT" --host 127.0.0.1 > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    # 기동 대기 — 실측 8초. 넉넉히 60초까지 본다(첫 uvx 실행은 패키지를 받는다).
    i=0
    while [ "$i" -lt 60 ]; do
      alive && { echo "proxy: 떴다 (127.0.0.1:$PORT · ${i}s · 로그 $LOG_FILE)"; exit 0; }
      sleep 1; i=$((i+1))
    done
    echo "proxy: ⛔ 60초 안에 뜨지 않았다. 로그: $LOG_FILE" >&2
    tail -5 "$LOG_FILE" >&2 2>/dev/null
    exit 67
    ;;

  *)
    echo "사용: proxy.sh start|stop|status [--port N] [--endpoint URL] [--model NAME] [--key K]" >&2
    exit 64
    ;;
esac
