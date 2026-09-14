#!/usr/bin/env bash
# rollback.sh — 테스트 에이전트를 **도입 전 상태로** 되돌린다.
#
# 사용자 지시(2026-09-15): 「성능이 잘 안되면, 롤백할 수 있게 지금 상태도 기억을 하면 좋겠네」
#
# ⭐ 좌표는 이 스크립트가 아니라 `ROLLBACK.md` 에 있다. 값을 코드에 박으면 문서와 코드가
#   갈라지고, 그때 되돌림은 **틀린 자리로** 간다. 여기서는 그 표를 읽는다.
#
# ⚠ 기본은 dry-run 이다. 무엇을 바꿀지 먼저 말하고, `--apply` 를 받아야 실제로 바꾼다.
#   되돌림은 되돌리기 어렵다 — 그래서 한 단계를 둔다.
#
# 이 스크립트가 하는 것은 **2층까지**다(심링크·프록시·슬롯·설정).
# 3층(코드 되돌림)은 태그가 있어도 사람이 diff 를 보고 revert 해야 한다 — 자동화하지 않는다.
set -u

SELF="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SELF/.." && pwd)"
DOC="$PLUGIN_ROOT/ROLLBACK.md"

APPLY=0; PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    *) echo "사용: rollback.sh [--dry-run|--apply] [--project <레포>]" >&2; exit 64 ;;
  esac
done
PROJECT="${PROJECT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

[ -f "$DOC" ] || { echo "rollback: ⛔ 좌표 문서가 없다: $DOC" >&2; exit 65; }

# ROLLBACK.md 의 표에서 값을 읽는다. 형식: | `KEY` | 값 | 비고 |
coord() { # coord <KEY>
  awk -F'|' -v k="$1" '
    $0 ~ ("`" k "`") {
      v=$3
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      gsub(/`/, "", v)
      sub(/ .*$/, "", v)
      print v
      exit
    }' "$DOC"
}

SYMLINK_PATH="$HOME/.claude/skills/go-review"
TARGET_BEFORE="$(coord SYMLINK_TARGET_BEFORE)"
TAG="$(coord TAG)"

# `~` 로 시작하면 펼친다.
case "$TARGET_BEFORE" in "~"*) TARGET_BEFORE="$HOME${TARGET_BEFORE#\~}" ;; esac

echo "=== 롤백 좌표 (출처: ROLLBACK.md)"
printf '  심링크          %s\n' "$SYMLINK_PATH"
printf '  되돌릴 대상     %s\n' "${TARGET_BEFORE:-⚠ 읽지 못했다}"
printf '  기준 태그       %s\n' "${TAG:-⚠ 읽지 못했다}"
printf '  프로젝트        %s\n' "$PROJECT"
echo

if [ -z "$TARGET_BEFORE" ]; then
  echo "rollback: ⛔ SYMLINK_TARGET_BEFORE 를 읽지 못했다 — ROLLBACK.md 의 표 형식을 확인하라." >&2
  exit 65
fi

plan=""
add() { plan="$plan$1
"; }

now_target="$(readlink "$SYMLINK_PATH" 2>/dev/null || echo '(심링크 아님)')"
[ "$now_target" != "$TARGET_BEFORE" ] && add "심링크를 되돌린다: $now_target → $TARGET_BEFORE" \
                                      || add "심링크는 이미 도입 전 대상이다 — 그대로 둔다"

port="$(python3 - "$PLUGIN_ROOT" <<'PY' 2>/dev/null || echo 4141
import io, json, os, sys
p = os.path.join(sys.argv[1], "tester", "config.default.json")
try:
    print(json.load(io.open(p, encoding="utf-8")).get("proxy_port", 4141))
except Exception:
    print(4141)
PY
)"
if lsof -ti "tcp:$port" >/dev/null 2>&1; then add "프록시를 내린다 (127.0.0.1:$port)"; else add "프록시는 돌지 않는다"; fi

SEM_DIR="${TMPDIR:-/tmp}/go-tester/sem"
slots=$(ls -d "$SEM_DIR"/slot-* 2>/dev/null | wc -l | tr -d ' ')
[ "$slots" != "0" ] && add "세마포어 슬롯 $slots 개를 비운다" || add "세마포어 슬롯 0개"

CG_DIR="${TMPDIR:-/tmp}/go-tester/cg"
wts=$(ls -d "$CG_DIR"/wt-* 2>/dev/null | wc -l | tr -d ' ')
[ "$wts" != "0" ] && add "대조군 임시 워크트리 $wts 개를 거둔다" || add "대조군 임시 워크트리 0개"

OPTIN="$PROJECT/.claude/tester/opt-in.json"
[ -f "$OPTIN" ] && add "옵트인 기록을 지운다: $OPTIN" || add "옵트인 기록 없음(이미 「안 씀」)"

PCFG="$PROJECT/.claude/tester/config.json"
if [ -f "$PCFG" ]; then add "프로젝트 구성을 enabled=off 로 바꾼다: $PCFG"; else add "프로젝트 구성 없음 — 기본이 ask 라 묻기만 한다"; fi

echo "=== 할 일"
printf '%s' "$plan" | sed 's/^/  · /'
echo
echo "=== 3층(코드)은 자동화하지 않는다"
echo "  태그 $TAG 기준으로 사람이 diff 를 보고 revert 한다(reset 이 아니다)."
echo "  대상: ~/개발/go-skill · $PROJECT"
echo

if [ "$APPLY" != "1" ]; then
  echo "dry-run 이다. 실제로 되돌리려면 --apply 를 붙여라."
  exit 0
fi

echo "=== 적용"
if [ "$now_target" != "$TARGET_BEFORE" ]; then
  if [ -d "$TARGET_BEFORE" ]; then
    ln -sfn "$TARGET_BEFORE" "$SYMLINK_PATH" && echo "  심링크 복원 완료"
  else
    # ⚠ 대상이 없는데 심링크를 걸면 체인이 통째로 죽는다 — 그 상태는 「되돌린 것」이 아니다.
    echo "  ⛔ 되돌릴 대상이 없다: $TARGET_BEFORE (rename 했다면 먼저 복원하라)" >&2
  fi
fi
bash "$PLUGIN_ROOT/tester/proxy.sh" stop --port "$port" >/dev/null 2>&1 && echo "  프록시 정지"
rm -rf "$SEM_DIR" 2>/dev/null && echo "  세마포어 정리"
if [ "$wts" != "0" ]; then rm -rf "$CG_DIR" 2>/dev/null && echo "  대조군 워크트리 정리"; fi
[ -f "$OPTIN" ] && rm -f "$OPTIN" && echo "  옵트인 기록 삭제"
if [ -f "$PCFG" ]; then
  python3 - "$PCFG" <<'PY' && echo "  프로젝트 구성 enabled=off"
import io, json, sys
p = sys.argv[1]
d = json.load(io.open(p, encoding="utf-8"))
d["enabled"] = "off"
d["_rollback"] = "rollback.sh 가 껐다. 다시 쓰려면 ask 로 되돌리고 /go 에서 「쓴다」를 답하라."
json.dump(d, io.open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
fi
echo
echo "2층까지 되돌렸다. 체인이 살아 있는지 확인해라:"
echo "  bash \"\$HOME/.claude/skills/go-review/hooks/doctor.sh\""
