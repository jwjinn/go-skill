#!/usr/bin/env bash
# go-precheck.sh 대조군. 실행: bash <플러그인>/hooks/go-precheck.test.sh
#
# 이 훅은 **보조 그물**이다(본체는 /go 안의 지시). 그래서 「말해야 할 때」보다
# **「엉뚱한 프롬프트에 말하지 않는 것」**이 더 중요하다 — 매 프롬프트마다 돌기 때문이다.
set -u

HOOK="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/go-precheck.sh"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
ng(){ printf '  NG   %s  (%s)\n' "$1" "$2"; fail=$((fail+1)); }

NOW=$(date +%s)
setup(){ T=$(mktemp -d); mkdir -p "$T/.claude"; }
cleanup(){ rm -rf "$T"; }
setmtime(){ python3 -c "import os,sys; os.utime(sys.argv[1],(int(sys.argv[2]),int(sys.argv[2])))" "$1" "$2"; }
run(){ python3 -c "import json,sys;print(json.dumps({'prompt':sys.argv[1]}))" "$1" \
       | CLAUDE_PROJECT_DIR="$T" bash "$HOOK" 2>/dev/null; }

DRAFT='# 제목

## 목표 계약
원 요청: "리뷰 루프를 붙여줘"
수용 기준:
  - 세 리뷰어가 병렬로 뜬다
범위 밖: UI 변경

## P0
- [ ] P0-1 하나
- [ ] P0-2 둘
'

