#!/usr/bin/env bash
# controlgroup.sh — 대조군을 **격리된 워크트리에서** 돌린다.
#
# 왜 스크립트인가: 대조군은 「소스를 일부러 깨고 되돌리는」 절차다. 그 조작을 모델에게
#   맡기면 두 가지가 일어난다 — ① 되돌리기를 빠뜨려 레포가 깨진 채 남는다
#   ② `git stash` 를 쓴다. 이 레포군에서 bare stash 는 금지다(스택이 다른 세션·워크트리와
#   공유되어 남의 작업을 삼킨다. 실측 6회).
#   ⇒ 격리된 워크트리에서 깨고, 끝나면 워크트리째 버린다. 원본은 처음부터 손대지 않는다.
#
# 사용:
#   controlgroup.sh --repo <레포> --file <변이할 파일> --sed <sed 표현식> --gate '<게이트 명령>'
#                   [--worktree-base <경로>] [--timeout <초>]
#
# 출력: JSON 한 줄 {"went_red":true|false,"gate_rc_mutated":N,"gate_rc_clean":N,"reason":"..."}
#
# 판정: **깨면 실패하고, 안 깨면 통과**해야 went_red=true 다.
#   ⚠ 「깨면 실패한다」만 보면 안 된다 — 원래부터 실패하는 게이트도 그 조건을 만족한다.
#     양쪽을 다 봐야 「그 보호 때문에 실패했다」가 성립한다(탐지기 생존 증명).
set -u

REPO=""; FILE=""; SEDEXPR=""; GATE=""; WTBASE=""; TMO="600"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)          REPO="${2:-}";    shift 2 ;;
    --file)          FILE="${2:-}";    shift 2 ;;
    --sed)           SEDEXPR="${2:-}"; shift 2 ;;
    --gate)          GATE="${2:-}";    shift 2 ;;
    --worktree-base) WTBASE="${2:-}";  shift 2 ;;
    --timeout)       TMO="${2:-}";     shift 2 ;;
    *) shift ;;
  esac
done

emit() { # emit <went_red> <rc_mut> <rc_clean> <reason>
  python3 -c 'import json,sys;print(json.dumps({"went_red":sys.argv[1]=="true","gate_rc_mutated":int(sys.argv[2]),"gate_rc_clean":int(sys.argv[3]),"reason":sys.argv[4]},ensure_ascii=False))' \
    "$1" "$2" "$3" "$4"
}

[ -n "$REPO" ] && [ -n "$FILE" ] && [ -n "$SEDEXPR" ] && [ -n "$GATE" ] || {
  emit false 0 0 "인자 부족(--repo --file --sed --gate 가 모두 필요하다)"; exit 64; }

git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || {
  emit false 0 0 "git 레포가 아니다: $REPO"; exit 65; }

WTBASE="${WTBASE:-${TMPDIR:-/tmp}/go-tester/cg}"
mkdir -p "$WTBASE"
WT="$WTBASE/wt-$$-$(date +%s)"

cleanup() {
  # ⚠ 실패해도 반드시 회수한다 — 워크트리가 쌓이면 다음 실행이 느려지고 사람이 치우게 된다.
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT" 2>/dev/null
  git -C "$REPO" worktree prune >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

# ⭐ detach 로 만든다 — 브랜치를 점유하면 같은 브랜치를 쓰는 다른 워크트리가 거부당한다.
if ! git -C "$REPO" worktree add --detach --quiet "$WT" HEAD 2>"$WTBASE/err.$$"; then
  emit false 0 0 "워크트리 생성 실패: $(tail -1 "$WTBASE/err.$$" 2>/dev/null)"
  rm -f "$WTBASE/err.$$"; exit 66
fi
rm -f "$WTBASE/err.$$"

# ⭐ 커밋되지 않은 작업 파일(방금 쓴 테스트 등)을 워크트리로 옮긴다.
#   워크트리는 HEAD 를 체크아웃하므로 미커밋 변경이 없다 — 그대로 두면 **테스트 파일이 없는**
#   상태에서 대조군을 돌리게 되고, 그러면 무엇을 깨도 「붉어지지 않는다」가 나온다(거짓 음성).
if git -C "$REPO" status --porcelain 2>/dev/null | grep -q .; then
  git -C "$REPO" -c core.quotePath=false status --porcelain | awk '{print $NF}' | while IFS= read -r rel; do
    [ -f "$REPO/$rel" ] || continue
    mkdir -p "$WT/$(dirname "$rel")" 2>/dev/null
    cp "$REPO/$rel" "$WT/$rel" 2>/dev/null
  done
fi

[ -f "$WT/$FILE" ] || { emit false 0 0 "변이 대상 파일이 워크트리에 없다: $FILE"; exit 67; }

# ── ① 깨끗한 상태에서 게이트가 통과하는가 ────────────────────────────────────
( cd "$WT" && eval "timeout $TMO $GATE" ) >/dev/null 2>&1
RC_CLEAN=$?

# ── ② 변이를 넣고 게이트가 실패하는가 ────────────────────────────────────────
# sed -i 는 BSD/GNU 가 다르다 — 둘 다 받는다(이 레포군이 두 번 밟은 이식성 함정).
if ! sed -i '' "$SEDEXPR" "$WT/$FILE" 2>/dev/null; then
  sed -i "$SEDEXPR" "$WT/$FILE" 2>/dev/null || { emit false "$RC_CLEAN" "$RC_CLEAN" "sed 변이 적용 실패"; exit 68; }
fi
if cmp -s "$WT/$FILE" "$REPO/$FILE" 2>/dev/null; then
  # ⚠ sed 가 아무것도 바꾸지 않았는데 「붉어지지 않았다」고 보고하면 그것은 거짓 음성이다.
  emit false "$RC_CLEAN" "$RC_CLEAN" "sed 표현식이 파일을 바꾸지 못했다(변이 0) — 표현식을 확인하라"
  exit 69
fi
( cd "$WT" && eval "timeout $TMO $GATE" ) >/dev/null 2>&1
RC_MUT=$?

if [ "$RC_CLEAN" -ne 0 ]; then
  emit false "$RC_MUT" "$RC_CLEAN" "깨끗한 상태에서 이미 게이트가 실패한다(rc=$RC_CLEAN) — 대조군이 성립하지 않는다"
  exit 0
fi
if [ "$RC_MUT" -eq 0 ]; then
  emit false "$RC_MUT" "$RC_CLEAN" "변이를 넣어도 게이트가 통과한다 — 그 테스트는 이 동작을 잠그지 않는다"
  exit 0
fi
emit true "$RC_MUT" "$RC_CLEAN" "깨끗=통과 · 변이=실패 — 대조군 발화"
exit 0
