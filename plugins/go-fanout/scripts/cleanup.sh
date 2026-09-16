#!/usr/bin/env bash
# go-fanout 정리 — 이 fan-out 라운드가 만든 워커 워크트리를 회수 후 삭제한다.
#
# ⭐ 「기억」은 새로 만들지 않는다. Orca 의 `orchestration worker-list` 가 이미
#    runId → worktreeId(전체 경로) 를 들고 있고, 그것이 정본이다.
# ⭐ 이 스크립트의 본체는 삭제가 아니라 **잃을 것을 먼저 건지는 것**이다.
#    실측(2026-09-07): 정리 대기 중이던 워크트리 5개의 미커밋 변경이 전부
#    `docs/리뷰-이력/`·`.claude/go-report.md` 였다 — 그냥 지웠으면 측정 이력과
#    fan-out provenance 를 잃었을 것이고, 코드가 아니라서 눈에도 안 띈다.
#
# 용법:
#   bash cleanup.sh                      # 후보 표만 낸다(기본 dry-run — 아무것도 안 바꾼다)
#   bash cleanup.sh --run run_abc123     # 그 라운드만
#   bash cleanup.sh --apply              # 회수 → release → 워크트리 삭제
#   bash cleanup.sh --apply --run <id> --archive-dir ~/some/dir
#
# 종료 코드: 0 정상 · 1 하나 이상 실패 · 2 사용법 오류
set -uo pipefail

ORCA_BIN="${ORCA_BIN:-orca}"
GH_BIN="${GH_BIN:-gh}"
ARCHIVE_ROOT="${FANOUT_ARCHIVE_DIR:-$HOME/orca/fanout-archive}"

RUN_FILTER=""
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --run)         RUN_FILTER="${2:-}"; shift 2 ;;
    --apply)       APPLY=1; shift ;;
    --archive-dir) ARCHIVE_ROOT="${2:-}"; shift 2 ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

# 미커밋이어도 「코드 변경」으로 보지 않는 경로들 — 게이트·리뷰 체인이 워크트리에
# 남기는 산출물이다. 삭제를 막지는 않되 **아카이브 대상**이 된다.
HARVEST_PATHS=(
  ".claude/go-report.md"
  ".claude/plan-active.md"
  ".claude/plan-draft.md"
  ".claude/review-active.md"
  ".claude/plans"
  ".claude/state"
  ".claude/review/runs"
  "docs/리뷰-이력"
)

