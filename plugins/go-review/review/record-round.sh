#!/usr/bin/env bash
# record-round.sh — 리뷰 라운드 하나를 **커밋되는 히스토리**로 승격한다.
#
# 왜 두 층인가:
#   프로젝트 `.claude/review/runs/<ts>/` 원본은 gitignore 다 — 라운드마다 diff.patch 만 수십~수백 KB 라
#   전부 커밋하면 레포가 소음으로 불어나고, 소음이 되면 아무도 안 읽는다.
#   그래서 원본은 디버깅용 일회성으로 두고, **사람이 읽는 요약**과 **기계가 세는 한 줄**만 남긴다.
#
# ⭐ JSONL 이 이 도구의 본체다. 일기가 아니라 **측정**이 목적이고, 재려는 것은 하나다 —
#   **리뷰어를 하나 더 붙이는 값이 그 비용을 하는가.**
#   그래서 must_fix 마다 **누가 발견했는지**를 저장한다. 그것만 있으면 나중에
#   `measure.sh` 가 절제(ablation)를 계산한다: "이 리뷰어를 빼면 무엇을 놓쳤나".
#   근거 문헌(교차 모델 리뷰 비대칭)은 프리프린트이므로 **우리 코드에서 직접 재는 것**이 답이다.
#
# 사용:
#   bash <플러그인>/review/record-round.sh <라운드 디렉토리> ["한 줄 목표"] ["토큰 스펙"]
#   토큰 스펙 예: "claude-contract=102471,claude-blind=118861,review-merger=294522"
#     · codex 는 codex.err 에서 **자동 파싱**한다(그 파일이 남아 있으면).
#     · 안 주면 null 이다 — 0 으로 채우지 마라. 「안 썼다」와 「안 쟀다」는 다르다.
set -euo pipefail

ROUND="${1:?라운드 디렉토리를 인자로 줘라 (예: .claude/review/runs/20260902-103044)}"
GOAL="${2:-}"
TOKENS="${3:-}"
MODELS="${4:-}"   # "reviewers=claude-opus-5,codex=gpt-5.2" — codex 는 codex.err 에서 자동 파싱
[ -d "$ROUND" ] || { echo "라운드 디렉토리가 없다: $ROUND" >&2; exit 1; }
[ -f "$ROUND/merged.json" ] || { echo "merged.json 이 없다 — 병합을 먼저 끝내라: $ROUND" >&2; exit 1; }

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || printf '.')
OUT="${CLAUDE_REVIEW_HISTORY_DIR:-$ROOT/docs/리뷰-이력}"
mkdir -p "$OUT"

RID=$(basename "$ROUND")
MONTH="${RID:0:4}-${RID:4:2}"
DAY="${RID:0:4}-${RID:4:2}-${RID:6:2}"

SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
python3 "$SELF/_record.py" "$ROUND" "$OUT" "$RID" "$DAY" "$GOAL" "$TOKENS" "$MODELS"

# ── 사람이 읽는 월별 기록 ─────────────────────────────────────────────────────
MD="$OUT/$MONTH.md"
[ -f "$MD" ] || cat > "$MD" <<HDR
# 리뷰 이력 $MONTH

각 절이 리뷰 라운드 하나다. 원본(diff·리뷰어별 JSON)은 \`.claude/review/runs/<라운드>/\` 에
있으나 **gitignore** 라 이 저장소에는 없다 — 여기 남는 것은 요약과 판단이다.
기계가 세는 한 줄은 [rounds.jsonl](rounds.jsonl) 에 있고,
\`bash <플러그인>/review/measure.sh\` 가 그것으로 **비용 대비 값**을 계산한다.

HDR

if ! grep -q "라운드 \`$RID\`" "$MD" 2>/dev/null; then
  {
    printf '\n---\n\n## %s — 라운드 `%s`\n\n' "$DAY" "$RID"
    [ -n "$GOAL" ] && printf '**목표**: %s\n\n' "$GOAL"
    if [ -f "$ROUND/merged.md" ]; then
      sed -e 's/^# /### /' -e 's/^## /#### /' "$ROUND/merged.md"
    else
      printf '⚠ merged.md 가 없다 — 병합 산출물 없이 기록됐다.\n'
    fi
    printf '\n<sub>원본: `%s` (gitignore)</sub>\n' "$ROUND"
  } >> "$MD"
  echo "  기록   $MD"
else
  echo "  기록   $MD (이미 이 라운드가 있다 — 본문은 건드리지 않았다)"
fi

echo
echo "⛔ 남은 일 — **사람만 할 수 있다**: 발견마다 판정을 붙여라."
echo "     bash \"$SELF/verdict.sh\" $RID"
echo "   그것 없이는 「몇 건 나왔나」까지만 알 수 있고 「그중 몇 건이 옳았나」는 알 수 없다."
echo "   측정: bash \"$SELF/measure.sh\""
