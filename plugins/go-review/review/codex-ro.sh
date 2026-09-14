#!/usr/bin/env bash
# codex-ro.sh — 리뷰용 codex 호출의 **유일한 입구**. 읽기 전용을 여기서 못박는다.
#
# ⭐ 왜 래퍼인가 (2026-09-02 실측):
#   역할 정본 3종(reviewer-contract·reviewer-blind·review-merger)은 "구조적으로 읽기
#   전용이라 코드를 고칠 수 없다"고 주장한다. Claude 서브에이전트에서는 그것이 참이다 —
#   frontmatter `tools: Read, Grep, Glob` 라서 **쓰기 도구가 아예 없다**(부재가 통제다).
#   그런데 같은 파일을 codex 가 읽을 때 그 frontmatter 는 **무력**하다.
#
#   ⛔ 대조군으로 확인했다:
#     · `-c sandbox_mode="read-only"` 있음 → 파일 생성 **실패**
#     · 플래그 없음                        → 파일 **생성됨**. 기본이
#       `workspace-write [workdir, /tmp, $TMPDIR]` 이고 **workdir 은 작업 중인 프로젝트**다.
#   즉 플래그 하나를 빼면 리뷰어가 자기가 리뷰하는 코드를 고칠 수 있는데,
#   역할 파일은 여전히 「고칠 수 없다」고 말한다. **fail-open 방향이다.**
#
# ⚠ 그래서 스킬은 `codex exec` 를 직접 부르지 말고 이 스크립트를 부른다.
#   `codex-ro.test.sh` ③ 이 스킬 문서에 남은 맨 `codex exec` 를 잡는다(문서 축의 구조화).
# ⚠⚠ `--full-auto` 는 read-only 를 **덮어쓴다** — 이 스크립트가 인자에서 거부한다.
#
# 사용:
#   codex-ro.sh [-m 모델] [-C 루트] [--reasoning high] [--schema s.json]
#               [-o 산출.json | --out 산출.json] [--err 에러.log] <프롬프트>
#   예) codex-ro.sh -C "$(git rev-parse --show-toplevel)" --reasoning high \
#         --schema "$SELF/finding-schema.json" -o "$ROUND/codex.json" \
#         --err "$ROUND/codex.err" "$(cat "$ROUND/codex-prompt.txt")"
# ⚠ `-o`(codex 가 파일에 쓴다) 와 `--out`(stdout 리다이렉트)은 다르다 — 스킬 실측 주석대로
#   **stdout 은 이벤트 로그와 섞이므로** 스키마를 쓸 때는 `-o` 를 권한다.
set -u

SCHEMA=""; OUT=""; ERR=""; MODEL=""; CODEX_O=""; CWD=""; REASON=""
TMO="${CLAUDE_CODEX_TIMEOUT:-900}"
while [ $# -gt 0 ]; do
  case "$1" in
    --schema) SCHEMA="${2:-}"; shift 2 ;;
    --out)    OUT="${2:-}";    shift 2 ;;
    --err)    ERR="${2:-}";    shift 2 ;;
    -m|--model) MODEL="${2:-}"; shift 2 ;;
    --timeout)  TMO="${2:-}";   shift 2 ;;
    # ⭐ codex 자신의 `-o`(산출 파일)를 통과시킨다. 스킬의 실측 주석: **stdout 은 이벤트
    #   로그와 섞인다** — 그래서 파일로 받는 경로를 막으면 전환이 곧 성능 저하가 된다.
    -o|--output-last-message) CODEX_O="${2:-}"; shift 2 ;;
    # ⭐ 작업 디렉토리. read-only 라 쓰기와 무관하고, 리뷰는 레포 루트에서 봐야 한다.
    -C|--cd) CWD="${2:-}"; shift 2 ;;
    # ⭐ 추론 강도만 화이트리스트로 연다 — 리뷰 품질에 직접 걸리고 샌드박스와 무관하다.
    --reasoning) REASON="${2:-}"; shift 2 ;;
    # ⚠⚠ 읽기 전용을 깨는 인자는 **받지 않는다.** 통제를 인자로 끌 수 있으면 통제가 아니다.
    --full-auto|--dangerously-bypass-approvals-and-sandbox|--yolo)
      echo "codex-ro.sh: '$1' 은 읽기 전용을 덮어쓴다 — 리뷰 경로에서 거부한다." >&2
      exit 64 ;;
    # ⚠ 맨 `-c` 는 통째로 거부한다. 통과시키려면 「어느 키가 안전한가」를 판정해야 하고
    #   그 판정이 틀리면 조용히 읽기 전용이 깨진다. 필요한 키는 **위처럼 전용 옵션으로** 열어라
    #   (지금 열린 것: --reasoning). 그러면 무엇이 열렸는지가 코드에 보인다.
    -c) echo "codex-ro.sh: 맨 '-c' 는 받지 않는다 (sandbox_mode·approval_policy 는 이" >&2
        echo "  스크립트가 정한다). 추론 강도는 --reasoning 을 써라. 다른 키가 필요하면" >&2
        echo "  이 파일에 전용 옵션으로 추가하라 — 그래야 무엇이 열렸는지 보인다." >&2
        exit 64 ;;
    --) shift; break ;;
    -*) echo "codex-ro.sh: 모르는 옵션 '$1'" >&2; exit 64 ;;
    *)  break ;;
  esac
