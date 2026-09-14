#!/usr/bin/env bash
# tester.sh — 테스트 에이전트의 **유일한 입구**. 로컬 모델에 붙은 별도 `claude` 프로세스를
#             띄우고, 그 산출을 검증해 JSON 하나로 돌려준다.
#
# ⭐ 왜 래퍼인가 (go-review 의 `codex-ro.sh` 와 같은 이유):
#   통제를 호출자가 플래그로 조립하게 두면, 플래그 하나를 빠뜨린 날 통제가 사라지고
#   **아무 신호도 없다.** 그래서 환경변수 9종·도구 제한·게이트 우회·세마포어·산출 검증을
#   전부 여기 둔다. 호출자는 「무엇을 시킬지」만 정한다.
#
# ⛔⛔ 실측으로 얻은 통제 셋 (2026-09-15 · 전부 재현했다):
#   ① `--setting-sources ""` 를 빼면 **부모의 go-review Stop 훅이 자식에 걸린다.**
#      debug 로그로 셌다: `""` → go-review 훅 0건 / `user` → 3건 로드되고 Stop 발화.
#   ② 그렇게 걸리면 자식은 **부모의 계획 파일을 편집해서 빠져나간다.** 재현 1/1 —
#      Read·Edit·Write 로 미완료 체크박스 2개를 지웠다. 부모는 그 사실을 모른다.
#   ③ `--allowedTools ""` 는 `bypassPermissions` 에서 **도구를 막지 못한다.** 막는 것은
#      `--tools` 다. ②가 일어난 조건이 정확히 이것이었다.
#   ⇒ 세 통제가 다 여기 있고, 그 위에 **부모 계획·리뷰 파일 해시 대조**를 한 겹 더 둔다.
#      통제가 하나라도 조용히 깨졌을 때 그것을 알아차릴 유일한 방법이기 때문이다.
#
# 사용:
#   tester.sh --task <지시서 파일> [--mode run|write|full] [--cwd <레포>] [--out <산출.json>]
#             [--gate '<게이트 명령>'] [--label <라벨>]
#
# 종료코드:
#   0   정상 — 스키마를 통과한 JSON 을 냈다
#   64  사용법 오류
#   65  산출이 무효(JSON 이 아니거나 필수 필드 누락)
#   66  테스트 파일 밖을 고쳤다
#   67  대조군 누락(mode=full 인데 발화한 대조군이 0건)
#   68  부모 계획·리뷰 파일이 훼손됐다(원본을 복원했다)
#   70  쓸 수 없다 — 꺼졌거나·옵트인 없음·heartbeat 불가·슬롯 대기 초과
set -u

SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/_sem.sh"

TASK=""; MODE="full"; CWD=""; OUT=""; GATE=""; LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --task)  TASK="${2:-}";  shift 2 ;;
    --mode)  MODE="${2:-}";  shift 2 ;;
    --cwd)   CWD="${2:-}";   shift 2 ;;
    --out)   OUT="${2:-}";   shift 2 ;;
    --gate)  GATE="${2:-}";  shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    *) echo "tester.sh: 모르는 옵션 '$1'" >&2; exit 64 ;;
  esac
done

case "$MODE" in run|write|full) : ;; *) echo "tester.sh: --mode 는 run|write|full 이다('$MODE')" >&2; exit 64 ;; esac

CWD="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
LABEL="${LABEL:-$(date +%Y%m%d-%H%M%S)-$$}"
OUT="${OUT:-${TMPDIR:-/tmp}/go-tester/result-$LABEL.json}"
mkdir -p "$(dirname "$OUT")"

fail_json() { # fail_json <rc> <사유>
  KEEP_GUARD=1
  python3 -c 'import json,sys;print(json.dumps({"mode":sys.argv[1],"commands":[],"passed":0,"failed":0,"skipped":0,"failures":[],"tests_written":[],"control_group":[],"files_changed":[],"notes":"","unavailable_reason":sys.argv[2]},ensure_ascii=False))' \
    "$MODE" "$2" > "$OUT"
  cat "$OUT"
  exit "$1"
}

[ -n "$TASK" ] && [ -f "$TASK" ] || { echo "tester.sh: --task <지시서 파일> 이 필요하다." >&2; exit 64; }

