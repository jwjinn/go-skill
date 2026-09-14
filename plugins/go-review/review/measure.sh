#!/usr/bin/env bash
# measure.sh — 리뷰 파이프라인이 비용을 하는가를 rounds.jsonl 로 계산한다.
# 사용: bash <플러그인>/review/measure.sh [rounds.jsonl 경로]
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || printf '.')
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DEFAULT="${CLAUDE_REVIEW_HISTORY_DIR:-$ROOT/docs/리뷰-이력}/rounds.jsonl"
exec python3 "$SELF/_measure.py" "${1:-$DEFAULT}"
