#!/usr/bin/env bash
# goal-echo.sh 대조군. 실행: bash <플러그인>/hooks/goal-echo.test.sh
#
# 이 훅은 **매 프롬프트마다** 돈다. 그래서 「말해야 할 때」보다 **「조용해야 할 때」**가 더 중요하다 —
# 오탐이 잦으면 사람이 훅을 꺼 버리고, 꺼진 훅은 없는 훅이다.
set -u

HOOK="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/goal-echo.sh"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
ng(){ printf '  NG   %s  (%s)\n' "$1" "$2"; fail=$((fail+1)); }

NOW=$(date +%s)
setup(){ T=$(mktemp -d); mkdir -p "$T/.claude"; SESS="${1:-s}"; }
setmtime(){ python3 -c "import os,sys; os.utime(sys.argv[1],(int(sys.argv[2]),int(sys.argv[2])))" "$1" "$2"; }
run(){ printf '{"session_id":"%s","prompt":"뭐 좀 해줘"}' "$SESS" \
       | CLAUDE_PROJECT_DIR="$T" bash "$HOOK" 2>/dev/null; }
cleanup(){ rm -rf "$T"; }

PLAN_OK='# 제목

## 목표 계약
원 요청: "리뷰 루프를 붙여줘"
수용 기준:
  - /review-loop 가 세 리뷰어를 병렬로 띄운다
범위 밖: UI 변경(요청에 없다)

## P0
- [ ] P0-1 아직
- [x] P0-2 끝
'

# ⚠ 완료판을 `${PLAN_OK//.../...}` 로 만들지 마라. bash 패턴 치환에서 `[ ]` 는 **글로브
#   문자클래스**라 리터럴 `- [ ]` 를 매치하지 못한다 — 치환이 조용히 실패해 두 픽스처가
#   같아지고, 그러면 「완료면 조용하다」와 사보타주 대조군이 **둘 다 거짓으로 통과**한다.
#   (실제로 이 파일을 처음 쓸 때 그렇게 됐고, 사보타주 검사가 그것을 잡았다.)
PLAN_DONE='# 제목

## 목표 계약
원 요청: "리뷰 루프를 붙여줘"
범위 밖: UI 변경(요청에 없다)

## P0
- [x] P0-1 끝
- [x] P0-2 끝
'

echo "=== 말해야 하는 경우"
setup s1; printf '%s' "$PLAN_OK" > "$T/.claude/plan-active.md"; setmtime "$T/.claude/plan-active.md" "$NOW"
out=$(run)
printf '%s' "$out" | grep -q '리뷰 루프를 붙여줘' && printf '%s' "$out" | grep -q '범위 밖' \
  && ok "미완료 있음 → 원 요청과 범위 밖을 되읽는다" || ng "계약 출력" "$out"
printf '%s' "$out" | grep -q '남은 항목 1/2' && ok "남은 항목 수를 센다" || ng "잔여 계수" "$out"
cleanup

setup s2; printf '# t\n\n## P0\n- [ ] 계약 없는 계획\n' > "$T/.claude/plan-active.md"
setmtime "$T/.claude/plan-active.md" "$NOW"
run | grep -q '「## 목표 계약」 절이 없다' && ok "계약 절 부재 → 그 사실을 말한다" || ng "계약 부재 경고" "$(run)"
cleanup

echo "=== 조용해야 하는 경우(이쪽이 더 중요하다)"
setup s3; out=$(run); [ -z "$out" ] && ok "계획 파일 없음 → 무출력" || ng "계획 없음" "$out"; cleanup

setup s4; printf '%s' "$PLAN_DONE" > "$T/.claude/plan-active.md"
setmtime "$T/.claude/plan-active.md" "$NOW"
out=$(run); [ -z "$out" ] && ok "전부 완료 → 무출력(재정렬할 목표가 없다)" || ng "완료 계획" "$out"; cleanup

setup s5; printf '%s' "$PLAN_OK" > "$T/.claude/plan-active.md"
setmtime "$T/.claude/plan-active.md" "$((NOW - 60*60*72))"   # 72시간 전 > 기본 48h
out=$(run); [ -z "$out" ] && ok "72h 지난 잔재 → 무출력(자동 만료)" || ng "낡은 계획" "$out"; cleanup

setup s6; printf '# t\n\n## 목표 계약\n원 요청: "x"\n\n## P0\n체크박스가 없다\n' > "$T/.claude/plan-active.md"
setmtime "$T/.claude/plan-active.md" "$NOW"
out=$(run); [ -z "$out" ] && ok "체크박스 0개 → 무출력(판정 불가)" || ng "체크박스 0" "$out"; cleanup