# ── ① 켤 수 있나 ─────────────────────────────────────────────────────────────
CFG_OUT="$(CLAUDE_PROJECT_DIR="$CWD" python3 "$SELF/_config.py" 2>/dev/null)"
eval "$(printf '%s' "$CFG_OUT" | grep -E '^TESTER_[A-Z_]+=' | sed 's/^/export /')"

if [ "${TESTER_ENABLED:-0}" != "1" ]; then
  # ⭐ 여기가 fail-closed 지점이다. 묻지 않았거나·답이 「쓴다」가 아니거나·구성이 off 면
  #   **프록시조차 띄우지 않고** 멈춘다. 「기본은 안 씀」이 프로세스 수준에서도 참이어야 한다.
  fail_json 70 "${TESTER_REASON:-unavailable}"
fi

# ── ② heartbeat — 존재가 아니라 가용성 ───────────────────────────────────────
PROBE="$(bash "$SELF/probe.sh" --endpoint "$TESTER_ENDPOINT" --model "$TESTER_MODEL" \
          --port "$TESTER_PROXY_PORT" --key "$TESTER_PROXY_KEY" --timeout "$TESTER_PROBE_TIMEOUT" 2>/dev/null)"
if ! printf '%s' "$PROBE" | python3 -c 'import json,sys;sys.exit(0 if json.load(sys.stdin).get("available") else 1)' 2>/dev/null; then
  reason="$(printf '%s' "$PROBE" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("reason",""))
except Exception: print("probe 산출을 읽지 못했다")' 2>/dev/null)"
  fail_json 70 "heartbeat_failed: $reason"
fi

# probe 가 프록시를 내렸다 — 본 실행을 위해 다시 띄우고, 우리가 띄웠으면 끝에 내린다.
PROXY_MINE=0
if ! bash "$SELF/proxy.sh" status --port "$TESTER_PROXY_PORT" >/dev/null 2>&1; then
  if ! bash "$SELF/proxy.sh" start --port "$TESTER_PROXY_PORT" --endpoint "$TESTER_ENDPOINT" \
         --model "$TESTER_MODEL" --key "$TESTER_PROXY_KEY" >/dev/null 2>&1; then
    fail_json 70 "proxy_start_failed(heartbeat 는 통과했는데 본 실행용 기동에 실패했다)"
  fi
  PROXY_MINE=1
fi

# ── ③ 부모 계획·리뷰 파일의 지문 ─────────────────────────────────────────────
# 실측 ②의 방어. 자식이 게이트를 빠져나가려 이 파일들을 고치면 여기서 잡는다.
PLAN_F="${CLAUDE_PLAN_FILE:-$CWD/.claude/plan-active.md}"
REVIEW_F="${CLAUDE_REVIEW_FILE:-$CWD/.claude/review-active.md}"
GUARD_DIR="${TMPDIR:-/tmp}/go-tester/guard-$LABEL"
mkdir -p "$GUARD_DIR"
snap() { # snap <파일> <이름>
  [ -f "$1" ] || return 0
  cp "$1" "$GUARD_DIR/$2.bak"
  shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 > "$GUARD_DIR/$2.sha"
}
changed() { # changed <파일> <이름> → 0=바뀌었다
  [ -f "$GUARD_DIR/$2.sha" ] || return 1
  [ -f "$1" ] || return 0
  [ "$(shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1)" != "$(cat "$GUARD_DIR/$2.sha")" ]
}
snap "$PLAN_F" plan
snap "$REVIEW_F" review

# ── ④ 변경 전 스냅샷 ─────────────────────────────────────────────────────────
# ⛔ 여기가 fail-open 이 되기 쉬운 자리다. 첫 판은 git 레포가 아니면 빈 목록을 만들었고,
#   그러면 「변경 없음」이 되어 **쓰기 범위 검사가 무조건 통과**했다. 검사하지 않은 것과
#   통과한 것은 다르다 — 이 체인이 반복해서 잡는 부류라 스스로 밟을 수는 없다.
#   ⇒ git 이 아니면 파일 경로·크기·mtime 으로 직접 스냅샷을 뜬다. 파일이 너무 많으면
#     그 사실을 `SCOPE_METHOD=none` 으로 남겨 「미검사」가 「통과」로 읽히지 않게 한다.
IS_GIT=0
git -C "$CWD" rev-parse --show-toplevel >/dev/null 2>&1 && IS_GIT=1
BEFORE="$GUARD_DIR/before.txt"
AFTER="$GUARD_DIR/after.txt"
SCOPE_METHOD="git"
FILE_CAP=20000

