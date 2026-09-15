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

# ⛔⛔ 게이트는 **셸에 통째로** 넘겨라 (2026-09-15 실측 — 이 레포에서 대조군이 한 번도
#   성립하지 않았다). 종전 코드는 `eval "timeout $TMO $GATE"` 였고, 게이트가
#   `cd backend && go test ...` 같은 복합 명령이면 `timeout` 이 **첫 낱말 `cd` 에만** 붙는다.
#   그리고 macOS 에는 `/usr/bin/cd` 가 실제로 존재한다 — 그래서 그 호출은 **조용히 rc 0** 을
#   내고(자식 프로세스의 디렉토리만 바뀌고 사라진다) `&&` 를 통과한 뒤, 뒤 명령이
#   **워크트리 루트**에서 돈다. go.mod 가 `backend/` 에 있는 레포에서는 거기서 실패한다.
#   ⇒ 출력은 「go.mod 가 없다」이고, 읽는 사람은 **레포 구조 문제**로 읽는다. 실제로는
#     측정 도구의 버그다. 틀린 사유는 없는 것보다 나쁘다.
#   ⚠ `timeout` 이 없는 환경도 있다(BSD 계열 기본). 없으면 시간 제한 없이 그냥 돌린다 —
#     상한을 잃는 것이 측정 자체를 잃는 것보다 낫다.
CG_PARSE="$(cd "$(dirname "$0")" && pwd)/_cgpaths.py"
CG_TIMEOUT=""
for c in timeout gtimeout; do command -v "$c" >/dev/null 2>&1 && { CG_TIMEOUT="$c"; break; }; done

run_gate() { # run_gate <작업 디렉토리> → 게이트의 종료 코드
  if [ -n "$CG_TIMEOUT" ]; then
    ( cd "$1" && "$CG_TIMEOUT" "$TMO" bash -c "$GATE" ) >/dev/null 2>&1
  else
    ( cd "$1" && bash -c "$GATE" ) >/dev/null 2>&1
  fi
}

emit() { # emit <went_red> <rc_mut> <rc_clean> <reason>
  python3 -c 'import json,sys;print(json.dumps({"went_red":sys.argv[1]=="true","gate_rc_mutated":int(sys.argv[2]),"gate_rc_clean":int(sys.argv[3]),"reason":sys.argv[4]},ensure_ascii=False))' \
    "$1" "$2" "$3" "$4"
}

[ -n "$REPO" ] && [ -n "$FILE" ] && [ -n "$SEDEXPR" ] && [ -n "$GATE" ] || {
  emit false 0 0 "인자 부족(--repo --file --sed --gate 가 모두 필요하다)"; exit 64; }

git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || {
  emit false 0 0 "git 레포가 아니다: $REPO"; exit 65; }

# ⛔⛔ 게이트가 **원본 레포의 절대경로**를 품고 있으면 대조군이 성립하지 않는다 (2026-09-15 실측).
#   이 스크립트는 `( cd "$WT" && eval "$GATE" )` 로 게이트를 워크트리 안에서 돌린다. 그런데
#   게이트가 `cd /절대/경로/backend && go test ...` 형태면 그 `cd` 가 **워크트리 밖 원본으로
#   되돌아간다** — 변이는 사본에만 있으므로 게이트는 멀쩡한 원본을 보고 초록을 낸다.
#   ⇒ `went_red:false` 가 나오고, 읽는 사람은 「테스트가 그 동작을 안 잠근다」로 읽는다.
#     실제로는 테스트가 아니라 **측정이 틀린 것**이다. 조용하고, 결론이 정확히 반대다.
#   그래서 그 조건을 거부한다. 게이트는 **레포 루트 기준 상대경로**로 줘라
#     ✔ `cd backend && go test ./internal/... -count=1`
#     ✘ `cd /Users/me/repo/backend && go test ./internal/... -count=1`
#   ⚠ 경로를 **한 가지 형태로만** 비교하지 마라. macOS 의 `/tmp` 는 `/private/tmp` 로 가는
#     심링크라 논리 경로와 물리 경로가 다르다. 처음 판은 `pwd -P`(물리)만 봐서, 호출자가
#     논리 경로로 준 게이트를 놓쳤다 — 그 조건에서 검사가 **조용히 통과**한다.
#     대조군 G5 가 그것을 잡았다(변이해도 went_red:false 가 나오는 것을 실제로 재현했다).
REPO_PHYS="$(cd "$REPO" 2>/dev/null && pwd -P)"
REPO_LOGICAL="$(cd "$REPO" 2>/dev/null && pwd)"
for cand in "$REPO" "$REPO_PHYS" "$REPO_LOGICAL"; do
  [ -n "$cand" ] || continue
  case " $GATE " in
    *"$cand"*)
      emit false 0 0 "게이트가 원본 레포의 절대경로를 가리킨다($cand) — 그러면 변이본이 아니라 원본에서 돌아 대조군이 거짓 음성이 된다. 레포 루트 기준 상대경로로 줘라(예: 'cd backend && go test ./... -count=1')"
      exit 68 ;;
  esac