echo "=== ⭐ 긴 계약의 절단 — 「범위 밖」은 절대 잃지 않는다(리뷰 MF1)"
# 이 케이스가 없어서 head -12 가 「범위 밖」을 통째로 잘라 내는 것을 못 잡았다.
# go.md 규약대로 쓴 실제 계약은 원 요청 인용만 8줄이 넘는다 — 그 모양을 그대로 만든다.
setup s7
{
  printf '# 제목\n\n## 목표 계약\n원 요청: "1줄\n2줄\n3줄\n4줄\n5줄\n6줄\n7줄\n8줄\n9줄\n10줄"\n'
  printf '수용 기준:\n  - 기준1\n  - 기준2\n  - 기준3\n  - 기준4\n  - 기준5\n'
  printf '범위 밖: UI 변경(요청에 없다)\n\n## P0\n- [ ] 아직\n'
} > "$T/.claude/plan-active.md"
setmtime "$T/.claude/plan-active.md" "$NOW"

# ⭐ 상한을 12 로 주면 **옛 `head -12` 와 정확히 같은 조건**이다 — 그때 「범위 밖」이 잘렸다.
#   같은 조건에서 이제는 살아남는지가 이 수정의 진짜 대조군이다.
run12(){ printf '{"session_id":"%s","prompt":"x"}' "$SESS" \
         | CLAUDE_PROJECT_DIR="$T" CLAUDE_GOAL_ECHO_MAX_LINES=12 bash "$HOOK" 2>/dev/null; }
out=$(run12)
printf '%s' "$out" | grep -q '범위 밖' \
  && ok "옛 head -12 조건에서도 「범위 밖」이 살아남는다" || ng "범위 밖 절단" "$out"
printf '%s' "$out" | grep -q '줄 생략' \
  && ok "잘렸으면 잘렸다고 말한다(조용한 절단 금지)" || ng "절단 표시" "$out"
[ "$(printf '%s' "$out" | grep -c '범위 밖')" = "1" ] \
  && ok "범위 밖을 두 번 찍지 않는다" || ng "중복 출력" "$(printf '%s' "$out" | grep -c '범위 밖')"

# 기본 상한(24)에서는 이 17줄 계약이 통째로 들어가야 한다 — 절단은 예외이지 기본이 아니다
out=$(run)
printf '%s' "$out" | grep -q '줄 생략' \
  && ng "기본 상한에서 불필요한 절단" "$out" || ok "17줄 계약은 기본 상한에서 통째로 들어간다"
cleanup

setup s8   # 짧은 계약은 절단 표시가 없어야 한다(오탐 방지)
printf '%s' "$PLAN_OK" > "$T/.claude/plan-active.md"; setmtime "$T/.claude/plan-active.md" "$NOW"
out=$(run); printf '%s' "$out" | grep -q '줄 생략' \
  && ng "짧은 계약에 절단 표시" "$out" || ok "짧은 계약은 절단 표시 없음"
cleanup

echo "=== 경로 재지정(CLAUDE_PLAN_FILE) — 한 트리에서 세션을 나누는 유일한 수단"
setup s9
printf '# 공용\n\n## 목표 계약\n원 요청: "남의계획"\n\n## P\n- [ ] 남의 미완료\n' > "$T/.claude/plan-active.md"
printf '# 내 것\n\n## 목표 계약\n원 요청: "내계획"\n\n## P\n- [ ] 내 미완료\n' > "$T/mine.md"
setmtime "$T/.claude/plan-active.md" "$NOW"; setmtime "$T/mine.md" "$NOW"
out=$(run)   # override 없음 → 공용을 본다
printf '%s' "$out" | grep -q '남의계획' && ok "override 없으면 공용 계획을 본다" || ng "공용 폴백" "$out"
out=$(printf '{"session_id":"%s","prompt":"x"}' "$SESS" \
      | CLAUDE_PROJECT_DIR="$T" CLAUDE_PLAN_FILE="$T/mine.md" bash "$HOOK" 2>/dev/null)
printf '%s' "$out" | grep -q '내계획' && ! printf '%s' "$out" | grep -q '남의계획' \
  && ok "override 를 주면 내 계획만 되읽는다" || ng "override 격리" "$out"
cleanup

