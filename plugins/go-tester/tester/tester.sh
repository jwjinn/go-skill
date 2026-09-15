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
#
# 사용:
#   tester.sh --task <지시서 파일> [--mode run|write|full] [--cwd <레포>] [--out <산출.json>]
#             [--gate '<게이트 명령>'] [--label <라벨>]
#
# 종료코드:
#   0   정상 — 스키마를 통과한 JSON 을 냈다(stdout 은 그 JSON **하나뿐**이다)
#   64  사용법 오류
#   65  산출이 무효(JSON 이 아니거나 스키마 불충족)
#   66  테스트 파일 밖을 고쳤다 · 또는 쓰기 범위를 **검사하지 못했다**
#   67  대조군 누락(테스트 파일이 바뀌었는데 발화한 대조군이 0건)
#   68  부모 계획·리뷰 파일이 훼손됐다(원본을 복원했다)
#   70  쓸 수 없다 — 꺼졌거나·옵트인 없음·heartbeat 불가·슬롯 대기 초과·**업스트림 거부**
#       (⭐ heartbeat 는 통과했는데 본 작업이 403/401/429 로 막히는 경우가 실재한다)
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

# ⭐ `timeout` 은 이름이 둘이고 macOS 에는 기본 설치가 없다. 없으면 **상한 없이** 부른다 —
#   「없는 명령이라 위임이 통째로 안 돌았는데 산출 오류로 보고되는」 것보다 낫다(리뷰 g5).
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD="gtimeout"
fi

GUARD_DIR=""
LEDGER_PATH=""
KEEP_GUARD=0

