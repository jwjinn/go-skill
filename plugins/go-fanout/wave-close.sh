#!/usr/bin/env bash
# wave-close.sh — 파도 마감을 **한 명령**으로. 재고, 막히면 멈추고, 통과하면 회수로 넘긴다.
#
# # 왜 있나 (2026-09-13 · 2026-09-15 실측)
#
# 마감 절차는 이미 다 있었다. `worker-release` 도, `cleanup.sh` 도, 보고 회수 순서도.
# 빠진 것은 **그것을 언제 누가 부르느냐** 하나였고, 그래서 세 번 새어 나갔다.
#
#   · 워커 13명이 끝난 뒤에도 터미널 15개·워크트리 13개가 **밤새** 살아 있었다(2026-09-13).
#   · 회수 직전 미커밋이 전부 리뷰 원장과 종료 보고였다 — 그냥 지웠으면 사라졌다(3/3).
#   · 종료 보고가 **상속본**인 것을 사람이 해시를 비교하고서야 알았다(5중 3 · 2026-09-15).
#
# ⇒ 규율이 아니라 **순서가 박힌 한 명령**으로 만든다. 이 스크립트는 재기만 하고, 되돌릴 수
#   없는 일(회수·삭제)은 `--apply` 를 줘야 `cleanup.sh` 에 넘긴다. 기본은 dry-run 이다.
#
# # 무엇을 자동으로 하고 무엇을 안 하나
#
#   자동: **재는 것 전부**(워커 상태 · 보고 · 미커밋 · 원장 · 파일 집합 교차)
#   사람: **되돌릴 수 없는 것**(PR 머지 · 그림자·라이브 배포 · 합본 리뷰의 must_fix 반영)
#
#   ⚠ 이 경계를 옮기지 마라. 재는 것을 사람에게 맡기면 오늘처럼 놓치고, 되돌릴 수 없는 것을
#     자동으로 하면 되돌릴 방법이 없다.
#
# 용법:
#   bash wave-close.sh --run <run_id> --base <ref> [--marker <날짜>]          # 재기만 한다
#   bash wave-close.sh --run <run_id> --base <ref> --marker 2026-09-15 --apply # 통과하면 회수까지
#
# 판정: 0 마감 가능(또는 완료) · 1 막힌 것이 있다 · 2 검사 자체가 안 됐다
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
ORCA_BIN="${ORCA_BIN:-orca}"
RUN=""; BASE=""; MARKER=""; APPLY=0; REPO_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

while [ $# -gt 0 ]; do
  case "$1" in
    --run)    RUN="${2:-}";    shift 2 ;;
    --base)   BASE="${2:-}";   shift 2 ;;
    --marker) MARKER="${2:-}"; shift 2 ;;
    --repo)   REPO_DIR="${2:-}"; shift 2 ;;
    --apply)  APPLY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

[ -n "$RUN" ] || { echo "wave-close: --run <run_id> 가 필요하다." >&2; exit 2; }
command -v "$ORCA_BIN" >/dev/null 2>&1 || { echo "wave-close: orca 가 없다(검사 못 함)." >&2; exit 2; }

BLOCK=0; UNMEASURED=0; HUMAN_BLOCKED=0

# ⭐⭐ 「보류」 표식 — 사람을 기다리는 동안 Stop 훅이 조용해지게 한다 (2026-09-15).
#
#   실측: 마감 게이트가 「자원이 살아 있다」로 막는데 그것을 푸는 조건이 **사람의 PR 머지**인
#   경우가 있다. 그러면 코디네이터는 풀 수단이 없는 채로 매 턴 막히고, 세션당 상한 8회를
#   소음으로 태운 뒤 통과한다. 막는 것 자체는 옳지만 **풀 수 없는 것을 반복해 막는 것**은
#   게이트를 소음으로 만들고, 소음이 된 게이트는 사람이 끈다.
#
#   ⚠ 이 표식은 **내가 재서** 쓴다. 코디네이터가 손으로 쓰는 것이 아니다 — 그러면 빠져나가는
#     문이 된다. 사유와 시각이 함께 들어가고, 오래되면 훅이 무시한다.
DEFER_DIR="${TMPDIR:-/tmp}/go-fanout"
DEFER_FILE="$DEFER_DIR/deferred.${RUN}.json"
step() { printf '\n── %s ─────────────────────────────\n' "$1"; }
blocked() { BLOCK=$((BLOCK+1)); printf '  ⛔ %s\n' "$1"; }
unmeasured() { UNMEASURED=$((UNMEASURED+1)); printf '  ⚠ %s\n' "$1"; }
fine() { printf '  ✅ %s\n' "$1"; }

