#!/usr/bin/env bash
# deps-check.sh — 이 플러그인이 **지금 이 기계에서 실제로 돌 수 있는지** 센다.
#
# ⭐ 왜 있나: 설치는 파일 복사라 언제나 성공한다. 그런데 이 체인은 외부 도구 위에 서 있고,
#   그중 `jq` 가 없으면 Stop 게이트 세 축이 **조용히 통과한다**(재현 완료 · `_deps.sh` 머리말).
#   「설치했다」와 「돌아간다」가 다르다는 것을 이 스크립트가 개수로 말한다.
#
# ⚠ 초록 한 줄로 끝내지 않는다 — **무엇을 몇 개 셌는지** 출력한다. 「그 축을 아예 안 봤다」가
#   가장 조용한 고장이고, 개수가 없으면 그것을 구분할 수 없다.
#
# 사용:
#   bash scripts/deps-check.sh            # 있는지 본다(빠르다)
#   bash scripts/deps-check.sh --deep     # + codex 를 **실제로 한 번 불러** 돌아가는지 본다
#   bash scripts/deps-check.sh --quiet     # 판정만(종료코드)
#
# 종료코드: 0 전부 충족 · 1 선택 도구 부재(체인은 돈다) · 2 ⛔ 필수 부재(축이 죽는다)
set -u

SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SELF/.." && pwd)
. "$ROOT/hooks/_deps.sh" 2>/dev/null || {
  echo "⛔ hooks/_deps.sh 를 읽지 못했다 — 플러그인 설치가 깨졌다($ROOT)" >&2
  exit 2
}

DEEP=0; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --deep)  DEEP=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
    *) echo "deps-check.sh: 모르는 인자 $1" >&2; exit 64 ;;
  esac
  shift
done

n_ok=0; n_warn=0; n_bad=0
OUT=""
say()  { OUT="${OUT}$1
"; }
pass() { n_ok=$((n_ok+1));   say "  ✅ $1"; }
warns(){ n_warn=$((n_warn+1)); say "  ⚠  $1"; }
fails(){ n_bad=$((n_bad+1));  say "  ⛔ $1"; }

ver_of() {   # <도구> — 한 줄짜리 버전 문자열(못 읽으면 빈 값)
  case "$1" in
    bash)    printf '%s' "${BASH_VERSION:-}" ;;
    git)     git --version 2>/dev/null | head -1 ;;
    jq)      jq --version 2>/dev/null | head -1 ;;
    python3) python3 -V 2>&1 | head -1 ;;
    codex)   codex --version 2>/dev/null | head -1 ;;
    timeout) printf '%s' "$(deps_timeout_cmd)" ;;
    *) printf '' ;;
  esac
}

say "── 필수 ────────────────────────────────────────────────────────────"
for c in $(deps_required_list); do
  if command -v "$c" >/dev/null 2>&1; then
    pass "$(printf '%-8s %s' "$c" "$(ver_of "$c")")"
  else
    fails "$(printf '%-8s 없다 — %s' "$c" "$(deps_role "$c")")"
    say "        설치: $(deps_hint "$c")"
  fi
done

say "── 선택 ────────────────────────────────────────────────────────────"
# timeout 은 이름이 둘이라 따로 본다(`timeout` · `gtimeout`).
tc=$(deps_timeout_cmd)
if [ -n "$tc" ]; then
  pass "$(printf '%-8s %s 로 쓴다' 'timeout' "$tc")"
else
  warns "$(printf '%-8s 없다 — %s' 'timeout' "$(deps_role timeout)")"
  say "        설치: $(deps_hint timeout)"
fi
if command -v codex >/dev/null 2>&1; then
  pass "$(printf '%-8s %s' 'codex' "$(ver_of codex)")"
else
  warns "$(printf '%-8s 없다 — %s' 'codex' "$(deps_role codex)")"
  say "        설치: $(deps_hint codex)"
fi

# ── ⭐ 있음 ≠ 돌아감 ────────────────────────────────────────────────────────
#
# ⚠⚠ 실측으로 겪었다(codex 0.152.0): 설치돼 있는데 기본 모델이 CLI 업그레이드를 요구하거나
#   계정이 그 모델 계열을 지원하지 않아 **한 줄도 못 돌았다.** 그런데 구성 해석은
#   `command -v codex` 만 보므로 전 자리를 codex 로 둔 채 진행했고, 리뷰가 0회였다.
#   그래서 「있다」와 「돌아간다」를 다른 검사로 나눈다 — 후자는 느리므로 `--deep` 에 둔다.
if [ "$DEEP" -eq 1 ]; then
  say "── 깊은 확인(--deep) ───────────────────────────────────────────────"
  if command -v codex >/dev/null 2>&1; then
    tmpd=$(mktemp -d)
    if CLAUDE_CODEX_TIMEOUT=90 bash "$ROOT/review/codex-ro.sh" --out "$tmpd/o.txt" --err "$tmpd/e.txt" \
         'Answer with exactly one word: ok' >/dev/null 2>&1 && [ -s "$tmpd/o.txt" ]; then
      pass "codex 실제 호출 성공(읽기 전용 래퍼 경유)"
    else
      fails "codex 가 설치돼 있는데 **호출이 실패했다** — 이 상태로는 codex 자리의 리뷰가 0회다"
      say "        에러: $(head -3 "$tmpd/e.txt" 2>/dev/null | tr '\n' ' ')"
      say "        흔한 원인: \`codex login\` 미완료 · 기본 모델을 계정이 지원하지 않음 · CLI 업그레이드 요구"
    fi
    rm -rf "$tmpd"
  else
    warns "codex 가 없어 깊은 확인을 건너뛴다 — **미검사이지 통과가 아니다**"
  fi
fi

# ── 구성이 실제로 해석되나 ──────────────────────────────────────────────────
say "── 리뷰 구성 ───────────────────────────────────────────────────────"
if command -v python3 >/dev/null 2>&1; then
  seats=$(python3 "$ROOT/review/_config.py" 2>/dev/null | grep -oE 'CLAUDE_REVIEW_REVIEWERS=[^ ]*' | head -1)
  if [ -n "$seats" ]; then
    pass "리뷰 자리: ${seats#CLAUDE_REVIEW_REVIEWERS=}"
  else
    fails "구성을 해석하지 못했다 — \`python3 review/_config.py\` 를 직접 돌려 봐라"
  fi
else
  fails "python3 이 없어 구성을 해석할 수 없다(위 필수 항목 참조)"
fi

total=$((n_ok + n_warn + n_bad))
head="[의존성 점검] ${total}검사 · 충족 ${n_ok} · 경고 ${n_warn} · 부재 ${n_bad}"

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n%s' "$head" "$OUT"
  if [ "$n_bad" -gt 0 ]; then
    printf '\n⛔ 필수 도구가 없다. **설치돼 있어도 게이트가 아무것도 막지 않는다** — 위 설치 명령을 먼저 돌려라.\n'
  elif [ "$n_warn" -gt 0 ]; then
    printf '\n⚠ 체인은 돈다. 다만 위 항목만큼 기능이 줄고, 그 사실이 라운드 보고에 적혀야 한다.\n'
  else
    printf '\n✅ 전부 충족. `go-review:plan` → `go-review:go` → `go-review:review-loop` 로 시작해라.\n'
  fi
fi

[ "$n_bad" -gt 0 ] && exit 2
[ "$n_warn" -gt 0 ] && exit 1
exit 0