ledger_append() { # ledger_append <rc> <사유>
  # ⭐ **실패도 원장에 남긴다**(리뷰 g2). 성공만 기록하면 폴백률의 분자가 구조적으로 0 이고,
  #   그러면 「폴백 0회」가 「폴백이 없었다」인지 「기록이 안 됐다」인지 갈리지 않는다.
  [ -n "$LEDGER_PATH" ] || return 0
  mkdir -p "$(dirname "$LEDGER_PATH")" 2>/dev/null || return 0
  python3 - "$LEDGER_PATH" "$LABEL" "$MODE" "${TESTER_MODEL:-}" "$1" "$2" <<'PYL' 2>/dev/null || true
import io, json, sys, datetime
ledger, label, mode, model, rc, reason = sys.argv[1:7]
row = {
    "at": datetime.datetime.now().isoformat(timespec="seconds"),
    "label": label, "mode": mode, "model": model,
    "rc": int(rc), "reason": reason[:300],
}
with io.open(ledger, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PYL
}

fail_json() { # fail_json <rc> <사유>
  KEEP_GUARD=1
  # ⚠ 보존 경로를 **모든 실패 사유**에 싣는다(리뷰). 종전에는 파싱 실패에만 있었다.
  local why="$2"
  if [ -n "$GUARD_DIR" ] && [ -d "$GUARD_DIR" ]; then why="$why · 보존: $GUARD_DIR"; fi
  python3 -c 'import json,sys;print(json.dumps({"mode":sys.argv[1],"commands":[],"passed":0,"failed":0,"skipped":0,"failures":[],"tests_written":[],"control_group":[],"files_changed":[],"notes":"","unavailable_reason":sys.argv[2]},ensure_ascii=False))' \
    "$MODE" "$why" > "$OUT"
  ledger_append "$1" "$why"
  cat "$OUT"
  exit "$1"
}

[ -n "$TASK" ] && [ -f "$TASK" ] || { echo "tester.sh: --task <지시서 파일> 이 필요하다." >&2; exit 64; }

# ── ① 켤 수 있나 ─────────────────────────────────────────────────────────────
CFG_OUT="$(CLAUDE_PROJECT_DIR="$CWD" python3 "$SELF/_config.py" 2>/dev/null)"
eval "$(printf '%s' "$CFG_OUT" | grep -E '^TESTER_[A-Z_]+=' | sed 's/^/export /')"
LEDGER_PATH="$CWD/${TESTER_LEDGER:-.claude/tester/tester.jsonl}"

if [ "${TESTER_ENABLED:-0}" != "1" ]; then
  # ⭐ 여기가 fail-closed 지점이다. 묻지 않았거나·답이 「쓴다」가 아니거나·구성이 off 면
  #   **프록시조차 띄우지 않고** 멈춘다.
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

# ── ③ 프록시 — **참조 카운트**로 공유한다 ───────────────────────────────────
# ⛔ 종전에는 「내가 띄웠으면 내가 내린다」였고, 그래서 먼저 끝난 호출이 **아직 돌고 있는
#   형제 호출의 프록시를 죽였다**(리뷰 g13). 자식은 그 순간부터 엔드포인트에 닿지 못해
#   빈 산출을 내고, 우리는 그것을 rc 65 「지시서 문제」로 보고했다 — 원인을 반대로 지목한다.
PROXY_USERS="${TMPDIR:-/tmp}/go-tester/users-${TESTER_PROXY_PORT:-4141}"
mkdir -p "$PROXY_USERS"
USER_MARK="$PROXY_USERS/$$"

proxy_users_count() {
  local n=0 m p
  for m in "$PROXY_USERS"/*; do
    [ -e "$m" ] || continue
    p="$(basename "$m")"
    case "$p" in *[!0-9]*) rm -f "$m"; continue ;; esac
    if kill -0 "$p" 2>/dev/null; then n=$((n + 1)); else rm -f "$m"; fi
  done
  printf '%s' "$n"
}

: > "$USER_MARK"
if ! bash "$SELF/proxy.sh" status --port "$TESTER_PROXY_PORT" >/dev/null 2>&1; then
  if ! bash "$SELF/proxy.sh" start --port "$TESTER_PROXY_PORT" --endpoint "$TESTER_ENDPOINT" \
         --model "$TESTER_MODEL" --key "$TESTER_PROXY_KEY" >/dev/null 2>&1; then
    rm -f "$USER_MARK"
    fail_json 70 "proxy_start_failed(heartbeat 는 통과했는데 본 실행용 기동에 실패했다)"
  fi
fi

# ── ④ 부모 계획·리뷰 파일의 지문 ─────────────────────────────────────────────
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
# ⭐⭐ 복원은 **덮어쓰기**다 — 되돌리기 전에 지금 내용을 반드시 남겨라 (2026-09-15 실측).
#   첫 실사용에서 이 경로가 발화했는데 원인이 자식이 아니라 **부모**였다: 부모 세션이
#   자식이 도는 동안 계획 파일을 파킹(`mv`)했고, 가드가 그것을 훼손으로 읽어 되돌렸다.
#   그때 부모의 변경이 아무 사본도 없이 사라진다 — 가드가 지키려던 것을 가드가 삼킨다.
#   ⇒ 되돌리기 전에 `<이름>.at-exit` 로 보존하고, 그 경로를 사유에 실어 되찾을 수 있게 한다.
restore_one() { # restore_one <파일> <이름> → 바뀌었으면 보존·복원하고 0
  changed "$1" "$2" || return 1
  [ -f "$1" ] && cp "$1" "$GUARD_DIR/$2.at-exit" 2>/dev/null
  cp "$GUARD_DIR/$2.bak" "$1"
}
restore_parents() {
  # ⭐ 신호로 죽을 때도 **복원이 먼저**다(리뷰 g10). 종전 트랩은 백업이 든 GUARD_DIR 을
  #   지우고 끝나서, INT·TERM 경로에서는 자식이 고친 계획 파일이 그대로 남았다.
  local restored=""
  if restore_one "$PLAN_F"   plan;   then restored="$restored plan-active.md"; fi
  if restore_one "$REVIEW_F" review; then restored="$restored review-active.md"; fi
  printf '%s' "$restored"
}
snap "$PLAN_F" plan
snap "$REVIEW_F" review

# ── ⑤ 변경 전 스냅샷 ─────────────────────────────────────────────────────────
# ⛔ 여기가 fail-open 이 되기 쉬운 자리다. 첫 판은 git 이 아니면 빈 목록을 만들었고, 두 번째
#   판은 **경로 이름만** 담아서 「이미 더티인 파일을 자식이 더 고치는」 경우를 놓쳤다
#   (리뷰 g3 — 정상 흐름이 「구현(미커밋) → 그 코드의 테스트를 위임」이라 흔한 조건이다).
#   ⇒ 경로가 아니라 **내용 지문**을 담고, 양방향으로 비교해 삭제도 잡는다(g16).
IS_GIT=0
git -C "$CWD" rev-parse --show-toplevel >/dev/null 2>&1 && IS_GIT=1
BEFORE="$GUARD_DIR/before.txt"
AFTER="$GUARD_DIR/after.txt"
SCOPE_METHOD="git"
FILE_CAP=20000

digest_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

snapshot() { # snapshot <산출 파일> — "<경로>\t<지문>" 한 줄씩
  if [ "$IS_GIT" = "1" ]; then
    SCOPE_METHOD="git"
    {
      git -C "$CWD" -c core.quotePath=false ls-files -z 2>/dev/null \
        | while IFS= read -r -d '' rel; do
            if [ -f "$CWD/$rel" ]; then printf '%s\t%s\n' "$rel" "$(digest_of "$CWD/$rel")"
            else printf '%s\t__MISSING__\n' "$rel"; fi
          done
      git -C "$CWD" -c core.quotePath=false ls-files -z --others --exclude-standard 2>/dev/null \
        | while IFS= read -r -d '' rel; do
            [ -f "$CWD/$rel" ] && printf '%s\t%s\n' "$rel" "$(digest_of "$CWD/$rel")"
          done
    } | sort > "$1"
    return 0
  fi
  n=$(find "$CWD" -type f -not -path '*/.git/*' 2>/dev/null | head -n $((FILE_CAP + 1)) | wc -l | tr -d ' ')
  if [ "$n" -gt "$FILE_CAP" ]; then
    SCOPE_METHOD="none"
    printf '__TOO_MANY_FILES__\t0\n' > "$1"
    return 0
  fi
  SCOPE_METHOD="fs"
  ( cd "$CWD" && find . -type f -not -path './.git/*' -print 2>/dev/null ) \
    | while IFS= read -r rel; do
        printf '%s\t%s\n' "${rel#./}" "$(digest_of "$CWD/${rel#./}")"
      done | sort > "$1"
}
snapshot "$BEFORE"

# ── ⑥ 슬롯 · 정리 ───────────────────────────────────────────────────────────
release_all() {
  sem_release
  rm -f "$USER_MARK" 2>/dev/null
  # 마지막 사용자가 나갈 때만 프록시를 내린다.
  if [ "$(proxy_users_count)" = "0" ]; then
    bash "$SELF/proxy.sh" stop --port "${TESTER_PROXY_PORT:-4141}" >/dev/null 2>&1
  fi
  [ "${KEEP_GUARD:-0}" = "1" ] || rm -rf "$GUARD_DIR" 2>/dev/null
}
on_signal() {
  r="$(restore_parents)"
  [ -n "$r" ] && echo "tester.sh: 신호로 중단 — 부모 파일 복원:$r" >&2
  ledger_append 143 "interrupted${r:+ · 복원:$r}"
  release_all
  exit 143
}
trap 'release_all' EXIT
trap 'on_signal' INT TERM

if ! sem_acquire "${TESTER_MAX_CONCURRENCY:-4}" 900; then
  fail_json 70 "semaphore_timeout(동시 상한 ${TESTER_MAX_CONCURRENCY:-4} 에서 900초 대기 후 포기)"
fi

# ── ⑦ 자식 실행 ─────────────────────────────────────────────────────────────
SCHEMA="$(cat "$SELF/result-schema.json")"   # ⚠ --json-schema 는 **경로가 아니라 JSON 문자열**이다(실측)

# ⭐⭐ 결과를 **파일로** 받는다 (2026-09-15 · 실측으로 바꿨다).
#   종전에는 자식의 **마지막 메시지**가 곧 산출이었고 `--json-schema` 로 그것을 강제했다.
#   그런데 도구를 쓴 다중 턴 세션에서 작은 모델은 그 전환을 못 한다 — 실측:
#   「go vet은 문제가 없었습니다. now return the structured output:」 에서 멈췄다.
#   일은 다 해 놓고 형식만 못 갖춰 rc 65 로 통째로 버려지는 것이 그 부류다.
#   ⚠ 도구 없는 단일 호출에서는 같은 모델이 스키마를 정확히 지켰다 — 즉 능력이 아니라
#     **전환**의 문제다.
#   ⇒ 파일 쓰기는 도구 호출이라 이미 되는 것이 증명돼 있다(자식이 Bash 로 게이트를 돌렸다).
#     그 경로를 산출의 **정본**으로 삼고, 마지막 메시지는 폴백으로 남긴다.
#   ⚠ 이 파일은 `$GUARD_DIR` 안이라 레포 밖이다 — 쓰기 범위 검사에 걸리지 않는다.
REPORT_FILE="$GUARD_DIR/report.json"
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

CONTROL GROUP COMMAND (this is the CONTROLGROUP <...> your instructions refer to)
  bash $SELF/controlgroup.sh --repo $CWD --file <source file> --sed '<sed expression>' --gate '${GATE:-<gate command>}'
It mutates a throwaway copy of the tree, never this working tree, and prints one JSON line
with went_red. Use it instead of editing any source file yourself.

OUTPUT CONTRACT - WRITE IT TO A FILE (this is how the caller reads your result)
Before you finish, write your report as ONE JSON object to exactly this path:
  $REPORT_FILE
Use the Write tool. The file must contain the JSON object and nothing else.
Required keys:
  mode, commands, passed, failed, skipped, failures, tests_written,
  control_group, files_changed, notes, unavailable_reason
Set mode to \"$MODE\". Every entry in control_group needs test, mutation and went_red,
and went_red is true only for a failing run you actually observed.

Writing that file is the last thing you do. If you skip it the whole run is discarded,
however good your work was. After writing it, reply with the same JSON as your final
message too - but the file is what counts."

CHILD_ERR="$GUARD_DIR/child.err"
CHILD_OUT="$GUARD_DIR/child.json"

# ⭐ 감시 창을 **자식이 도는 구간**으로 좁힌다 (2026-09-15).
#   ④ 의 첫 스냅은 프록시 기동·세마포어 대기보다 앞이라, 그 사이(실측 최대 900초 대기)에
#   부모가 자기 계획 파일을 고치면 자식과 무관한 변경이 ⑧ 에 걸린다. 여기서 다시 찍으면
#   남는 창은 자식의 수명뿐이다. ⚠ 첫 스냅을 없애지 마라 — 트랩(INT·TERM)이 그것에 기댄다.
snap "$PLAN_F" plan
snap "$REVIEW_F" review

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
  #   자식이 부모 계획을 붙잡지 않도록 이중으로 둔다(④의 해시 대조가 세 번째 겹이다).
  export CLAUDE_PLAN_FILE="$GUARD_DIR/none-plan.md"
  export CLAUDE_REVIEW_FILE="$GUARD_DIR/none-review.md"
  set -- claude -p "$PROMPT" \
    --model "$TESTER_MODEL" --output-format json --json-schema "$SCHEMA" \
    --append-system-prompt "$(cat "$SELF/system-prompt.md")" \
    --permission-mode bypassPermissions --tools "${TESTER_TOOLS:-Read,Write,Edit,Bash,Glob,Grep}" \
    --setting-sources "" --no-session-persistence --max-turns 80
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "${TESTER_TIMEOUT:-900}" "$@" > "$CHILD_OUT" 2> "$CHILD_ERR"
  else
    "$@" > "$CHILD_OUT" 2> "$CHILD_ERR"
  fi
)
CHILD_RC=$?
t1=$(python3 -c 'import time;print(time.time())')
ELAPSED=$(python3 -c "print(round($t1-$t0,1))")

# ── ⑧ 부모 파일 훼손 검사 (다른 판정보다 앞선다) ────────────────────────────
RESTORED="$(restore_parents)"
if [ -n "$RESTORED" ]; then
  # ⛔ **어느 쪽이 고쳤는지 이 도구는 가르지 못한다.** 2026-09-15 첫 실사용에서 이 경로가
  #   발화했고 원인은 자식이 아니라 부모였다(부모가 계획을 파킹했다). 종전 문구는
  #   「자식이 게이트를 빠져나가려 한 것으로 보인다」고 단정했는데, 틀린 사유는 없는 것보다
  #   나쁘다 — 사람을 반대 방향으로 보낸다. ⇒ 관측된 것만 말하고 판단 재료를 함께 준다.
  #   ⚠ 자식은 `CLAUDE_PLAN_FILE` 이 임시 경로로 덮여 있고 `--setting-sources ""` 로 훅도
  #     막혀 있다(⑦). 즉 자식이 부모 계획을 고칠 동기가 구조적으로 없다 — 부모를 먼저 의심하라.
  WHY68="parent_files_modified:$RESTORED (되돌리기 전 내용을 <이름>.at-exit 로 남겼다"
  WHY68="$WHY68 · 부모가 고친 것이면 그 파일로 되찾아라 · 자식·부모 어느 쪽인지는 가르지 못한다)"
  if [ -s "$REPORT_FILE" ]; then
    SUM68="$(python3 - "$REPORT_FILE" <<'PYSUM' 2>/dev/null
import io, json, sys
try:
    d = json.load(io.open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit
cg = d.get("control_group") or []
red = sum(1 for c in cg if isinstance(c, dict) and c.get("went_red") is True)
print("자식 보고서는 남아 있다: 통과 %s · 실패 %s · 테스트 %s건 · 대조군 발화 %s/%s · %s"
      % (d.get("passed"), d.get("failed"), len(d.get("tests_written") or []), red, len(cg), sys.argv[1]))
PYSUM
)"
    [ -n "$SUM68" ] && WHY68="$WHY68 · $SUM68"
  fi
  fail_json 68 "$WHY68"
fi

# ── ⑨ 산출 파싱 ─────────────────────────────────────────────────────────────
python3 - "$CHILD_OUT" "$OUT" "$ELAPSED" "$REPORT_FILE" <<'PYPARSE'
import io, json, os, sys
child, out, elapsed = sys.argv[1], sys.argv[2], sys.argv[3]
report = sys.argv[4] if len(sys.argv) > 4 else ""
try:
    d = json.load(io.open(child, encoding="utf-8"))
except Exception as e:
    json.dump({"_error": "child_json_unreadable", "_detail": str(e), "_raw": ""},
              io.open(out, "w", encoding="utf-8"))
    sys.exit(3)
# ⭐ 파일이 정본이다(위 OUTPUT CONTRACT). 없거나 깨졌으면 마지막 메시지로 폴백한다.
#   두 경로를 두는 이유: 파일 쓰기는 도구라 작은 모델도 하지만, 큰 모델은 마지막 메시지로도
#   정확히 답한다. 한쪽만 두면 그 모델군에서 멀쩡한 작업이 버려진다.
inner = None
src = ""
if report and os.path.exists(report):
    try:
        cand = json.load(io.open(report, encoding="utf-8"))
        if isinstance(cand, dict):
            inner, src = cand, "file"
    except Exception:
        pass
r = d.get("result")
try:
    if inner is None:
        inner = json.loads(r) if isinstance(r, str) else r
        src = "message"
    if not isinstance(inner, dict):
        raise ValueError("result 가 객체가 아니다")
except Exception as e:
    json.dump({"_error": "result_not_json", "_detail": str(e), "_raw": str(r)[:400]},
              io.open(out, "w", encoding="utf-8"))
    sys.exit(4)
u = d.get("usage") or {}
# ⚠ `_meta` 는 스키마에 없다(additionalProperties:false). 산출에 섞으면 우리 자신이 계약을
#   깬다(리뷰 g17) ⇒ 곁 파일에 쓴다. 원장이 그 파일을 읽는다.
meta = {
    "elapsed_sec": float(elapsed), "turns": d.get("num_turns"), "subtype": d.get("subtype"),
    "result_source": src,
    "input_tokens": u.get("input_tokens"), "output_tokens": u.get("output_tokens"),
}
json.dump(meta, io.open(out + ".meta.json", "w", encoding="utf-8"), ensure_ascii=False)
json.dump(inner, io.open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYPARSE
PARSE_RC=$?
if [ "$PARSE_RC" -ne 0 ]; then
  # ⭐ 업스트림 거부와 모델의 형식 오류를 **가른다.** 고칠 곳이 다르다.
  #   ⚠ 종전에는 사유 문자열 전체에 `*403*` 을 걸어서 파서의 오류 위치(`char 401`)까지
  #     HTTP 상태로 읽었다(리뷰 g19). ⇒ **자식이 낸 원문만** 보고, 숫자는 단독으로 보지 않는다.
  RAW="$(python3 -c 'import json,sys
try: print((json.load(open(sys.argv[1])).get("_raw") or "").replace(chr(10)," ")[:400])
except Exception: print("")' "$OUT" 2>/dev/null)"
  DETAIL="$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); print(d.get("_error","") + ((": " + d.get("_detail","")) if d.get("_detail") else ""))
except Exception: print("산출을 읽지 못했다")' "$OUT" 2>/dev/null)"
  case "$RAW" in
    *"fabrix-guard"*|*"보안 정책"*|*"Failed to authenticate"*|*"AuthenticationError"*|\
    *"API Error: 403"*|*"API Error: 401"*|*"API Error: 429"*|*"status 403"*|*"status 401"*|\
    *"status 429"*|*"rate_limit"*|*"PermissionDenied"*|*"insufficient_quota"*)
      fail_json 70 "upstream_rejected: $(printf '%s' "$RAW" | cut -c1-220) (heartbeat 는 통과했지만 본 작업이 거부됐다 — 엔드포인트·정책 문제이지 지시서 문제가 아니다)" ;;
  esac
  fail_json 65 "invalid_output: ${DETAIL:-산출을 읽지 못했다}$( [ -n "$RAW" ] && printf ' | 자식이 낸 것: %s' "$(printf '%s' "$RAW" | cut -c1-220)" )(자식 rc=$CHILD_RC)"
fi

# ── ⑩ 스키마·쓰기 범위·대조군 검증 ──────────────────────────────────────────
snapshot "$AFTER"

# ⚠ 우리 자신이 만든 파일(--out 산출·지시서)을 자식의 위반으로 세지 마라.
SELF_MADE=""
case "$OUT" in "$CWD"/*) SELF_MADE="${OUT#$CWD/}|${OUT#$CWD/}.meta.json" ;; esac
case "$TASK" in "$CWD"/*) SELF_MADE="$SELF_MADE|${TASK#$CWD/}" ;; esac

VERIFY_ERR="$GUARD_DIR/verify.err"
python3 - "$OUT" "$SELF/result-schema.json" "$BEFORE" "$AFTER" "${TESTER_TEST_PATTERNS:-}" "$MODE" "$SCOPE_METHOD" "$SELF_MADE" 2> "$VERIFY_ERR" <<'PYVERIFY'
import fnmatch, io, json, sys
out, schema_p, before_p, after_p, pats, mode, scope_method = sys.argv[1:8]
self_made = set(x for x in (sys.argv[8] if len(sys.argv) > 8 else "").split("|") if x)
d = json.load(io.open(out, encoding="utf-8"))
schema = json.load(io.open(schema_p, encoding="utf-8"))

# ── 스키마: 필수 키 + **금지된 여분 키**(additionalProperties:false 를 우리도 지킨다)
missing = [k for k in schema.get("required", []) if k not in d]
if missing:
    sys.stderr.write("필수 필드 누락: %s" % ",".join(missing))
    sys.exit(65)
if schema.get("additionalProperties") is False:
    extra = [k for k in d if k not in (schema.get("properties") or {})]
    if extra:
        sys.stderr.write("스키마에 없는 필드: %s" % ",".join(extra))
        sys.exit(65)

patterns = [x for x in pats.split("|") if x]

def is_test(path):
    base = path.split("/")[-1]
    for pat in patterns:
        if fnmatch.fnmatch(base, pat) or fnmatch.fnmatch(path, pat) or fnmatch.fnmatch(path, "*/" + pat):
            return True
    return False

if scope_method == "none":
    # ⛔ 미검사를 통과로 읽지 않는다(리뷰 g12). 검사하지 못한 것은 **거부**다 —
    #   「검사했고 깨끗하다」와 「검사 자체가 안 됐다」를 같은 rc 로 말할 수 없다.
    sys.stderr.write("쓰기 범위를 검사하지 못했다(파일 수가 상한을 넘었다)")
    sys.exit(66)

def fp(p):
    m = {}
    for line in io.open(p, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line:
            continue
        path, _, digest = line.partition("\t")
        m[path] = digest
    return m

b, a = fp(before_p), fp(after_p)
touched = set(p for p, dg in a.items() if b.get(p) != dg)
touched |= set(p for p in b if p not in a)          # 삭제도 변경이다

outside = sorted(p for p in touched if not is_test(p) and p not in self_made)
if outside:
    sys.stderr.write("테스트 패턴 밖 변경: %s" % ",".join(outside[:8]))
    sys.exit(66)

# ── 대조군: **관측**을 기준으로 한다(자기신고가 아니라).
#   ⚠ 종전에는 `mode == "full" and tests_written` 이었다. 그러면 ①write 모드로 부르거나
#     ②tests_written 을 빈 배열로 보고하면 검사가 통째로 건너뛰어졌다(리뷰 g7).
test_touched = sorted(p for p in touched if is_test(p) and p not in self_made)
if mode in ("full", "write") and test_touched:
    red = [c for c in (d.get("control_group") or []) if c.get("went_red") is True]
    if not red:
        sys.stderr.write("테스트 파일 %d개가 바뀌었는데 went_red 인 대조군이 0건: %s"
                         % (len(test_touched), ",".join(test_touched[:5])))
        sys.exit(67)
    claimed = set(t.get("file") for t in (d.get("tests_written") or []))
    unreported = [p for p in test_touched if p not in claimed]
    if unreported:
        d["notes"] = (str(d.get("notes") or "") +
                      " | ⚠ tests_written 에 없는 테스트 파일 변경: " + ",".join(unreported[:5])).strip(" |")
        json.dump(d, io.open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYVERIFY
V_RC=$?
V_MSG="$(head -3 "$VERIFY_ERR" 2>/dev/null | tr '\n' ' ')"
case "$V_RC" in
  0)  : ;;
  65) fail_json 65 "schema_violation: ${V_MSG}" ;;
  66) fail_json 66 "wrote_outside_test_paths: ${V_MSG}(스냅샷 방식=$SCOPE_METHOD)" ;;
  67) fail_json 67 "control_group_missing: ${V_MSG}" ;;
  *)  fail_json 65 "validation_failed(rc=$V_RC) ${V_MSG}" ;;
esac

# ── ⑪ 원장 ──────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LEDGER_PATH")" 2>/dev/null
python3 - "$OUT" "$LEDGER_PATH" "$LABEL" "$MODE" "$TESTER_MODEL" "$SCOPE_METHOD" <<'PYLEDGER'
import io, json, os, sys, datetime
out, ledger, label, mode, model, scope = sys.argv[1:7]
d = json.load(io.open(out, encoding="utf-8"))
m = {}
mp = out + ".meta.json"
if os.path.exists(mp):
    try:
        m = json.load(io.open(mp, encoding="utf-8"))
    except Exception:
        m = {}
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

# ⭐ stdout 은 **JSON 하나뿐**이다(리뷰 g15). 검증 스크립트의 진단은 stderr 로만 나간다.
cat "$OUT"
exit 0