snapshot() { # snapshot <산출 파일>
  if [ "$IS_GIT" = "1" ]; then
    git -C "$CWD" -c core.quotePath=false status --porcelain 2>/dev/null \
      | sed 's/^...//' | sed 's/^"//; s/"$//' | sort > "$1"
    return 0
  fi
  n=$(find "$CWD" -type f -not -path '*/.git/*' 2>/dev/null | head -n $((FILE_CAP + 1)) | wc -l | tr -d ' ')
  if [ "$n" -gt "$FILE_CAP" ]; then
    SCOPE_METHOD="none"
    printf '__TOO_MANY_FILES__\n' > "$1"
    return 0
  fi
  SCOPE_METHOD="fs"
  ( cd "$CWD" && { find . -type f -not -path './.git/*' -exec stat -f '%N %z %m' {} + 2>/dev/null \
      || find . -type f -not -path './.git/*' -exec stat -c '%n %s %Y' {} + 2>/dev/null ; } ) | sort > "$1"
}
snapshot "$BEFORE"

# ── ⑤ 슬롯 ──────────────────────────────────────────────────────────────────
if ! sem_acquire "${TESTER_MAX_CONCURRENCY:-4}" 900; then
  [ "$PROXY_MINE" = "1" ] && bash "$SELF/proxy.sh" stop --port "$TESTER_PROXY_PORT" >/dev/null 2>&1
  fail_json 70 "semaphore_timeout(동시 상한 ${TESTER_MAX_CONCURRENCY:-4} 에서 900초 대기 후 포기)"
fi
# ⚠ 실패했을 때 자식의 원본 산출을 지우면 **원인을 영영 못 본다.** 첫 판이 그랬고,
#   「자식이 JSON 을 안 냈다」까지만 알고 무엇을 냈는지는 알 수 없었다. 성공이면 치우고
#   실패면 남긴다 — 남긴 경로는 사유에 적어 사람이 바로 열 수 있게 한다.
KEEP_GUARD=0
release_all() {
  sem_release
  [ "${PROXY_MINE:-0}" = "1" ] && bash "$SELF/proxy.sh" stop --port "${TESTER_PROXY_PORT:-4141}" >/dev/null 2>&1
  [ "${KEEP_GUARD:-0}" = "1" ] || rm -rf "$GUARD_DIR" 2>/dev/null
}
trap 'release_all' EXIT INT TERM

# ── ⑥ 자식 실행 ─────────────────────────────────────────────────────────────
SCHEMA="$(cat "$SELF/result-schema.json")"   # ⚠ --json-schema 는 **경로가 아니라 JSON 문자열**이다(실측)
PROMPT="$(cat "$TASK")"
if [ -n "$GATE" ]; then
  PROMPT="$PROMPT

GATE COMMAND (run exactly this to check the tests):
  $GATE"
fi
PROMPT="$PROMPT

MODE: $MODE
TEST FILE PATTERNS you may create or edit (anything else is rejected by the caller):
  $(printf '%s' "${TESTER_TEST_PATTERNS:-}" | tr '|' ' ')

OUTPUT CONTRACT (the caller parses this and rejects anything else)
Your final message must be ONE JSON object and nothing else - no prose before or after,
no markdown fence. Required keys:
  mode, commands, passed, failed, skipped, failures, tests_written,
  control_group, files_changed, notes, unavailable_reason
Set mode to \"$MODE\". Every entry in control_group needs test, mutation and went_red,
and went_red is true only for a failing run you actually observed."

CHILD_ERR="$GUARD_DIR/child.err"
CHILD_OUT="$GUARD_DIR/child.json"