done

WTBASE="${WTBASE:-${TMPDIR:-/tmp}/go-tester/cg}"
mkdir -p "$WTBASE"

# ⭐ 시작할 때 **고아를 먼저 치운다** — trap 은 SIGKILL 을 못 잡는다(2026-09-15 에 둘이 남았다).
#   자식의 도구 호출이 타임아웃으로 강제 종료되면 cleanup 이 돌지 못하고 워크트리가 남는다.
#   쌓이면 `worktree list` 가 지저분해지고 사람이 손으로 치우게 된다.
git -C "$REPO" worktree prune >/dev/null 2>&1
if [ -d "$WTBASE" ]; then
  find "$WTBASE" -maxdepth 1 -type d -name 'wt-*' -mmin +60 2>/dev/null | while IFS= read -r stale; do
    git -C "$REPO" worktree remove --force "$stale" >/dev/null 2>&1
    rm -rf "$stale" 2>/dev/null
  done
  git -C "$REPO" worktree prune >/dev/null 2>&1
fi

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
#
# ⚠ 경로 목록은 `-z`(NUL 구분)로 받는다. 종전 판은 `status --porcelain | awk '{print $NF}'`
#   이었고 셋을 놓쳤다 — ① 공백이 들어간 경로는 마지막 낱말만 남는다 ② 이름이 바뀐 항목
#   (`R  옛 -> 새`)의 원본 경로가 섞여 든다 ③ **untracked 디렉토리**는 porcelain 이
#   `계단/` 한 줄로 접어서 내보내는데, `[ -f ]` 로 걸러 버리면 그 안의 파일이 하나도
#   따라오지 않는다. 디렉토리면 통째로 복사한다.
CG_LIST="$WTBASE/paths.$$"
git -C "$REPO" -c core.quotePath=false status --porcelain -z 2>/dev/null > "$CG_LIST"
if [ -s "$CG_LIST" ]; then
  python3 "$CG_PARSE" "$CG_LIST" | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rel="${rel%/}"
    if [ -d "$REPO/$rel" ]; then
      mkdir -p "$WT/$(dirname "$rel")" 2>/dev/null
      cp -R "$REPO/$rel" "$WT/$rel" 2>/dev/null
    elif [ -f "$REPO/$rel" ]; then
      mkdir -p "$WT/$(dirname "$rel")" 2>/dev/null
      cp "$REPO/$rel" "$WT/$rel" 2>/dev/null
    fi
  done
fi
rm -f "$CG_LIST"

# ⛔⛔ 무시 대상이지만 **게이트가 반드시 필요로 하는 산출물**을 이어 준다 (2026-09-15 실측).
#   `git worktree add` 는 추적되는 파일만 체크아웃한다. 그래서 `node_modules` 처럼
#   gitignore 된 설치 산출물이 사본에 **없다** — `npx vitest` 는 거기서 무조건 실패한다.
#   그러면 ①의 「깨끗한 상태」부터 rc≠0 이 되고 스크립트는 「대조군이 성립하지 않는다」를
#   낸다. 읽는 사람은 그것을 **테스트의 문제**로 읽지만 실제로는 사본에 의존이 없는 것이다.
#   ⇒ 그 조건에서 웹 슬라이스는 대조군을 **한 번도** 세울 수 없다. 2026-09-15 에 한
#     저장소에서 위임 호출 둘이 연달아 rc 67 로 거부됐고, 자식은 「스크립트가 한글 경로를
#     파싱하지 못한다」는 **틀린 사유**를 보고했다. 틀린 사유는 없는 것보다 나쁘다.
#   ⭐ 복사가 아니라 **심링크**다. node_modules 는 파일이 수만 개라 복사하면 대조군 한 번에
#     분 단위가 든다. 대조군은 소스만 변이하므로 의존을 공유해도 격리가 깨지지 않는다.
#   ⚠ 링크는 워크트리를 버릴 때 함께 사라진다(`rm -rf` 는 심링크 자체만 지운다).
git -C "$REPO" -c core.quotePath=false ls-files -- '*package.json' 2>/dev/null \
  | grep -v '/node_modules/' | sed 's#package\.json$##' | while IFS= read -r depdir; do
  SRC_NM="$REPO/${depdir}node_modules"
  [ -d "$SRC_NM" ] || continue
  [ -e "$WT/${depdir}node_modules" ] && continue
  [ -n "$depdir" ] && mkdir -p "$WT/$depdir" 2>/dev/null
  ln -s "$SRC_NM" "$WT/${depdir}node_modules" 2>/dev/null
done

[ -f "$WT/$FILE" ] || { emit false 0 0 "변이 대상 파일이 워크트리에 없다: $FILE"; exit 67; }

# ── ① 깨끗한 상태에서 게이트가 통과하는가 ────────────────────────────────────
run_gate "$WT"
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
run_gate "$WT"
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