echo "=== 훅 고장은 통과"
out=$(printf '' | bash "$HOOK" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "빈 stdin → exit 0·무출력" || ng "빈 stdin" "rc=$rc"
out=$(printf 'not json' | bash "$HOOK" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "깨진 stdin → exit 0" || ng "깨진 stdin" "rc=$rc"

echo "=== ⭐ G9 확정 결정 재주입"
PLAN_DEC="$PLAN_OK"'
## 결정 필요(승인 전)
- [x] Q1 [선택] 목업 ① → 답: B 질문 우선
| Q2 | 머지 주체 | 사람 | 답 | 닫힘 · 사람이 한다 |
'
setup s11; printf '%s' "$PLAN_DEC" > "$T/.claude/plan-active.md"; setmtime "$T/.claude/plan-active.md" "$NOW"
out=$(run)
printf '%s' "$out" | grep -q '확정 결정' && ok "닫힌 결정을 되읽는다" || ng "확정 결정 절" "$out"
printf '%s' "$out" | grep -q 'Q1.*B 질문 우선' && ok "체크박스형 닫힌 항목이 보인다" || ng "체크박스형" "$out"
printf '%s' "$out" | grep -q 'Q2.*사람이 한다' && ok "표형 닫힌 항목이 보인다" || ng "표형" "$out"
printf '%s' "$out" | grep -q '열린 항목' && ng "열린 것이 없는데 열림 경고" "$out" || ok "열린 항목이 없으면 경고 없음"
cleanup
PLAN_DEC_OPEN="$PLAN_OK"'
## 결정 필요(승인 전)
- [ ] Q1 [선택] 목업 ① — 아직
'
setup s12; printf '%s' "$PLAN_DEC_OPEN" > "$T/.claude/plan-active.md"; setmtime "$T/.claude/plan-active.md" "$NOW"
out=$(run)
printf '%s' "$out" | grep -q '열린 항목 1건.*승인 뒤에도' && ok "승인 뒤 열린 결정을 이상으로 알린다" || ng "열린 결정 경고" "$out"
cleanup
setup s13; printf '%s' "$PLAN_OK" > "$T/.claude/plan-active.md"; setmtime "$T/.claude/plan-active.md" "$NOW"
out=$(run)
printf '%s' "$out" | grep -q '확정 결정' && ng "절이 없는데 확정 결정을 찍음" "$out" || ok "결정 절이 없으면 조용하다"
cleanup

echo "=== ⭐ R1 리뷰 반영 — 3열 결정표도 되읽는다 · 결정 체크박스는 단계로 세지 않는다"
PLAN_DEC3="$PLAN_OK"'
## 결정 필요(승인 전)
| # | 결정 | 답 |
|---|---|---|
| Q1 | 목업 선택 | 닫힘 · A안 |
'
setup s20; printf '%s' "$PLAN_DEC3" > "$T/.claude/plan-active.md"; setmtime "$T/.claude/plan-active.md" "$NOW"
out=$(run)
printf '%s' "$out" | grep -q '확정 결정' && ok "⭐ 3열 표의 닫힌 결정을 되읽는다" || ng "3열 확정 결정" "$out"
cleanup

PLAN_DECBOX="$PLAN_OK"'
## 결정 필요(승인 전)
- [ ] Q1 목업 선택 — 아직
- [ ] Q2 머지 주체 — 아직
'
setup s21; printf '%s' "$PLAN_DECBOX" > "$T/.claude/plan-active.md"; setmtime "$T/.claude/plan-active.md" "$NOW"
out=$(run)
printf '%s' "$out" | grep -q '남은 항목 1/2' && ok "⭐⭐ 결정 절 체크박스를 **계획 단계로 세지 않는다**(1/2 여야 한다)" || ng "결정 절 제외" "$out"
printf '%s' "$out" | grep -q '열린 항목 2건' && ok "대신 「열린 결정」으로 따로 말한다" || ng "열린 결정 경고" "$out"
cleanup

echo "=== 사보타주 — 탐지기가 정말 미완료를 보는가"
setup s9; printf '%s' "$PLAN_OK" > "$T/.claude/plan-active.md"; setmtime "$T/.claude/plan-active.md" "$NOW"
a=$(run); cleanup
setup s10; printf '%s' "$PLAN_DONE" > "$T/.claude/plan-active.md"
setmtime "$T/.claude/plan-active.md" "$NOW"
b=$(run); cleanup
[ -n "$a" ] && [ -z "$b" ] && ok "체크 하나로 출력이 사라진다(탐지기 생존)" \
  || ng "사보타주" "미완료=$([ -n "$a" ] && echo 출력 || echo 무출력) 완료=$([ -n "$b" ] && echo 출력 || echo 무출력)"

printf '\npass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