WL="$("$ORCA_BIN" orchestration worker-list --run "$RUN" --json 2>/dev/null)" || WL=""
[ -n "$WL" ] || { echo "wave-close: worker-list 를 못 받았다(검사 못 함)." >&2; exit 2; }

# ── ① 파도가 정말 끝났나 ─────────────────────────────────────────────────────
# ⚠ `worker-list` 의 상태를 그대로 믿지 마라. 2026-09-15 실측으로 목록은 여섯 다
#   `ready/working` 이라 했는데 터미널은 둘이 `done` 이었다. 반대 방향도 있다.
#   여기서는 **끝나지 않은 것이 있으면 멈추는** 쪽으로만 쓴다(거짓 진행은 안전하다).
step "① 워커 상태"
PENDING="$(printf '%s' "$WL" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit(0)
for w in (d.get("result") or {}).get("workers") or []:
    st=str(w.get("workerState") or ""); ds=str(w.get("dispatchStatus") or "")
    # ⚠ `failed` 는 **끝난 것**이다. 진행 중과 섞어 세면 실패한 워커 하나 때문에 파도를
    #   영원히 못 닫는다(오늘 죽은 워커 하나를 새 워커로 대체하고도 그랬을 것이다).
    #   여기서 막는 대상은 **아직 도는 워커**뿐이다. 실패한 워커의 산출물은 ②③이 잡는다.
    if st in ("succeeded","failed") or ds in ("completed","failed"):
        continue
    print("%s\t%s/%s" % (w.get("dispatchId"), st, ds))
' 2>/dev/null)"
if [ -n "$PENDING" ]; then
  printf '%s\n' "$PENDING" | while IFS=$'\t' read -r id st; do
    printf '  ⛔ 아직 끝나지 않았다: %s (%s)\n' "$id" "$st"
  done
  blocked "파도가 끝나지 않았다 — 마감하지 마라"
else
  fine "이 run 에 아직 도는 워커가 없다"
fi

# ⚠ 실패로 끝난 워커는 막지 않되 **말한다.** 조용히 넘기면 그 산출물이 회수에서 빠진다.
printf '%s' "$WL" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit(0)
for w in (d.get("result") or {}).get("workers") or []:
    if str(w.get("workerState"))=="failed" or str(w.get("dispatchStatus"))=="failed":
        print("  ⚠ 실패로 끝난 워커가 있다: %s — 그 워크트리의 산출물을 꼭 확인해라" % w.get("dispatchId"))
' 2>/dev/null

WTS="$(printf '%s' "$WL" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit(0)
seen=set()
for w in (d.get("result") or {}).get("workers") or []:
    r=w.get("resource") or {}
    wid=str(r.get("worktreeId") or "")
    p=wid.split("::",1)[1] if "::" in wid else ""
    if p and p not in seen:
        seen.add(p); print(p)
' 2>/dev/null)"

if [ -z "$WTS" ]; then
  unmeasured "워크트리 경로를 못 뽑았다 — 아래 검사를 못 돈다"
fi

# ── ② 종료 보고가 진짜인가 ───────────────────────────────────────────────────
# 파일이 있다고 보고가 아니다. 판정은 base 의 그 파일과 blob 해시가 다른가 하나다.
step "② 종료 보고"
CHK="$REPO_DIR/scripts/worker-report-check.sh"
if [ -z "$WTS" ]; then
  unmeasured "대상 워크트리가 없어 건너뛴다"