is_harvestable() {  # $1 = git status 가 낸 경로
  local p="$1" h
  for h in "${HARVEST_PATHS[@]}"; do
    case "$p" in "$h"|"$h"/*) return 0 ;; esac
  done
  return 1
}

# ── 1. Orca 에게 이 라운드의 워커를 묻는다 (기억의 정본) ────────────────────
wl_args=(orchestration worker-list --json)
[ -n "$RUN_FILTER" ] && wl_args+=(--run "$RUN_FILTER")

WORKERS_JSON="$("$ORCA_BIN" "${wl_args[@]}" 2>/dev/null)"
if [ -z "$WORKERS_JSON" ]; then
  echo "⛔ orca worker-list 가 응답하지 않았다 — 무엇을 지울지 모르는 상태다. 중단한다." >&2
  exit 1
fi

ROWS="$(printf '%s' "$WORKERS_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in (d.get("result") or {}).get("workers") or []:
    r = w.get("resource") or {}
    wid = r.get("worktreeId") or ""
    path = wid.split("::", 1)[1] if "::" in wid else ""
    if not path:
        continue
    print("\t".join([
        w.get("runId") or "", w.get("dispatchId") or "",
        w.get("workerState") or "", w.get("terminalState") or "", path,
    ]))
')"

if [ -z "$ROWS" ]; then
  echo "정리할 워커가 없다 (worker-list 가 빈 결과)."
  exit 0
fi

# ── 2. 워크트리마다 판정 ────────────────────────────────────────────────────
declare -a READY_PATH READY_DISPATCH READY_RUN READY_BRANCH EXTRA_DISPATCH
SEEN_PATHS=$'\n'
FAILED=0
printf '%-24s %-11s %-9s %s\n' "워크트리" "워커" "판정" "사유"
printf -- '─%.0s' {1..96}; echo

while IFS=$'\t' read -r run_id dispatch state term path; do
  [ -n "$path" ] || continue
  name="$(basename "$path")"
  verdict="" reason=""

  # 같은 워크트리에 dispatch 가 여럿일 수 있다(실측: 후속 재판정 워커가 같은 경로를
  # 다시 썼다). 경로는 한 번만 판정하고, 나머지 dispatch 는 release 만 한다.
  if [[ "$SEEN_PATHS" == *$'\n'"$path"$'\n'* ]]; then
    verdict="dup"; reason="같은 워크트리의 다른 dispatch — release 만"
    EXTRA_DISPATCH+=("$dispatch")
  elif [ ! -d "$path" ]; then
    verdict="gone"; reason="경로 없음 — 이미 정리됨"
  elif [ "$state" != "succeeded" ] && [ "$state" != "failed" ]; then
    verdict="hold"; reason="워커가 아직 settled 가 아니다($state)"
  else
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
      verdict="hold"; reason="브랜치를 못 읽었다(detached?) — 머지 판정 불가"
    elif ! command -v "$GH_BIN" >/dev/null 2>&1; then
      verdict="hold"; reason="gh 없음 — 머지 여부를 모른다"
    else
      pr_state="$("$GH_BIN" pr list --head "$branch" --state all \
                    --json state --jq '.[0].state' 2>/dev/null \
                    < /dev/null || true)"
      # ⚠ 머지 판정을 `git rev-list origin/main..branch` 로 하지 마라 — 이 레포는
      #    squash merge 라 머지된 브랜치에도 커밋이 남아 있다(실측: 2~11건).
      if [ "$pr_state" != "MERGED" ]; then
        verdict="hold"; reason="PR 이 MERGED 가 아니다(${pr_state:-PR 없음})"
      else
        code_dirty=0
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          p="${line:3}"
          p="${p#\"}"; p="${p%\"}"
          is_harvestable "$p" || code_dirty=$((code_dirty + 1))
        # -uall: untracked 를 디렉토리(`?? .claude/`)가 아니라 파일 단위로 낸다 — 아니면
        #        완전 untracked 디렉토리 안의 go-report.md 가 화이트리스트에 안 걸린다.
        # quotePath=false: 한글 경로를 `\353\246…` 로 이스케이프하지 않게 한다.
        done < <(git -C "$path" -c core.quotePath=false status --porcelain -uall 2>/dev/null)

        if [ "$code_dirty" -gt 0 ]; then
          verdict="hold"; reason="미커밋 코드 변경 ${code_dirty}건 — 사람이 봐야 한다"
        else
          verdict="ready"; reason="PR MERGED · 코드 미커밋 0"
          READY_PATH+=("$path"); READY_DISPATCH+=("$dispatch")
          READY_RUN+=("$run_id"); READY_BRANCH+=("$branch")
        fi
      fi
    fi
  fi

  SEEN_PATHS+="$path"$'\n'
  printf '%-24s %-11s %-9s %s\n' "${name:0:24}" "$state" "$verdict" "$reason"
done <<< "$ROWS"

echo
n_ready="${#READY_PATH[@]}"

if [ "$n_ready" -eq 0 ]; then
  echo "삭제 가능한 워크트리가 없다."
  exit 0
fi

if [ "$APPLY" -eq 0 ]; then
  echo "정리 가능: ${n_ready}개. 실제로 지우려면 --apply 를 붙여라(그때 먼저 아카이브한다)."
  echo "아카이브 위치: $ARCHIVE_ROOT/<run_id>/<워크트리>/"
  exit 0
fi

# ── 3. 회수 → release → 삭제 ────────────────────────────────────────────────
i=0
while [ "$i" -lt "$n_ready" ]; do
  path="${READY_PATH[$i]}"; dispatch="${READY_DISPATCH[$i]}"
  run_id="${READY_RUN[$i]}"; branch="${READY_BRANCH[$i]}"
  name="$(basename "$path")"
  dest="$ARCHIVE_ROOT/$run_id/$name"
  i=$((i + 1))

  echo "▸ $name"
  mkdir -p "$dest" || { echo "  ⛔ 아카이브 디렉토리를 못 만들었다 — 삭제하지 않는다"; FAILED=1; continue; }

  {
    echo "worktree: $path"
    echo "branch:   $branch"
    echo "head:     $(git -C "$path" rev-parse HEAD 2>/dev/null)"
    echo "run:      $run_id"
    echo "dispatch: $dispatch"
    echo "archived: $(date -Iseconds)"
  } > "$dest/meta.txt"

  git -C "$path" -c core.quotePath=false status --porcelain -uall > "$dest/git-status.txt" 2>/dev/null
  git -C "$path" diff HEAD          > "$dest/uncommitted.diff" 2>/dev/null

  for h in "${HARVEST_PATHS[@]}"; do
    if [ -e "$path/$h" ]; then
      mkdir -p "$dest/files/$(dirname "$h")"
      rm -rf "$dest/files/$h"          # 재실행 시 `cp -R` 이 기존 디렉토리 안으로 중첩 복사하는 것을 막는다(실측)
      cp -R "$path/$h" "$dest/files/$h" 2>/dev/null
    fi
  done
  echo "  회수 → $dest"

  # 아카이브가 실제로 남았는지 확인한 뒤에만 지운다.
  if [ ! -s "$dest/meta.txt" ]; then
    echo "  ⛔ 아카이브가 비었다 — 삭제하지 않는다"; FAILED=1; continue
  fi

  # 회수한 파일을 워크트리에서 치운다. ⚠ 실측(2026-09-07): Orca 의 `worktree rm` 은 미커밋
  # 파일이 하나라도 있으면 거부한다(`?? .claude/go-report.md`) — 우리 화이트리스트를 모른다.
  # 판정이 ready 였으므로 미커밋은 전부 화이트리스트 안이고, 방금 아카이브했으니 잃는 것이 없다.
  git -C "$path" checkout -q -- . 2>/dev/null                       # tracked 수정 되돌림
  for h in "${HARVEST_PATHS[@]}"; do
    [ -e "$path/$h" ] && git -C "$path" clean -fdq -- "$h" 2>/dev/null   # untracked 산출물 제거
  done
  leftover="$(git -C "$path" -c core.quotePath=false status --porcelain -uall 2>/dev/null)"
  if [ -n "$leftover" ]; then
    echo "  ⛔ 치운 뒤에도 미커밋이 남았다 — 삭제하지 않는다:"; printf '%s\n' "$leftover" | sed 's/^/     /'
    FAILED=1; continue
  fi

  "$ORCA_BIN" orchestration worker-release --dispatch "$dispatch" --json >/dev/null 2>&1 \
    && echo "  터미널 release" \
    || echo "  ⚠ release 실패(무시하고 진행 — 터미널이 이미 닫혔을 수 있다)"

  # ⭐ 브랜치는 남긴다(사용자 결정 2026-09-07). `orca worktree rm` 은 체크아웃된
  #    로컬 브랜치를 함께 지우려 하므로, 먼저 detach 해서 「지울 브랜치」가 없게 만든다.
  common_dir="$(git -C "$path" rev-parse --git-common-dir 2>/dev/null)"
  case "$common_dir" in /*) ;; *) common_dir="$path/$common_dir" ;; esac
  if ! git -C "$path" checkout --detach -q 2>/dev/null; then
    echo "  ⛔ detach 실패 — 브랜치를 보존할 수 없어 삭제하지 않는다"; FAILED=1; continue
  fi

  rm_out="$("$ORCA_BIN" worktree rm --worktree "path:$path" --json 2>&1)"
  if [ $? -eq 0 ] && ! printf '%s' "$rm_out" | grep -q '"ok": *false'; then
    echo "  삭제 완료"
    if [ -n "$common_dir" ] && ! git --git-dir="$common_dir" show-ref --verify -q "refs/heads/$branch"; then
      echo "  ⚠ 브랜치 $branch 가 사라졌다 — 원격에는 있을 것이다(PR MERGED). 사람이 확인하라."
      FAILED=1
    else
      echo "  브랜치 $branch 보존"
    fi
  else
    # --force 는 자동으로 붙이지 않는다. 왜 거부됐는지는 사람이 봐야 한다.
    # 실패했으면 브랜치를 다시 붙여 워크트리를 원상태로 둔다(재실행이 detached 로 막히지 않게).
    git -C "$path" checkout -q "$branch" 2>/dev/null
    echo "  ⛔ 워크트리 삭제 실패 — 아카이브는 남아 있고 브랜치는 다시 붙였다. Orca 의 말:"
    printf '%s\n' "$rm_out" | python3 -c 'import json,sys
try: print("     " + (json.load(sys.stdin).get("error") or {}).get("message", "(메시지 없음)"))
except Exception: print("     " + sys.stdin.read()[:300])' 2>/dev/null
    echo "     orca worktree rm --worktree path:$path"
    FAILED=1
  fi
done

for d in "${EXTRA_DISPATCH[@]+"${EXTRA_DISPATCH[@]}"}"; do
  "$ORCA_BIN" orchestration worker-release --dispatch "$d" --json >/dev/null 2>&1 \
    && echo "▸ 추가 dispatch $d release" \
    || echo "▸ ⚠ 추가 dispatch $d release 실패(무시)"
done

echo
if [ "$FAILED" -ne 0 ]; then
  echo "일부가 실패했다. 위 사유를 보고 처리하라."
  exit 1
fi
echo "정리 완료 — 아카이브는 $ARCHIVE_ROOT 에 남아 있다."
exit 0
