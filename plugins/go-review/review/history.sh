#!/usr/bin/env bash
# history.sh — 리뷰 라운드 히스토리를 표로 낸다. `/go` **종료 보고**의 「리뷰」 절이 이것이다.
#
# ⭐ 사용자 결정(2026-09-03): 「go 는 최대한 AI-Native 하게 — 협의로 플랜을 같이 만들면
#   go 가 그 협의문 기준으로 개발·리뷰·수정을 계속하고, 끝났을 때 최종 보고를 받는다.」
#   ⇒ 사람의 검증이 라운드마다가 아니라 **끝의 보고 한 자리**로 옮겨 갔다. 그 보고가 부실하면
#   통제가 통째로 약해지므로, 이 절만은 모델의 산문이 아니라 **기계 출력**이어야 한다.
#
# 사용:
#   bash <플러그인>/review/history.sh              # 전체
#   bash <플러그인>/review/history.sh 20260903     # 그 접두의 라운드만(오늘 것만)
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || printf '.')
OUT="${CLAUDE_REVIEW_HISTORY_DIR:-$ROOT/docs/리뷰-이력}"
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$SELF/_history.py" "$OUT" "$@"