elif [ ! -f "$CHK" ]; then
  unmeasured "worker-report-check.sh 가 없다($CHK) — 보고 진위를 못 잰다"
elif [ -z "$BASE" ]; then
  unmeasured "--base 가 없어 상속본을 가릴 수 없다"
else
  args=(--base "$BASE"); [ -n "$MARKER" ] && args+=(--marker "$MARKER")
  # shellcheck disable=SC2086
  if bash "$CHK" "${args[@]}" $WTS; then fine "전부 이번 차수 보고를 남겼다"
  else
    rc=$?
    [ "$rc" = "2" ] && unmeasured "보고 검사가 판정 2 다(검사 못 함)" || blocked "보고가 빠졌거나 상속본이다"
  fi
fi

# ── ③ 미커밋 — 거의 항상 리뷰 원장과 종료 보고다 ─────────────────────────────
step "③ 미커밋"
if [ -z "$WTS" ]; then
  unmeasured "대상 워크트리가 없어 건너뛴다"
else
  dirty=0
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    if ! git -C "$wt" rev-parse --show-toplevel >/dev/null 2>&1; then
      unmeasured "$(basename "$wt") — git 워크트리가 아니다"; continue
    fi
    n=$(git -C "$wt" -c core.quotePath=false status --porcelain 2>/dev/null | grep -c .)
    if [ "$n" -gt 0 ]; then
      printf '  ⛔ %s — 미커밋 %s건\n' "$(basename "$wt")" "$n"
      git -C "$wt" -c core.quotePath=false status --porcelain 2>/dev/null | sed 's/^/        /' | head -8
      dirty=$((dirty+1))
    fi
  done <<EOF
$WTS
EOF
  if [ "$dirty" -gt 0 ]; then
    blocked "$dirty 개 워크트리에 미커밋이 있다 — 거두기 전에 지우지 마라"
  else
    fine "미커밋 0"
  fi
fi

# ── ④ 리뷰 원장 무결성 ───────────────────────────────────────────────────────
step "④ 리뷰 원장"
LEDGER="$REPO_DIR/scripts/review-ledger-check.sh"
if [ ! -f "$LEDGER" ]; then
  unmeasured "review-ledger-check.sh 가 없다 — 원장 중복을 못 잰다"
else
  if (cd "$REPO_DIR" && bash "$LEDGER" >/dev/null 2>&1); then fine "원장 판정 0"
  else
    rc=$?
    [ "$rc" = "2" ] && unmeasured "원장 검사가 판정 2 다(실행 불가)" || blocked "원장에 중복·키 부재가 있다"
  fi
fi

# ── ⑤ 파일 집합 교차 ─────────────────────────────────────────────────────────
# ⛔⛔ 셸의 `sort | uniq -d` 로 세지 마라 (2026-09-15 실측 — 거짓 양성 3건).
#   한 워커만 건드린 한글 경로 셋이 교차로 보고됐다. 원인 후보 둘을 `_crossing.py` 가 함께
#   막는다 — ①한 워크트리 안의 중복(교차는 **다른 워커끼리**여야 한다) ②유니코드 정규화
#   (macOS 는 NFD, git 저장은 NFC 라 겉보기가 같은 경로가 다른 바이트로 나온다).
#   이 저장소가 여러 번 밟은 「git 비ASCII 경로」 부류의 새 변종이다.
step "⑤ 파일 집합 교차"
if [ -z "$WTS" ] || [ -z "$BASE" ]; then
  unmeasured "워크트리 또는 --base 가 없어 교차를 못 잰다"
