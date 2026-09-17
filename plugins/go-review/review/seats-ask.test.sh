#!/usr/bin/env bash
# seats-ask.test.sh — `review-loop` **최초 실행 질문**의 파일 규약 대조군. 2026-09-17.
#
# # 무엇을 잠그나
#
# 사용자 지시(2026-09-17): 「스킬을 최초로 실행을 할때, 사용자에게 질문을 해서 … 각 모델에
# 어떠한 모델을 사용할 것인지를 사용자에게 질문을 받고 권고를 해줘.」
#
# 그 질문은 **프로젝트당 한 번**이어야 한다. 매 라운드 물으면 그것이 곧 사용자 정지이고,
# `go.md` 의 「승인된 계획 안에 사용자 답을 기다리는 지점이 있으면 안 된다」를 어긴다.
# 반대로 한 번 묻고 기록이 안 남으면 **매번 묻게 된다.** 양방향을 다 잠근다.
#
# ⚠ 지시문(`review-loop.md`)은 실행되지 않으므로 테스트할 수 없다. 테스트할 수 있는 것은
#   그 지시문이 **읽고 쓰는 파일의 규약**이다 — 판별 조건과 게이트 우선순위.
#
# # 축 셋
#
#   ① 기록이 없으면 「처음이다」(묻는다)
#   ② 기록이 있으면 「이미 물었다」(안 묻는다)
#   ③ ⭐ 자리 값이 `local` 인데 자격이 없으면 **P5 의 게이트가 먼저 발화한다** —
#      질문의 답이 그것을 덮지 않는다(사용자가 골라도 자격 없으면 그 자리는 빈다)
#
# 판정: 0 통과 · 1 실패 · 2 검사 자체가 불가(파이썬·대상 파일 부재)
set -uo pipefail

SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SELF/.." && pwd)
pass=0; fail=0

command -v python3 >/dev/null 2>&1 || { echo "python3 이 없다 — 검사 불가"; exit 2; }
[ -f "$ROOT/review/_config.py" ] || { echo "_config.py 가 없다 — 검사 불가"; exit 2; }

chk() { # chk <라벨> <실제> <기대>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1  → got=$2 want=$3"; fail=$((fail+1)); fi
}

# 「물었나」 판별 — review-loop.md §②-b 가 쓰는 것과 같은 조건이다.
asked() { [ -f "$1/.claude/review/seats-answered.json" ] && echo yes || echo no; }

mkproj() { # mkproj → 프로젝트 루트를 stdout 으로
  local d; d=$(mktemp -d)
  mkdir -p "$d/.claude/review/eval/cases"
  printf 'CASE-A\n' > "$d/.claude/review/eval/cases/project.jsonl"
  printf '%s' "$d"
}

echo "=== ① 기록이 없으면 묻는다 ==="
P=$(mkproj)
chk "① seats-answered.json 이 없으면 asked=no" "$(asked "$P")" "no"
rm -rf "$P"

echo "=== ② 기록이 있으면 안 묻는다 ==="
P=$(mkproj)
printf '{"answered_at":"2026-09-17T00:00:00+09:00","seats":{"blind":"claude"}}' \
  > "$P/.claude/review/seats-answered.json"
chk "② 기록이 있으면 asked=yes" "$(asked "$P")" "yes"
rm -rf "$P"

echo "=== ③ 질문의 답이 자격 게이트를 덮지 않는다 ==="
P=$(mkproj)
# 사용자가 blind 자리에 local 을 골랐다고 가정하고 그대로 기록·구성에 썼다.
printf '{"answered_at":"2026-09-17T00:00:00+09:00","seats":{"blind":"local"}}' \
  > "$P/.claude/review/seats-answered.json"
printf '{"preset":"custom","seats":{"contract":"claude","blind":"local","cross":"none","merger":"claude"}}' \
  > "$P/.claude/review/config.json"
# 자격 기록은 **없다**. 게이트가 먼저 발화해야 한다.
OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$ROOT/review/_config.py" "$P/.claude/review/config.json" 2>&1)
if printf '%s' "$OUT" | grep -q "로컬 모델 자리를 비웠다"; then g=yes; else g=no; fi
chk "③ 자격 없는 local 은 답이 있어도 비워진다" "$g" "yes"
# 그리고 그 자리가 실제로 비었는지(출력의 자리 표에서)
if printf '%s' "$OUT" | grep -qE "blind +—"; then e=yes; else e=no; fi
chk "③ 자리 표에도 비어 있다고 나온다" "$e" "yes"
rm -rf "$P"

echo "=== ④ ⭐ 대조군 — 자격이 있으면 그 자리가 남는다(③이 무조건 참이 아니다) ==="
P=$(mkproj)
printf '{"preset":"custom","seats":{"contract":"claude","blind":"local","cross":"none","merger":"claude"}}' \
  > "$P/.claude/review/config.json"
# 지금 케이스 파일의 해시로 합격 기록을 만든다.
H=$(CLAUDE_PROJECT_DIR="$P" python3 -c "
import sys; sys.path.insert(0,'$ROOT/review'); import _config
print(_config.cases_hash('$P'))
")
printf '{"qualified":true,"cases_hash":"%s","model":"t","why":"픽스처"}' "$H" \
  > "$P/.claude/review/local-qualified.json"
OUT=$(CLAUDE_PROJECT_DIR="$P" python3 "$ROOT/review/_config.py" "$P/.claude/review/config.json" 2>&1)
if printf '%s' "$OUT" | grep -q "로컬 모델 자리를 비웠다"; then g=yes; else g=no; fi
chk "④ 대조군: 자격이 있으면 게이트가 발화하지 않는다" "$g" "no"
if printf '%s' "$OUT" | grep -qE "blind +local"; then e=yes; else e=no; fi
chk "④ 대조군: 자리가 local 로 남는다" "$e" "yes"
rm -rf "$P"

echo
echo "검사 $((pass+fail))개 · 통과 $pass · 실패 $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
