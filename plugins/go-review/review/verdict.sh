#!/usr/bin/env bash
# verdict.sh — 리뷰 발견에 **사람의 판정**을 붙인다.
#
# ⭐ 이것이 측정의 병목이다. 발견 수는 자동으로 쌓이지만 「그중 몇 건이 옳았나」는
#   사람만 안다. 이 값이 없으면 measure.sh 는 정밀도를 계산하지 않고 그 사실을 말한다.
#
# ⭐ 판정 출처가 둘이고 **그 구분을 지우지 않는다**:
#   기본(플래그 없음) = `judged_by=user` — 사람이 직접 준 판정.
#   `--auto`          = `judged_by=auto` — 구현자·병합자가 반영 결과대로 붙인 판정.
#
# ⚠ `--auto` 는 사용자 결정으로 열렸다(2026-09-03): 「오탐 판정에 동의를 받지 마라 —
#   codex 가 판정하는 영역이다. 히스토리를 남기고 go 가 끝나면 알려 달라.」
#   사람의 검증층이 라운드 단위에서 **최종 결과물 단위**로 옮겨 간 것이지 사라진 것이 아니다.
#   그래서 자동 판정만으로 낸 정밀도는 **자기 채점**이고, 인용할 때 그 사실과 함께 인용해야 한다.
#   `history.sh` 가 라운드별로 그 출처를 나눠 보여준다.
#
# 사용:
#   bash <플러그인>/review/verdict.sh                  # 미판정 전부 보기
#   bash <플러그인>/review/verdict.sh <라운드>          # 그 라운드 미판정 보기
#   bash <플러그인>/review/verdict.sh <라운드> mf1=a mf2=r:오탐 c3=d      # 사람 판정
#   bash <플러그인>/review/verdict.sh --auto <라운드> mf1=a mf2=r:...     # 자동 판정(반영 결과대로)
#
#   a=결함이었다 · r=결함이 아니었다 · d=타당하나 지금 범위 밖(오탐 아님)
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || printf '.')
OUT="${CLAUDE_REVIEW_HISTORY_DIR:-$ROOT/docs/리뷰-이력}"
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

exec python3 "$SELF/_verdict.py" "$OUT/findings.jsonl" "$@"
