#!/usr/bin/env bash
# eval.sh — 리뷰어 회귀 평가. **정답을 아는 diff** 로 리뷰어를 채점한다.
#
# ⭐ 왜 필요한가: `verdict.sh` 는 **정밀도**(올린 것 중 진짜가 몇 건)만 준다.
#   반대쪽 — **있었는데 놓친 것이 몇 건**(재현율) — 은 답을 미리 아는 코드가 있어야만 잰다.
#   그리고 그것이 있어야 「프롬프트를 고쳤더니 좋아졌다」가 의견이 아니라 숫자가 된다.
#
# ⚠ 이것은 `go test` 가 아니다. 리뷰어는 **확률적**이라 같은 입력에 다른 답을 낸다 —
#   통과/실패가 아니라 **비율**을 보고 **이전 기준선과 비교**하라(그래서 test 가 아니라 eval 이다).
#
# 사용:
#   eval.sh list    [케이스]                     케이스 목록
#   eval.sh show    <id> [케이스]                한 케이스를 정답까지 펼쳐 본다(사람용)
#   eval.sh prepare [케이스] [출력]              리뷰어에게 줄 프롬프트로 펼친다
#   eval.sh codex   [케이스] [출력]              codex 로 자동 실행(셸에서 되는 유일한 리뷰어)
#   eval.sh score   [케이스] <결과> [이름]       채점
#
# ⚠ Claude 리뷰어(blind·contract)는 셸에서 못 부른다 — 서브에이전트는 모델이 부른다.
#   그래서 `prepare` → (모델이 각 프롬프트로 리뷰어 실행 → <id>.json 저장) → `score` 다.
set -euo pipefail

SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
CASES_DEFAULT="$SELF/cases/universal.jsonl"
CMD="${1:-help}"; shift || true

case "$CMD" in
  list)
    CASES="${1:-$CASES_DEFAULT}"
    python3 - "$CASES" <<'PY'
# -*- coding: utf-8 -*-
import io, json, sys
d = {}
n = 0
for line in io.open(sys.argv[1], encoding="utf-8"):
    if not line.strip():
        continue
    c = json.loads(line)
    n += 1
    mark = "결함" if c.get("defect") else "⭐대조군"
    print("  %-30s %-6s %-5s %s" % (c["id"], mark, c.get("lang"), c.get("class")))
    d[c.get("class")] = d.get(c.get("class"), 0) + 1
print()
print("총 %d건 · 부류 %d종" % (n, len(d)))
PY
    ;;

  show)
    ID="${1:?케이스 id 를 줘라}"; CASES="${2:-$CASES_DEFAULT}"
    python3 - "$CASES" "$ID" <<'PY'
# -*- coding: utf-8 -*-
import io, json, sys
for line in io.open(sys.argv[1], encoding="utf-8"):
    if not line.strip():
        continue
    c = json.loads(line)
    if c["id"] != sys.argv[2]:
        continue
    print("id     %s" % c["id"])
    print("부류   %s (%s)" % (c.get("class"), c.get("lang")))
    print("종류   %s" % ("결함" if c.get("defect") else "⭐ 대조군 — 정답은 「보고하지 않는 것」"))
    print("출처   %s" % c.get("origin", "—"))
    if c.get("why"):
        print("\n왜\n  %s" % c["why"].replace("\n", "\n  "))
    if c.get("briefing"):
        print("\n브리핑(리뷰어에게 준다)\n  %s" % c["briefing"].replace("\n", "\n  "))
    if c.get("false_claim"):
        print("\n⚠ 거짓 주장: %s" % c["false_claim"])
    if c.get("expect"):
        print("\n정답  %s" % json.dumps(c["expect"], ensure_ascii=False))
    print("\ndiff\n" + c["diff"])
    sys.exit(0)
