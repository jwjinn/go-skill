#!/usr/bin/env bash
# doctor.sh 대조군.
#
# ⭐ 이 스위트가 지키는 것은 「초록이 나온다」가 아니라 **「고장을 심으면 잡는다」** 다.
#   진단기가 죽어 있으면 그 초록은 「돌았다」가 아니라 「실패하지 않았다」이고,
#   이 레포는 그 부류를 여러 번 밟았다(trivy 미실행 · CSS 가 CI 밖 · 완주 게이트 3일 무장해제).
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
H="$SELF/doctor.sh"
pass=0; fail=0
chk() { # $1=label $2=출력 $3=패턴 $4=yes|no
  if printf '%s' "$2" | grep -q -- "$3"; then got=yes; else got=no; fi
  if [ "$got" = "$4" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1  → got=$got want=$4  (패턴: $3)"; fail=$((fail+1)); fi
}
mkproj() { # 깨끗한 프로젝트 하나
  P=$(mktemp -d); mkdir -p "$P/.claude"
  printf '{"hooks":{}}' > "$P/.claude/settings.json"
}
run() { CLAUDE_PROJECT_DIR="$P" bash "$H" 2>&1; }
clean() { rm -rf "$P"; }

STAMP_GLOB="${TMPDIR:-/tmp}/claude-go-suites-ok"*
rm -f $STAMP_GLOB 2>/dev/null || true

echo "=== 정상 프로젝트"
mkproj
out=$(run)
chk "훅 2중 등록 없음을 확인한다"      "$out" '훅 등록 5/5' yes
chk "로컬 사본 0개를 확인한다"          "$out" '로컬 사본 0개' yes
chk "결함 0"                            "$out" '결함 0' yes
chk "⭐ 호출 이름을 말한다(관찰 O-1)"   "$out" '호출:' yes
clean

echo "=== ⭐ 사보타주 ① 훅 2중 등록 — 잡아야 한다"
mkproj
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash \\"$CLAUDE_PROJECT_DIR/.claude/hooks/plan-file-gate.sh\\""}]}]}}' > "$P/.claude/settings.json"
out=$(run)
chk "2중 등록을 이름으로 지목한다"      "$out" 'plan-file-gate' yes
chk "결함으로 센다"                      "$out" '결함 1' yes
clean

echo "=== ⭐ 사보타주 ② 로컬 사본 — 잡아야 한다"
mkproj; mkdir -p "$P/.claude/commands"; printf 'x\n' > "$P/.claude/commands/go.md"
out=$(run)
chk "같은 이름의 로컬 사본을 지목한다"  "$out" 'commands/go.md' yes
chk "「정본이 둘이다」라고 말한다"       "$out" '정본이 둘' yes
clean

echo "=== ⭐ 사보타주 ③ 계획 소유자 불일치 — 잡아야 한다"
mkproj
printf '# t\n\n작업 위치: /somewhere/else\n\n## P0\n- [ ] 하나\n' > "$P/.claude/plan-active.md"
out=$(run)
chk "소유자 불일치를 지목한다"          "$out" '작업 위치가 다르다' yes
clean

echo "=== 계획이 자기 것이면 통과한다(사보타주의 반대 방향)"
mkproj
printf '# t\n\n작업 위치: %s\n\n## P0\n- [ ] 하나\n- [x] 둘\n' "$P" > "$P/.claude/plan-active.md"
out=$(run)
chk "소유자 일치 + 미완료 수를 센다"    "$out" '미완료 1개' yes
chk "소유자 불일치라 하지 않는다"        "$out" '작업 위치가 다르다' no
clean

echo "=== 미해결 리뷰는 경고한다"
mkproj
printf '# 리뷰 반영\n- [ ] [blocker] a.go:1 — 뭔가\n' > "$P/.claude/review-active.md"
out=$(run)
chk "미해결 지적 수를 말한다"            "$out" '미해결 리뷰 지적 1건' yes
clean

echo "=== 스탬프"
mkproj
out=$(run)
chk "스탬프가 없으면 경고한다"          "$out" '통과 표시 없음' yes
CLAUDE_PROJECT_DIR="$P" bash "$H" --stamp >/dev/null 2>&1
out=$(run)
chk "--stamp 뒤에는 통과한다"            "$out" '통과했다는 표시' yes
chk "그때는 경고가 아니다"               "$out" '통과 표시 없음' no
chk "⭐ 「통과했다」가 아니라 **자기신고**라고 말한다" "$out" '자기신고' yes
# ⚠ 기대값에 숫자를 박지 마라 — 스위트가 하나 늘 때마다 이 줄이 깨졌다(실제로 13→14 에서
#   깨졌다). 「세어서 말한다」를 재려면 **여기서도 세어야** 한다.
n_suites=$(ls "$SELF"/*.test.sh "$SELF/../review"/*.test.sh "$SELF/../review/eval"/*.test.sh "$SELF/../scripts"/*.test.sh 2>/dev/null | wc -l | tr -d ' ')
chk "⭐ 스위트 수를 세어 말한다(문자열 고정이 아니다)" "$out" "게이트 ${n_suites}스위트" yes
clean

echo "=== --hook 모드(SessionStart)"
mkproj
CLAUDE_PROJECT_DIR="$P" bash "$H" --stamp >/dev/null 2>&1
out=$(CLAUDE_PROJECT_DIR="$P" bash "$H" --hook 2>&1)
chk "⭐ 전부 통과면 **조용하다**(소음이면 사람이 훅을 끈다)" "$out" '.' no
mkdir -p "$P/.claude/commands"; printf 'x\n' > "$P/.claude/commands/go.md"
out=$(CLAUDE_PROJECT_DIR="$P" bash "$H" --hook 2>&1)
chk "결함이 있으면 JSON 으로 말한다"    "$out" 'systemMessage' yes
clean
rm -f $STAMP_GLOB 2>/dev/null || true

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