echo "=== 초안이 없을 때 — 막아야 한다"
setup
out=$(run "/go P0~P4")
printf '%s' "$out" | grep -q '승인할 계획이 없다' && ok "원문 /go + 초안 없음 → 경고" || ng "원문 /go" "$out"
out=$(run "<command-name>/go</command-name>
            <command-args>P0~P4</command-args>")
printf '%s' "$out" | grep -q '승인할 계획이 없다' && ok "래핑된 /go + 초안 없음 → 경고" || ng "래핑 /go" "$out"
cleanup

echo "=== 초안이 있을 때 — 「그대로 옮겨라」를 말해야 한다"
setup; printf '%s' "$DRAFT" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go 전부")
printf '%s' "$out" | grep -q '계획 초안 있음' && ok "초안 있음을 알린다" || ng "초안 인식" "$out"
printf '%s' "$out" | grep -q '체크박스 2개' && ok "체크박스 수를 센다" || ng "체크박스 계수" "$out"
printf '%s' "$out" | grep -q '그대로' && ok "「그대로 옮겨라」를 지시한다" || ng "이관 지시" "$out"
printf '%s' "$out" | grep -q '승인할 계획이 없다' && ng "초안이 있는데 없다고 함" "$out" || ok "초안이 있으면 없다고 하지 않는다"
cleanup

echo "=== 초안이 부실할 때 — 무엇이 없는지 말해야 한다"
setup; printf '# t\n\n## P0\n- [ ] 하나\n' > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
run "/go" | grep -q '「## 목표 계약」 절이 없다' && ok "계약 절 부재를 지적한다" || ng "계약 부재" "$(run '/go')"
cleanup
setup; printf '# t\n\n## 목표 계약\n원 요청: "x"\n\n## P0\n체크박스가 없다\n' > "$T/.claude/plan-draft.md"
setmtime "$T/.claude/plan-draft.md" "$NOW"
run "/go" | grep -q '체크박스가 0개' && ok "체크박스 0개를 지적한다" || ng "체크박스 0" "$(run '/go')"
cleanup

echo "=== ⭐ G9 결정 선행 게이트 — 열린 결정이 있으면 착수 금지를 말해야 한다"
DEC_OPEN="$DRAFT"'
## 결정 필요(승인 전)
- [ ] Q1 [선택] 목업 4화면 중 어느 안인가 — 닫힘: index.html 에 ✅
- [x] Q2 [질문] 낡은 백엔드를 종료하나 → 답: 예
'
setup; printf '%s' "$DEC_OPEN" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go 전부")
printf '%s' "$out" | grep -q '열린 항목 1건' && ok "체크박스형: 열린 1건을 센다" || ng "열린 결정 계수" "$out"
printf '%s' "$out" | grep -q '착수하지 마라' && ok "착수 금지를 말한다" || ng "착수 금지" "$out"
printf '%s' "$out" | grep -q 'Q1' && ok "열린 항목을 이름으로 지목한다" || ng "이름 지목" "$out"
printf '%s' "$out" | grep -q '그대로.*plan-active' && ng "열린 결정이 있는데 이관을 지시함" "$out" || ok "열린 결정이 있으면 이관 지시가 없다"
cleanup
DEC_TABLE="$DRAFT"'
## 결정 필요(승인 전)
| # | 결정 | 권고 | 닫힘 조건 | 상태 |
|---|---|---|---|---|
| Q0 | 목업 선택 | ④ 는 A | index.html ✅ | ⏳ 제작 중 |
| Q1 | K3 넷 포함? | 아니오 | 답 1개 | 열림 |
| Q2 | 낡은 백엔드 종료 | 예 | 답 1개 | 닫힘 · 예 |
'
setup; printf '%s' "$DEC_TABLE" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '열린 항목 2건.*닫힘 1건' && ok "표형: 열림·⏳ 2건 / 닫힘 1건" || ng "표형 계수" "$out"
cleanup
DEC_CLOSED="$DRAFT"'
## 결정 필요(승인 전)
- [x] Q1 [선택] 목업 → 답: ① B · ② A
- [x] Q2 [질문] 종료 → 답: 예
'
setup; printf '%s' "$DEC_CLOSED" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '전부 닫힘(2건)' && ok "전부 닫히면 ✅ 를 말한다" || ng "닫힘 인식" "$out"
printf '%s' "$out" | grep -q '그대로' && ok "닫혔으면 이관을 지시한다" || ng "닫힘 후 이관" "$out"
printf '%s' "$out" | grep -q '착수하지 마라' && ng "닫혔는데 착수 금지" "$out" || ok "닫혔으면 착수 금지가 없다"
cleanup
setup; printf '%s' "$DRAFT"'- [ ] P0-3 사용자 확인 후 배포한다\n' > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '결정 필요(승인 전)」 절이 없다' && ok "절이 없으면 경고한다(차단 아님)" || ng "절 부재 경고" "$out"
printf '%s' "$out" | grep -q '후보로 보이는 줄 \*\*1건' && ok "결정 후보(「사용자 확인」)를 센다" || ng "후보 계수" "$out"
printf '%s' "$out" | grep -q '그대로' && ok "절이 없어도 이관 지시는 남는다(경고이지 차단이 아니다)" || ng "절 부재 시 이관" "$out"
cleanup

echo "=== ⭐ R1 리뷰 반영 — 표의 **마지막 열**을 본다(열 수 고정 금지)"
DEC_3COL="$DRAFT"'
## 결정 필요(승인 전)
| # | 결정 | 상태 |
|---|---|---|
| Q1 | 목업 선택 | 열림 |
| Q2 | 머지 주체 | 닫힘 · 사람 |
'
setup; printf '%s' "$DEC_3COL" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '열린 항목 1건.*닫힘 1건' && ok "⭐ 3열 표를 센다(전에는 5열만 봤다)" || ng "3열 표" "$out"
cleanup

DEC_6COL="$DRAFT"'
## 결정 필요(승인 전)
| # | 결정 | 권고 | 닫힘 조건 | 근거 | 상태 |
|---|---|---|---|---|---|
| Q1 | 목업 선택 | B | ✅ 기록 | 실측 | 열림 |
'
setup; printf '%s' "$DEC_6COL" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '열린 항목 1건' && ok "⭐ 6열 표도 센다" || ng "6열 표" "$out"
cleanup

echo "=== ⭐⭐ 0 을 「없음」으로 단언하지 않는다(탐지기를 먼저 의심하라)"
DEC_UNPARSED="$DRAFT"'
## 결정 필요(승인 전)
Q1 목업 선택 — 아직 안 정함(형식을 안 지킨 서술)
'
setup; printf '%s' "$DEC_UNPARSED" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '어느 것도 세지 못했다' && ok "⭐ 못 읽었으면 「못 읽었다」고 말한다" || ng "미파싱 경고" "$out"
printf '%s' "$out" | grep -q '전부 닫힘' && ng "0 을 전부 닫힘으로 단언함" "$out" || ok "0 을 「전부 닫힘」이라 하지 않는다"
cleanup

echo "=== ⭐ 병렬 배치·자원 회수(2026-09-13) — 무엇을 병렬로 할지는 계획 단계의 판정이다"
BIG="$DRAFT"'- [ ] P0-3 셋
- [ ] P0-4 넷
'
FAN_FULL="$BIG"'
## 병렬 배치
| 파도 | 워커 | 항목 | 파일 집합(실측) | 공유 자원 |
|---|---|---|---|---|
| W1 | A | P0-1 · P0-2 | `a/**` | 없음 |
| W1 | B | P0-3 | `b/**` | 도커 |

## C — 자원 회수
- [ ] C1 파도 끝마다 worker-release
- [ ] C2 cleanup.sh --apply
'
setup; printf '%s' "$FAN_FULL" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '병렬 배치 절(워커 행 2개) + 자원 회수 절 있음' && ok "워커 2행 + 회수 절 → 둘 다 있다고 센다" || ng "fan 전부 있음" "$out"
printf '%s' "$out" | grep -q '자원 회수」 절이 없다' && ng "있는데 없다고 함" "$out" || ok "회수 절이 있으면 그 경고가 없다"
cleanup

FAN_NO_C="$BIG"'
## 병렬 배치
| 파도 | 워커 | 항목 | 파일 집합(실측) | 공유 자원 |
|---|---|---|---|---|
| W1 | A | P0-1 | `a/**` | 없음 |
'
setup; printf '%s' "$FAN_NO_C" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '자원 회수」 절이 없다' && ok "⭐ 워커는 있는데 회수 절이 없으면 지적한다(15개 누수의 재발 방지)" || ng "회수 부재 미지적" "$out"
cleanup

SOLO="$BIG"'
## 병렬 배치
단독 — 항목 넷이 한 패키지의 같은 파일 셋을 고친다
'
setup; printf '%s' "$SOLO" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '워커 행 0 — 「단독」' && ok "「단독 — 이유」 한 줄도 판정으로 본다" || ng "단독 미인식" "$out"
printf '%s' "$out" | grep -q '자원 회수」 절이 없다' && ng "단독인데 회수 절을 요구함" "$out" || ok "단독이면 회수 절을 요구하지 않는다"
cleanup

setup; printf '%s' "$BIG" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '「## 병렬 배치」 절이 없다(체크박스 4개)' && ok "체크박스 4개인데 절이 없으면 「정하지 않았다」를 알린다" || ng "절 부재 미지적" "$out"
cleanup

echo "=== 대조군: 작은 계획(체크박스 2개)은 병렬 배치 절을 요구하지 않는다(오탐 0)"
setup; printf '%s' "$DRAFT" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '병렬 배치' && ng "작은 계획에 병렬 배치를 요구함" "$out" || ok "체크박스 2개 → 조용"
cleanup

echo "=== 낡은 초안은 초안이 아니다"
setup; printf '%s' "$DRAFT" > "$T/.claude/plan-draft.md"
setmtime "$T/.claude/plan-draft.md" "$((NOW - 60*60*24))"   # 24h > 기본 12h
out=$(run "/go")
printf '%s' "$out" | grep -q '승인할 계획이 없다' && ok "12h 지난 초안 → 없는 것으로 본다" || ng "낡은 초안" "$out"
cleanup

echo "=== ⭐ 조용해야 하는 경우(오탐 0 이 이 훅의 생명이다)"
setup; printf '%s' "$DRAFT" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
for p in "안녕" "/goal 테스트가 통과한다" "/plan 뭔가" "코드에서 /go 를 설명해줘" "/gopher"; do
  out=$(run "$p")
  [ -z "$out" ] && ok "조용: $p" || ng "조용해야 함: $p" "$out"
done
cleanup

echo "=== 훅 고장은 통과"
out=$(printf '' | bash "$HOOK" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "빈 stdin → exit 0·무출력" || ng "빈 stdin" "rc=$rc"
out=$(printf 'not json' | bash "$HOOK" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "깨진 stdin → exit 0" || ng "깨진 stdin" "rc=$rc"

echo "=== 사보타주 — 탐지기가 정말 초안 유무를 보는가"
setup; a=$(run "/go"); printf '%s' "$DRAFT" > "$T/.claude/plan-draft.md"
setmtime "$T/.claude/plan-draft.md" "$NOW"; b=$(run "/go"); cleanup
printf '%s' "$a" | grep -q '없다' && printf '%s' "$b" | grep -q '있음' \
  && ok "파일 하나로 판정이 뒤집힌다(탐지기 생존)" || ng "사보타주" "a/b 가 같다"


echo "=== ⭐ 채택 경로 — 초안은 없지만 기존 plan-active.md 가 있으면 (2026-09-02 결함 3)"
# ⚠ 이것이 없으면 250줄 계획을 손에 들고도 /go 가 착수를 거부한다 —
#   사람이 §0-b 를 손으로 대신하게 된다(다른 세션 자가평가에서 실제로 그랬다).
setup
printf -- '# 계획\n\n작업 위치: **%s**\n\n## 목표 계약\n원 요청: "x"\n\n- [ ] S1\n- [ ] S2\n' "$T" \
  > "$T/.claude/plan-active.md"
out=$(run "/go S1~S11")
printf '%s' "$out" | grep -q '기존 계획' && ok "기존 계획을 알아본다" || ng "채택 미인식" "$out"
printf '%s' "$out" | grep -q '경로 ①' && ok "§0-b 경로 ①(채택)로 보낸다" || ng "경로 안내 없음" "$out"
printf '%s' "$out" | grep -q '승인할 계획이 없다' && ng "있는데 없다고 함" "$out" || ok "「없다」고 하지 않는다"
printf '%s' "$out" | grep -q 'R — 리뷰' && ok "⭐ 빠진 R 항목을 지목한다" || ng "R 미지목" "$out"
cleanup

# 반대 방향 ①: 전부 닫힌 계획은 채택 대상이 아니다(「전부 채택」 구현을 거른다)
setup
printf -- '# 계획\n작업 위치: **%s**\n\n- [x] S1\n' "$T" > "$T/.claude/plan-active.md"
out=$(run "/go")
printf '%s' "$out" | grep -q '승인할 계획이 없다' && ok "전부 닫힌 계획 → 채택 아님" || ng "닫힌 계획을 채택" "$out"
cleanup

# 반대 방향 ②: 남의 워크트리 계획은 채택하지 않고 진단만 한다
setup
printf -- '# 계획\n작업 위치: **/other/repo**\n\n- [ ] S1\n' > "$T/.claude/plan-active.md"
out=$(run "/go")
printf '%s' "$out" | grep -q '다른 세션의 계획일 수 있다' && ok "⚠ 남의 계획은 진단만" || ng "남의 계획 미진단" "$out"
printf '%s' "$out" | grep -q '경로 ①' && ng "남의 계획을 채택하라고 함" "$out" || ok "채택하라고 하지 않는다"
cleanup

# ── ⭐ 테스트 에이전트 축(2026-09-15) ────────────────────────────────────────
#
# 이 축은 **차단하지 않는다**(묻지 않고 지나가면 tester.sh 가 rc 70 으로 닫히므로 안전한 쪽으로
# 실패한다). 그래서 재는 것은 「알리는가」이고, 대조군은 **조용해야 하는 조건**이다.
echo "=== ⭐ 테스트 에이전트 축 — ask 인데 Q-T 가 없으면 알린다"

tester_stub() { # tester_stub <MODE> — go-tester 를 흉내 내는 최소 구조
  td="$T/fake-skills/go-tester/tester"
  mkdir -p "$td"
  printf '%s\n' "print('TESTER_MODE=$1')" > "$td/_config.py"
  printf '%s\n' "print('TESTER_ENABLED=0')" >> "$td/_config.py"
  HOME_ORIG="$HOME"
  export HOME="$T/fakehome"
  mkdir -p "$HOME/.claude/skills"
  ln -sfn "$T/fake-skills/go-tester" "$HOME/.claude/skills/go-tester"
}
tester_unstub() { [ -n "${HOME_ORIG:-}" ] && export HOME="$HOME_ORIG"; }

setup
printf -- '# 계획\n\n## 목표 계약\n원 요청: "x"\n\n## 결정 필요(승인 전)\n- [x] Q1 [질문] 무엇 — 답: 그것\n\n## 병렬 배치\n단독 — 작다\n\n## P0\n- [ ] a\n- [ ] b\n' \
  > "$T/.claude/plan-draft.md"
tester_stub ask
out=$(run "/go")
tester_unstub
printf '%s' "$out" | grep -q 'Q-T' && ok "ask 인데 Q-T 가 없으면 지목한다" || ng "Q-T 미지목" "$out"
printf '%s' "$out" | grep -q '그대로.*plan-active' && ok "⭐ 대조군 — 그래도 이관 지시는 나온다(차단이 아니다)" || ng "이관 지시가 사라졌다" "$out"
cleanup

echo "=== 대조군 — Q-T 가 있으면 조용하다(오탐 0)"
setup
printf -- '# 계획\n\n## 목표 계약\n원 요청: "x"\n\n## 결정 필요(승인 전)\n- [x] Q-T [질문] 테스트 에이전트(로컬 모델) 사용 — 답: 쓴다\n\n## 병렬 배치\n단독 — 작다\n\n## P0\n- [ ] a\n- [ ] b\n' \
  > "$T/.claude/plan-draft.md"
tester_stub ask
out=$(run "/go")
tester_unstub
printf '%s' "$out" | grep -q '테스트 에이전트 항목(Q-T)이 초안에 있다' && ok "Q-T 가 있으면 확인만 한다" || ng "Q-T 인식 실패" "$out"
printf '%s' "$out" | grep -q 'Q-T 가 없다' && ng "있는데 없다고 함" "$out" || ok "⭐ 없다고 말하지 않는다"
cleanup

echo "=== 대조군 — on/off 로 고정된 프로젝트는 묻지 않는다"
setup
printf -- '# 계획\n\n## 목표 계약\n원 요청: "x"\n\n## 결정 필요(승인 전)\n없음 — 단순\n\n## 병렬 배치\n단독\n\n## P0\n- [ ] a\n- [ ] b\n' \
  > "$T/.claude/plan-draft.md"
tester_stub off
out=$(run "/go")
tester_unstub
printf '%s' "$out" | grep -q 'Q-T 가 없다' && ng "off 인데 물으라고 함" "$out" || ok "off 면 Q-T 를 요구하지 않는다"
cleanup

echo "=== ⭐⭐ 대조군 — go-tester 가 **없으면** 이 축이 통째로 조용하다"
setup
printf -- '# 계획\n\n## 목표 계약\n원 요청: "x"\n\n## 결정 필요(승인 전)\n없음\n\n## 병렬 배치\n단독\n\n## P0\n- [ ] a\n- [ ] b\n' \
  > "$T/.claude/plan-draft.md"
HOME_ORIG="$HOME"; export HOME="$T/emptyhome"; mkdir -p "$HOME/.claude/skills"
out=$(run "/go")
export HOME="$HOME_ORIG"
printf '%s' "$out" | grep -qE 'Q-T|테스트 에이전트' && ng "go-tester 없는데 말한다" "$out" || ok "설치 안 됐으면 조용하다"
cleanup

echo "=== 옵트인 잔재 — 다른 계획의 기록이 남아 있으면 알린다"
setup
printf -- '# 계획\n\n## 목표 계약\n원 요청: "x"\n\n## 결정 필요(승인 전)\n- [x] Q-T [질문] 테스트 에이전트 — 답: 쓴다\n\n## 병렬 배치\n단독\n\n## P0\n- [ ] a\n- [ ] b\n' \
  > "$T/.claude/plan-draft.md"
mkdir -p "$T/.claude/tester"
printf '{"answer":"use","plan_file":"/elsewhere/plan-active.md"}\n' > "$T/.claude/tester/opt-in.json"
tester_stub ask
out=$(run "/go")
tester_unstub
printf '%s' "$out" | grep -q '다른 계획' && ok "다른 계획의 옵트인을 지목한다" || ng "잔재 미지목" "$out"
cleanup

printf '\npass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
