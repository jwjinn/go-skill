#!/usr/bin/env bash
# scope.test.sh — 「나눌지 말지」 판단의 대조군.
#
# ⭐ 이 스위트가 지키는 것 둘:
#   ① **두 방향이 다 있다** — 상한 이하면 「한 라운드로 충분」, 초과면 「나눠라」.
#      하나만 있으면 「항상 나눠라」와 구분되지 않는다.
#   ② **줄 세기가 헤더에 속지 않는다** — `+++`/`---` 를 변경 줄로 세면 파일 수만큼 부풀어
#      작은 diff 가 상한을 넘었다고 나온다(「탐지기를 먼저 의심하라」의 이 파일 판).
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
pass=0; fail=0
chk() { if printf '%s' "$2" | grep -q -- "$3"; then g=yes; else g=no; fi
  if [ "$g" = "$4" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1 → got=$g want=$4 ($3)"; fail=$((fail+1)); fi; }

W=$(mktemp -d)
# 변경 5줄(+4/-1) · 파일 2개짜리 작은 diff
# ⚠ 기대값을 손으로 세지 말고 도구 출력에서 확인해 적었다 — 처음에 6줄로 적었다가
#   틀렸다(`--- a/x.go` 는 부정형에 걸려 빠진다). 픽스처의 정답은 계산이 아니라 실측이다.
{ printf '%s\n' '--- a/x.go' '+++ b/x.go' '@@ -1,2 +1,4 @@' ' ctx' '+a' '+b' '-c'
  printf '%s\n' '--- a/y.ts' '+++ b/y.ts' '@@ -1,1 +1,3 @@' ' ctx' '+d' '+e'
} > "$W/small.patch"

echo "=== 두 방향"
out=$(CLAUDE_REVIEW_SPLIT_LINES=100 python3 "$SELF/_scope.py" "$W/small.patch" 2>&1)
chk "상한 이하 → 한 라운드로 충분"      "$out" '한 라운드로 충분하다' yes
chk "그때는 나누라고 하지 않는다"        "$out" '나누기를 권한다' no
out=$(CLAUDE_REVIEW_SPLIT_LINES=3 python3 "$SELF/_scope.py" "$W/small.patch" 2>&1)
chk "상한 초과 → 나누기를 권한다"        "$out" '나누기를 권한다' yes
chk "그때는 충분하다고 하지 않는다"      "$out" '한 라운드로 충분하다' no

echo "=== ⭐ 기본은 무제한이다(2026-09-13 사용자 결정: 「리뷰 상한은 없애죠」)"
out=$(env -u CLAUDE_REVIEW_SPLIT_LINES python3 "$SELF/_scope.py" "$W/small.patch" 2>&1)
chk "env 미설정 → 분할 상한이 없다"      "$out" '분할 상한이 없다' yes
chk "그때는 나누라고 하지 않는다"        "$out" '나누기를 권한다' no
chk "읽는 순서를 적으라고 말한다"        "$out" '어디부터 보라' yes
out=$(CLAUDE_REVIEW_SPLIT_LINES=0 python3 "$SELF/_scope.py" "$W/small.patch" 2>&1)
chk "0 을 명시해도 무제한"               "$out" '분할 상한이 없다' yes
out=$(CLAUDE_REVIEW_SPLIT_LINES=abc python3 "$SELF/_scope.py" "$W/small.patch" 2>&1)
chk "숫자가 아니면 무제한으로 떨어진다"  "$out" '분할 상한이 없다' yes

echo "=== 대조군: 숫자를 주면 종전대로 분할을 권한다(무제한이 판정을 통째로 삼키지 않는다)"
out=$(CLAUDE_REVIEW_SPLIT_LINES=3 python3 "$SELF/_scope.py" "$W/small.patch" 2>&1)
chk "숫자 3 → 나누기를 권한다"           "$out" '나누기를 권한다' yes
chk "그때는 「상한이 없다」고 하지 않는다" "$out" '분할 상한이 없다' no

echo "=== ⭐ 줄 세기가 헤더에 속지 않는다"
chk "변경 5줄로 센다(+++/--- 를 빼고)"   "$out" '변경 5줄 (+4 / -1)' yes
chk "파일 2개"                           "$out" '파일 2개' yes

echo "=== ⭐ 사보타주 — 헤더를 빼는 부정형을 지우면 부풀어 오른다"
sed -e 's/\^\\+(?!\\+\\+ )/^\\+/' -e 's/\^-(?!-- )/^-/' "$SELF/_scope.py" > "$W/sab.py"
sab=$(CLAUDE_REVIEW_SPLIT_LINES=3 python3 "$W/sab.py" "$W/small.patch" 2>&1)
# ⚠ 정답(5줄)과 비교해야 한다 — 사보타주 출력의 값을 적으면 그 값이 바뀔 때 조용히 통과한다
if printf '%s' "$sab" | grep -q '변경 5줄'; then
  echo "  FAIL 사보타주가 발화하지 않았다 — 이 테스트는 무엇도 지키지 않는다"; fail=$((fail+1))
else
  echo "  ok   ⭐ 사보타주하면 줄 수가 달라진다($(printf '%s' "$sab" | grep -o '변경 [0-9]*줄' | head -1))"
  pass=$((pass+1))
fi

echo "=== ⚠ 없는 파일·커밋 없음은 조용히 틀리지 않는다"
out=$(python3 "$SELF/_scope.py" "$W/없는것.patch" 2>&1)
chk "없는 diff 는 그렇게 말한다"          "$out" 'diff 파일이 없다' yes
out=$(CLAUDE_REVIEW_SPLIT_LINES=3 python3 "$SELF/_scope.py" "$W/small.patch" HEAD HEAD "$W" 2>&1)
chk "커밋이 0개면 제안하지 않는다고 말한다" "$out" '자를 곳을 제안하지 못한다' yes
chk "⚠ 파일 단위로 자르지 말라고 경고한다"  "$out" '파일 단위로 자르지 마라' yes

echo "=== ⚠⚠ 임계는 추측임을 스스로 밝힌다"
chk "머리말이 「외삽이지 측정이 아니다」라 적는다" "$(cat "$SELF/_scope.py")" '외삽이지 측정이 아니다' yes
chk "교정 경로를 가리킨다"                        "$(cat "$SELF/_scope.py")" 'verdict.sh' yes

rm -rf "$W"
echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