t0=$(python3 -c 'import time;print(time.time())')
(
  cd "$CWD" || exit 1
  export ANTHROPIC_BASE_URL="http://127.0.0.1:$TESTER_PROXY_PORT"
  export ANTHROPIC_AUTH_TOKEN="$TESTER_PROXY_KEY"
  export ANTHROPIC_API_KEY=""
  for v in ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
           ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL; do
    export "$v=$TESTER_MODEL"
  done
  export DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  # ⚠ 우회 두 줄 — `--setting-sources ""` 가 이미 훅을 막지만, 누군가 그 플래그를 지웠을 때
  #   자식이 부모 계획을 붙잡지 않도록 이중으로 둔다(③의 해시 대조가 세 번째 겹이다).
  export CLAUDE_PLAN_FILE="$GUARD_DIR/none-plan.md"
  export CLAUDE_REVIEW_FILE="$GUARD_DIR/none-review.md"
  timeout "${TESTER_TIMEOUT:-900}" claude -p "$PROMPT" \
    --model "$TESTER_MODEL" \
    --output-format json \
    --json-schema "$SCHEMA" \
    --append-system-prompt "$(cat "$SELF/system-prompt.md")" \
    --permission-mode bypassPermissions \
    --tools "${TESTER_TOOLS:-Read,Write,Edit,Bash,Glob,Grep}" \
    --setting-sources "" \
    --no-session-persistence \
    --max-turns 80 \
    > "$CHILD_OUT" 2> "$CHILD_ERR"
)
CHILD_RC=$?
t1=$(python3 -c 'import time;print(time.time())')
ELAPSED=$(python3 -c "print(round($t1-$t0,1))")

# ── ⑦ 부모 파일 훼손 검사 (다른 판정보다 앞선다) ────────────────────────────
RESTORED=""
if changed "$PLAN_F" plan;     then cp "$GUARD_DIR/plan.bak"   "$PLAN_F";   RESTORED="$RESTORED plan-active.md"; fi
if changed "$REVIEW_F" review; then cp "$GUARD_DIR/review.bak" "$REVIEW_F"; RESTORED="$RESTORED review-active.md"; fi
if [ -n "$RESTORED" ]; then
  fail_json 68 "parent_files_modified:$RESTORED (원본을 복원했다 — 자식이 완주 게이트를 빠져나가려 한 것으로 보인다)"
fi

# ── ⑧ 산출 파싱 ─────────────────────────────────────────────────────────────
python3 - "$CHILD_OUT" "$OUT" "$ELAPSED" <<'PYPARSE'
import io, json, sys
child, out, elapsed = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(io.open(child, encoding="utf-8"))
except Exception as e:
    json.dump({"_error": "child_json_unreadable: %s" % e}, io.open(out, "w", encoding="utf-8"))
    sys.exit(3)
r = d.get("result")
try:
    inner = json.loads(r) if isinstance(r, str) else r
    if not isinstance(inner, dict):
        raise ValueError("result 가 객체가 아니다")
except Exception as e:
    json.dump({"_error": "result_not_json: %s" % e, "_raw": str(r)[:400]}, io.open(out, "w", encoding="utf-8"))
    sys.exit(4)