sys.stderr.write("그런 케이스가 없다: %s\n" % sys.argv[2])
sys.exit(1)
PY
    ;;

  prepare)
    # prepare <케이스> <출력> [역할]  — 역할이 받는 것이 다르다(blind 는 브리핑을 못 본다)
    CASES="${1:-$CASES_DEFAULT}"
    OUT="${2:-$SELF/runs/$(date +%Y%m%d-%H%M%S)}"
    python3 "$SELF/_prepare.py" "$CASES" "$OUT" "$SELF/../finding-schema.json" "${3:-contract}"
    ;;

  claude)
    # claude <케이스> <출력> [--endpoint <url> --model <id>] [--role <자리>]
    #
    # ⭐ **로컬 모델과 상용 모델(opus 등)을 같은 코드로 부른다.** `--endpoint` 를 주면
    #   go-tester 의 프록시를 띄우고 `ANTHROPIC_BASE_URL` 을 걸며, 안 주면 기본 엔드포인트로
    #   간다. 한 서브커맨드로 둘을 재야 **조건이 같아져 비교가 정직해진다.**
    #
    # ⚠ 이 파일 머리말의 「Claude 리뷰어는 셸에서 못 부른다」는 **서브에이전트를 전제한
    #   문장**이다. `claude -p` 경로는 그 전제 밖이고 go-tester 가 이미 그렇게 부른다.
    #
    # ⚠⚠ 실패한 케이스는 **산출 JSON 을 남기지 않는다** — 그러면 채점기가 그것을
    #   「놓침」이 아니라 **「미측정」**으로 센다(`_score.py`). 둘을 섞으면 도달 실패가
    #   재현율 하락으로 보고돼 모델을 억울하게 깎는다.
    CASES="${1:-$CASES_DEFAULT}"; shift || true
    OUT="${1:-$SELF/runs/claude-$(date +%Y%m%d-%H%M%S)}"; shift || true
    EP=""; MODEL=""; ROLE="blind"
    while [ $# -gt 0 ]; do
      case "$1" in
        --endpoint) EP="${2:-}"; shift 2 ;;
        --model)    MODEL="${2:-}"; shift 2 ;;
        --role)     ROLE="${2:-blind}"; shift 2 ;;
        *) echo "모르는 인자: $1" >&2; exit 2 ;;
      esac
    done
    command -v claude >/dev/null 2>&1 || { echo "claude 가 없다 — 이 리뷰어는 건너뛴다." >&2; exit 2; }
    # ⚠ 케이스가 0건이면 **판정 2**(검사 불가)다. 0건을 0% 로 보고하면 「쟀는데 못 찾았다」가
    #   되는데 실제로는 **재지 않은 것**이다.
    NCASES=$(grep -c '[^[:space:]]' "$CASES" 2>/dev/null || echo 0)
    [ "$NCASES" -gt 0 ] || { echo "케이스가 0건이다 — 검사 불가(판정 2)" >&2; exit 2; }

    python3 "$SELF/_prepare.py" "$CASES" "$OUT" "$SELF/../finding-schema.json" "$ROLE" >/dev/null
    SCHEMA_JSON="$(cat "$SELF/../finding-schema.json")"

    PROXY_STARTED=0
    if [ -n "$EP" ]; then
      # go-tester 의 프록시를 **그대로 쓴다** — 두 벌로 만들지 않는다(정본이 둘이면 어긋난다).
      GT=$(bash "$SELF/../../hooks/_plugins.sh" go-tester tester/_config.py 2>/dev/null) || GT=""
      if [ -n "$GT" ] && [ -f "$GT/tester/proxy.sh" ]; then
        PORT="${EVAL_PROXY_PORT:-4142}"; KEY="${EVAL_PROXY_KEY:-sk-eval-local}"
        if bash "$GT/tester/proxy.sh" start --port "$PORT" --endpoint "$EP" \
             --model "${MODEL:-local}" --key "$KEY" >/dev/null 2>&1; then
          PROXY_STARTED=1
          export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
          export ANTHROPIC_AUTH_TOKEN="$KEY"
          export ANTHROPIC_API_KEY=""
        fi
      fi
      # ⭐ 프록시를 못 띄워도 **env 는 세운다** — 그래야 「엔드포인트를 줬는데 기본으로 갔다」가
      #   조용히 일어나지 않는다. 호출은 실패하고 그 케이스는 미측정으로 남는다.
      [ "$PROXY_STARTED" = "1" ] || { export ANTHROPIC_BASE_URL="$EP"; export ANTHROPIC_AUTH_TOKEN="${EVAL_PROXY_KEY:-sk-eval-local}"; }
    fi

    n=0; ok=0
    for p in "$OUT"/*.prompt.txt; do
      [ -f "$p" ] || continue
      id=$(basename "$p" .prompt.txt); n=$((n+1))
      printf '  %-30s ' "$id"
      RAW="$OUT/$id.raw"
      # ⚠ `< /dev/null` 필수 — 없으면 stdin 을 기다리며 멈춘다.
      # ⚠⚠ `--json-schema` 는 **파일 경로가 아니라 JSON 문자열**을 받는다(실측 2026-09-17:
      #    경로를 주면 `Unrecognized token '/'` 로 39/39 가 전부 실패했다). 내용을 읽어 넘긴다.
      if claude -p "$(cat "$p")" ${MODEL:+--model "$MODEL"} \
           --output-format json --json-schema "$SCHEMA_JSON" \
           < /dev/null > "$RAW" 2> "$OUT/$id.err"; then
        # 스키마를 만족하는 JSON 일 때만 `<id>.json` 으로 승격한다.
        if python3 - "$RAW" "$OUT/$id.json" <<'PY'
import io, json, sys
raw, out = sys.argv[1], sys.argv[2]
try:
    d = json.load(io.open(raw, encoding="utf-8"))
except Exception:
    raise SystemExit(1)
# claude --output-format json 은 결과를 감싸기도 한다 — findings 를 찾아 펴 준다.
if isinstance(d, dict) and "findings" not in d:
    for k in ("result", "content", "output"):
        v = d.get(k)
        if isinstance(v, dict) and "findings" in v:
            d = v
            break
        if isinstance(v, str):
            try:
                v2 = json.loads(v)
            except Exception:
                continue
            if isinstance(v2, dict) and "findings" in v2:
                d = v2
                break
if not isinstance(d, dict) or "findings" not in d:
    raise SystemExit(1)
json.dump(d, io.open(out, "w", encoding="utf-8"), ensure_ascii=False)
PY
        then ok=$((ok+1)); echo "ok"
        else rm -f "$OUT/$id.json"; echo "스키마 위반(미측정)"; fi
      else
        rm -f "$OUT/$id.json"; echo "실패(미측정 · 로그: $OUT/$id.err)"
      fi
      rm -f "$RAW"
    done

    [ "$PROXY_STARTED" = "1" ] && bash "$GT/tester/proxy.sh" stop --port "$PORT" >/dev/null 2>&1
    echo
    echo "실행 $ok/$n   (실패는 **미측정**이지 놓침이 아니다)"
    echo "채점: bash $0 score $CASES $OUT ${MODEL:-claude}"
    ;;

  codex)
    CASES="${1:-$CASES_DEFAULT}"
    OUT="${2:-$SELF/runs/codex-$(date +%Y%m%d-%H%M%S)}"
    command -v codex >/dev/null 2>&1 || { echo "codex 가 없다 — 이 리뷰어는 건너뛴다." >&2; exit 3; }
    python3 "$SELF/_prepare.py" "$CASES" "$OUT" "$SELF/../finding-schema.json" >/dev/null
    n=0; ok=0
    for p in "$OUT"/*.prompt.txt; do
      id=$(basename "$p" .prompt.txt); n=$((n+1))
      printf '  %-30s ' "$id"
      # ⚠ `< /dev/null` 필수 — 없으면 stdin 을 기다리며 영원히 멈춘다.
      # ⚠ sandbox 는 인자로 못박는다(--full-auto 는 read-only 를 덮어쓴다).
      if codex exec -c sandbox_mode="read-only" \
           --output-schema "$SELF/../finding-schema.json" \
           -o "$OUT/$id.json" "$(cat "$p")" < /dev/null > "$OUT/$id.err" 2>&1; then
        ok=$((ok+1)); echo "ok"
      else
        echo "실패(로그: $OUT/$id.err)"
      fi
    done
    echo
    echo "실행 $ok/$n"
    # ⚠ 실패는 「놓침」이 아니라 「미측정」이다 — 채점기가 그것을 구분한다.
    echo "채점: bash $0 score $CASES $OUT codex"
    ;;

  score)
    # score <케이스> <결과> [리뷰어이름] [--record ["메모"]]
    CASES="${1:-$CASES_DEFAULT}"
    RES="${2:?결과 디렉토리를 줘라}"
    WHO="${3:-reviewer}"
    if [ "${4:-}" = "--record" ]; then
      ROOT=$(git rev-parse --show-toplevel 2>/dev/null || printf '.')
      HIST="${CLAUDE_REVIEW_HISTORY_DIR:-$ROOT/docs/리뷰-이력}"
      mkdir -p "$HIST"
      python3 "$SELF/_score.py" "$CASES" "$RES" "$WHO" "$HIST/eval.jsonl" "${5:-}"
    else
      python3 "$SELF/_score.py" "$CASES" "$RES" "$WHO"
    fi
    ;;

  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