done

if [ $# -lt 1 ]; then
  echo "codex-ro.sh: 프롬프트가 없다. 사용법은 파일 머리말 참조." >&2
  exit 64
fi
PROMPT="$1"

set -- codex exec
[ -n "$MODEL" ]    && set -- "$@" -m "$MODEL"
[ -n "$CWD" ]      && set -- "$@" -C "$CWD"
[ -n "$SCHEMA" ]   && set -- "$@" --output-schema "$SCHEMA"
[ -n "$CODEX_O" ]  && set -- "$@" -o "$CODEX_O"
[ -n "$REASON" ]   && set -- "$@" -c "model_reasoning_effort=\"$REASON\""
# ⭐ 이 줄이 이 스크립트의 존재 이유다. 인자로 끌 수 없다(위에서 거부).
set -- "$@" -c sandbox_mode="read-only" -c approval_policy="never"
set -- "$@" "$PROMPT"

# ⚠⚠ **`timeout` 은 macOS 기본에 없다**(coreutils 를 깔면 `gtimeout` 으로 들어온다).
#   이름 하나만 보고 부르면 rc=127 로 죽고, 호출부는 그것을 「codex 가 실패했다」로 읽는다 —
#   틀린 사유는 없는 것보다 나쁘다. 이름 해석은 `_deps.sh` 한 곳에서 한다(정본을 둘로 두지 마라).
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/../hooks/_deps.sh" 2>/dev/null || true
TCMD=''
command -v deps_timeout_cmd >/dev/null 2>&1 && TCMD=$(deps_timeout_cmd)
if [ -n "$TCMD" ]; then
  set -- "$TCMD" "$TMO" "$@"
else
  # ⚠ 상한 없이 부르는 것과 상한이 있는 것은 다르다 — **어느 쪽인지 말한다**(정직 공백).
  echo "codex-ro.sh: ⚠ timeout·gtimeout 이 없어 **시간 상한 없이** 부른다(${TMO}s 무시). 설치: brew install coreutils" >&2
fi

# ⚠ `< /dev/null` 없으면 stdin 대기로 영원히 멈춘다(직접 밟았다).
if [ -n "$OUT" ] && [ -n "$ERR" ]; then
  "$@" < /dev/null > "$OUT" 2> "$ERR"
elif [ -n "$OUT" ]; then
  "$@" < /dev/null > "$OUT"
else
  "$@" < /dev/null
fi
rc=$?

# ⚠⚠ 스키마를 줬으면 **산출이 실제로 파싱되는지** 확인한다 — 깨진 JSON 을 조용히 넘기면
#    「리뷰가 없었다」와 「리뷰가 실패했다」가 구분되지 않는다(정직 공백).
# ⚠ 확인 대상은 **실제로 JSON 이 담기는 파일**이다 — `-o` 를 줬으면 그쪽이고, 아니면 stdout.
#   (엉뚱한 파일을 검사하면 「통과」가 아무 의미도 없다 — 이 세션에서 두 번 밟은 부류다)
TARGET="${CODEX_O:-$OUT}"
if [ "$rc" -eq 0 ] && [ -n "$SCHEMA" ] && [ -n "$TARGET" ]; then
  if ! python3 -c "import io,json,sys;json.load(io.open(sys.argv[1],encoding='utf-8'))" "$TARGET" 2>/dev/null; then
    echo "codex-ro.sh: ⚠ 산출이 유효한 JSON 이 아니다: $TARGET (에러 로그: ${ERR:-없음})" >&2
    exit 65
  fi
fi
exit "$rc"