else
  CROSS_OUT="$(printf '%s\n' "$WTS" | tr '\n' '\0' | xargs -0 python3 "$SELF/_crossing.py" "$BASE" 2>/dev/null)"
  CROSS_RC=$?
  if [ -z "$CROSS_OUT" ]; then
    unmeasured "교차를 재지 못했다"
  else
    printf '%s\n' "$CROSS_OUT" | head -1 | while read -r _ n; do
      [ "${n:-0}" -gt 0 ] 2>/dev/null && printf '  · 공용 산출물 %s건(합치는 대상이지 충돌이 아니다)\n' "$n"
    done
    # 공용 장부는 이름까지 보여 준다 — 매 파도에서 같은 파일이 겹치면 배치를 바꿀 신호다.
    printf '%s\n' "$CROSS_OUT" | grep '^SHARED-FILE' | sed 's/^SHARED-FILE\t/        · /' | head -8
    # ⚠ `SHARED` 머리줄과 `SHARED-FILE` 줄을 빼야 **진짜 소스 교차**만 남는다.
    REAL="$(printf '%s\n' "$CROSS_OUT" | grep -v '^SHARED')"
    if [ -n "$REAL" ]; then
      printf '%s\n' "$REAL" | sed 's/^/        /' | head -10
      blocked "두 워커가 **같은 소스 파일**을 고쳤다 — 합치기 전에 판단이 필요하다"
      # ⭐ 사람을 기다리는 사유다(아래 보류 표식 참조).
      HUMAN_BLOCKED=1
    else
      fine "소스 교차 0"
    fi
  fi
fi

# ── 판정 ─────────────────────────────────────────────────────────────────────
echo
echo "막힌 것 $BLOCK · 검사 못 함 $UNMEASURED"

# 보류 표식은 **막힌 것이 사람 사유 하나뿐일 때만** 남긴다. 다른 것이 섞여 있으면
# 코디네이터가 아직 할 일이 있다는 뜻이므로 계속 막아야 한다.
mkdir -p "$DEFER_DIR" 2>/dev/null
if [ "$BLOCK" -eq 1 ] && [ "$HUMAN_BLOCKED" = "1" ] && [ "$UNMEASURED" -eq 0 ]; then
  python3 -c 'import json,sys,datetime;print(json.dumps({"run":sys.argv[1],"reason":sys.argv[2],"at":datetime.datetime.now().astimezone().isoformat(timespec="seconds")},ensure_ascii=False))' \
    "$RUN" "소스 파일 교차 — PR 머지가 사람 몫이라 코디네이터가 지금 풀 수 없다" > "$DEFER_FILE" 2>/dev/null
  echo
  echo "⏸ 막힌 것이 **사람을 기다리는 사유 하나뿐**이다. 보류로 기록했다($DEFER_FILE)."
  echo "   PR 을 머지한 뒤 이 명령을 다시 돌려라. 그때 교차가 사라지면 --apply 로 회수한다."
else
  rm -f "$DEFER_FILE" 2>/dev/null
fi

if [ "$BLOCK" -gt 0 ]; then
  echo
  echo "⛔ 마감하지 마라. 위에서 막힌 것을 먼저 풀어라."
  echo "   보고가 상속본이면 그 워커의 worker_done 이 정본이다:"
  echo "     $ORCA_BIN orchestration inbox --limit 200 --json"
  exit 1
fi
if [ "$UNMEASURED" -gt 0 ]; then
  echo
  echo "⚠ 검사하지 못한 축이 있다. 「깨끗하다」가 아니라 **모른다**이다."
  echo "   그대로 회수하면 무엇을 잃는지 모른 채 잃는다."
  exit 2
fi

echo
if [ "$APPLY" = "1" ]; then
  echo "전부 통과 — 회수로 넘긴다."
  bash "$SELF/cleanup.sh" --apply --run "$RUN"
  exit $?
fi
echo "전부 통과. 실제로 회수하려면 --apply 를 붙여라(그때 먼저 아카이브한다):"
echo "    bash $SELF/wave-close.sh --run $RUN --base $BASE${MARKER:+ --marker $MARKER} --apply"
exit 0