u = d.get("usage") or {}
inner["_meta"] = {
    "elapsed_sec": float(elapsed),
    "turns": d.get("num_turns"),
    "subtype": d.get("subtype"),
    "input_tokens": u.get("input_tokens"),
    "output_tokens": u.get("output_tokens"),
}
json.dump(inner, io.open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYPARSE
PARSE_RC=$?
if [ "$PARSE_RC" -ne 0 ]; then
  why="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("_error",""))' "$OUT" 2>/dev/null)"
  fail_json 65 "invalid_output: ${why:-산출을 읽지 못했다} (자식 rc=$CHILD_RC · $(tail -1 "$CHILD_ERR" 2>/dev/null | head -c 160))"
fi

# ── ⑨ 스키마·대조군·쓰기 범위 검증 ──────────────────────────────────────────
snapshot "$AFTER"

# ⚠ 우리 자신이 만든 파일(--out 산출·지시서)을 자식의 위반으로 세지 마라 —
#   「탐지기가 자기 그림자를 잡는」 부류다. 레포 안에 있으면 상대경로로 제외한다.
SELF_MADE=""
case "$OUT" in "$CWD"/*) SELF_MADE="${OUT#$CWD/}" ;; esac
case "$TASK" in "$CWD"/*) SELF_MADE="$SELF_MADE|${TASK#$CWD/}" ;; esac

python3 - "$OUT" "$SELF/result-schema.json" "$BEFORE" "$AFTER" "${TESTER_TEST_PATTERNS:-}" "$MODE" "$SCOPE_METHOD" "$SELF_MADE" <<'PYVERIFY'
import fnmatch, io, json, sys
out, schema_p, before_p, after_p, pats, mode, scope_method = sys.argv[1:8]
self_made = set(x for x in (sys.argv[8] if len(sys.argv) > 8 else "").split("|") if x)
d = json.load(io.open(out, encoding="utf-8"))
schema = json.load(io.open(schema_p, encoding="utf-8"))

missing = [k for k in schema.get("required", []) if k not in d]
if missing:
    sys.stderr.write("필수 필드 누락: %s\n" % ",".join(missing))
    sys.exit(65)

# ⭐ 대조군: mode=full 이고 테스트를 썼으면 발화한 대조군이 있어야 한다.
if mode == "full" and d.get("tests_written"):
    red = [c for c in (d.get("control_group") or []) if c.get("went_red") is True]
    if not red:
        sys.stderr.write("tests_written=%d 인데 went_red 인 대조군이 0건\n" % len(d["tests_written"]))
        sys.exit(67)

# ⭐ 쓰기 범위: 스냅샷이 본 실제 변경이 테스트 패턴 안인가. 모델의 files_changed 를 믿지 않는다.
if scope_method == "none":
    # ⚠ 미검사를 통과로 읽지 않는다 — 결과에 그 사실을 박아 둔다.
    d.setdefault("notes", "")
    d["notes"] = (d["notes"] + " | ⚠ 쓰기 범위 미검사(파일 수가 상한을 넘어 스냅샷을 뜨지 못했다)").strip(" |")
    json.dump(d, io.open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("OK-UNCHECKED")
    sys.exit(0)

def lines(p):
    s = set()
    for line in io.open(p, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n").strip()
        if line:
            s.add(line)
    return s

new = lines(after_p) - lines(before_p)
# fs 방식은 "경로 크기 mtime" 이므로 경로만 뽑는다.
if scope_method == "fs":
    new = set(x.rsplit(" ", 2)[0].lstrip("./") for x in new)

patterns = [x for x in pats.split("|") if x]

def is_test(path):
    base = path.split("/")[-1]
    for pat in patterns:
        if fnmatch.fnmatch(base, pat) or fnmatch.fnmatch(path, pat) or fnmatch.fnmatch(path, "*/" + pat):
            return True
    return False

outside = sorted(p for p in new if not is_test(p) and p not in self_made)
if outside:
    sys.stderr.write("테스트 패턴 밖 변경: %s\n" % ",".join(outside[:8]))
    sys.exit(66)
print("OK")
PYVERIFY
V_RC=$?
case "$V_RC" in
  0)  : ;;
  65) fail_json 65 "schema_violation(필수 필드 누락)" ;;
  66) fail_json 66 "wrote_outside_test_paths(테스트 파일 밖을 고쳤다 — 스냅샷이 본 실제 변경 기준 · 방식=$SCOPE_METHOD)" ;;
  67) fail_json 67 "control_group_missing(테스트를 썼는데 발화한 대조군이 0건)" ;;
  *)  fail_json 65 "validation_failed(rc=$V_RC)" ;;
esac

# ── ⑩ 원장 ──────────────────────────────────────────────────────────────────
LEDGER="$CWD/${TESTER_LEDGER:-.claude/tester/tester.jsonl}"
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
python3 - "$OUT" "$LEDGER" "$LABEL" "$MODE" "$TESTER_MODEL" "$SCOPE_METHOD" <<'PYLEDGER'
import io, json, sys, datetime
out, ledger, label, mode, model, scope = sys.argv[1:7]
d = json.load(io.open(out, encoding="utf-8"))
m = d.get("_meta") or {}
row = {
    "at": datetime.datetime.now().isoformat(timespec="seconds"),
    "label": label, "mode": mode, "model": model, "rc": 0, "scope_check": scope,
    "elapsed_sec": m.get("elapsed_sec"), "turns": m.get("turns"),
    "input_tokens": m.get("input_tokens"), "output_tokens": m.get("output_tokens"),
    "passed": d.get("passed"), "failed": d.get("failed"),
    "tests_written": len(d.get("tests_written") or []),
    "control_red": len([c for c in (d.get("control_group") or []) if c.get("went_red") is True]),
    "control_total": len(d.get("control_group") or []),
    "notes_len": len(d.get("notes") or ""),
}
with io.open(ledger, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PYLEDGER

cat "$OUT"
exit 0
