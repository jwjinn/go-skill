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

echo "=== ⭐ 플러그인 이름 — 실제 호출 표기 /go-review:go 에도 발화한다 (2026-09-16)"
# 2026-09-16 실측: 플러그인으로 로드된 뒤 프롬프트는 `<command-name>/go-review:go</command-name>` 로
# 실리는데 이 훅은 `/go` 만 봐서 실사용에서 한 번도 발화하지 않았다. 대조군이 옛 표기만 잠갔던 탓이다.
setup
out=$(run "<command-message>go-review:go</command-message>
<command-name>/go-review:go</command-name>
<command-args></command-args>")
printf '%s' "$out" | grep -q '승인할 계획이 없다' && ok "래핑된 /go-review:go + 초안 없음 → 경고" || ng "래핑 /go-review:go" "$out"
out=$(run "/go-review:go 전부")
printf '%s' "$out" | grep -q '승인할 계획이 없다' && ok "원문 /go-review:go → 경고" || ng "원문 /go-review:go" "$out"
out=$(run "<command-name>/go-review:plan</command-name>")
[ -z "$out" ] && ok "대조군: /go-review:plan 에는 말하지 않는다" || ng "plan 오발화" "$out"
out=$(run "<command-name>/go-review:review-loop</command-name>")
[ -z "$out" ] && ok "대조군: /go-review:review-loop 에는 말하지 않는다" || ng "review-loop 오발화" "$out"
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

echo "=== ⭐⭐ 병렬 배치 협의(2026-09-16) — 워커가 둘 이상이면 승인 전에 사용자가 배치를 본다"
# 사용자 지시: 「사용자에게 사전에 어느 플랜들은 병렬로 할거다 안내하면 더 좋을 거 같고」.
# 병렬은 되돌리기 비싸다(워크트리 N개 · PR N개) — 그래서 결정 절의 항목이어야 한다.
setup; printf '%s' "$FAN_FULL" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '워커가 2명인데' && ok "워커 2행 + Q-P 없음 → 협의 항목을 요구한다" || ng "Q-P 부재 미지적" "$out"
printf '%s' "$out" | grep -q '교차 0 근거' && ok "무엇을 담아야 하는지 말한다" || ng "담을 것 미안내" "$out"
cleanup

FAN_QP="$FAN_FULL"'
## 결정 필요(승인 전)
- [x] Q-P [선택] 병렬 배치 — 권고: W1 = A(P0-1·P0-2) · B(P0-3) · 교차 0 · 대안: 단독 · 닫힘: 답 1개 ✅ 사용자 승인
'
setup; printf '%s' "$FAN_QP" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '병렬 배치 협의 항목(Q-P)이 결정 절에 있다' && ok "결정 절의 Q-P 를 센다" || ng "Q-P 미인식" "$out"
printf '%s' "$out" | grep -q '워커가 2명인데' && ng "있는데 없다고 함" "$out" || ok "그때는 요구하지 않는다"
cleanup

# ⭐⭐ 반대 방향 — 결정 절 **밖**의 Q-P 는 없는 것으로 센다(2026-09-16 리뷰 둘이 지적한 자리).
#   초안 전체를 훑으면 배치 표 옆 산문 한 줄이 잡혀 「승인 전에 사용자가 배치를 본다」고 단언하고,
#   그 상태로 /go 가 돌면 워커 N명이 사용자 승인 없이 뜬다.
FAN_QP_OUT="$FAN_FULL"'
Q-P 는 위 배치 표로 갈음한다(여기는 결정 절이 아니다).

## 결정 필요(승인 전)
- [x] Q1 [질문] 다른 것 — 닫힘
'
setup; printf '%s' "$FAN_QP_OUT" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '워커가 2명인데' && ok "⭐ 결정 절 밖의 Q-P 는 세지 않는다" || ng "절 밖 Q-P 를 인정했다" "$out"
cleanup

FAN_ONE="$BIG"'
## 병렬 배치
| 파도 | 워커 | 항목 | 파일 집합(실측) | 공유 자원 |
|---|---|---|---|---|
| W1 | A | P0-1 · P0-2 | `a/**` | 없음 |

## C — 자원 회수
- [ ] C1 파도 끝마다 worker-release
'
setup; printf '%s' "$FAN_ONE" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '워커가 1명인데\|워커가 [0-9]*명인데' && ng "⭐ 워커 하나인데 협의를 요구한다(소음)" "$out" || ok "⭐ 워커가 하나면 묻지 않는다"
cleanup

setup; printf '%s' "$SOLO" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go")
printf '%s' "$out" | grep -q '명인데' && ng "단독인데 협의를 요구한다" "$out" || ok "단독이면 묻지 않는다"
cleanup

# ⭐ 사보타주 — 워커 수를 세는 자리를 지우면 위 검사가 붉어져야 한다
setup; printf '%s' "$FAN_FULL" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
sed 's@if \[ "\$workers" -ge 2 \]; then@if false; then@' "$HOOK" > "$T/sab-qp.sh"
out=$(python3 -c "import json,sys;print(json.dumps({'prompt':'/go'}))" | CLAUDE_PROJECT_DIR="$T" bash "$T/sab-qp.sh" 2>/dev/null)
printf '%s' "$out" | grep -q '명인데' && ng "사보타주했는데 여전히 지적한다" "$out" || ok "⭐ 세는 자리를 지우면 협의 요구가 사라진다(탐지기가 살아 있다)"
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

# ⛔⛔ 가짜 `_config.py` 로 스텁하려던 첫 판은 **효력이 없었다**(2026-09-16 실측). `sibling_plugin`
#   은 HOME 이 아니라 **이 훅의 설치 위치**에서 형제를 찾으므로, HOME 을 바꿔도 진짜 go-tester 를
#   집었다. 즉 이 축의 검사들은 가짜가 아니라 **그때그때의 실제 구성**을 보고 있었다 — 내가 만든
#   스텁이 죽은 코드였고 아무도 몰랐다(「정본이 있는데 안 쓰인다」의 변종).
#   ⇒ 진짜 `_config.py` 가 읽는 **프로젝트 구성 파일**을 쓴다. 그것이 실제 조건과도 같다.
tester_stub() { # tester_stub <ask|on|off> — 연결된 상태를 만든다(endpoint·model 이 있어야 ask 가 ask 다)
  mkdir -p "$T/.claude/tester"
  case "$1" in
    ask) printf '%s\n' '{"endpoint":"http://example.invalid/v1","model":"qwen-test"}' > "$T/.claude/tester/config.json" ;;
    *)   printf '{"enabled":"%s","endpoint":"http://example.invalid/v1","model":"qwen-test"}\n' "$1" > "$T/.claude/tester/config.json" ;;
  esac
}
tester_unconfigured() { rm -f "$T/.claude/tester/config.json"; }   # 연결 안 된 상태
tester_unstub() { :; }

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
# ⚠ 격리가 **둘**이다. 훅은 go-tester 를 ①자기 플러그인 루트의 형제 ②HOME 아래 순으로
#   찾으므로(_plugins.sh), HOME 만 비우면 실제 저장소의 go-tester 를 찾아 이 대조군이 깨진다.
#   2026-09-16 에 실제로 깨졌고, 그 깨짐이 형제 탐색이 도는 증거였다.
HOME_ORIG="$HOME"; export HOME="$T/emptyhome"; mkdir -p "$HOME/.claude/skills"
mkdir -p "$T/lonely-plugin/hooks"
out=$(CLAUDE_PLUGIN_ROOT="$T/lonely-plugin" run "/go")
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

echo "=== ⭐⭐ 고유화 — 초안·계획이 여럿이면 내 것만 채택 후보다 (2026-09-16)"
runtr(){ python3 -c "import json,sys;print(json.dumps({'prompt':sys.argv[1],'transcript_path':sys.argv[2]}))" "$1" "$2" \
         | CLAUDE_PROJECT_DIR="$T" bash "$HOOK" 2>/dev/null; }
setup; mkdir -p "$T/.claude/plans/20260916-mine" "$T/.claude/plans/20260916-theirs"
printf '%s' "$DRAFT" > "$T/.claude/plans/20260916-mine/draft.md";   setmtime "$T/.claude/plans/20260916-mine/draft.md" "$NOW"
printf '%s' "$DRAFT" > "$T/.claude/plans/20260916-theirs/draft.md"; setmtime "$T/.claude/plans/20260916-theirs/draft.md" "$NOW"
printf '%s\n' '{"type":"user","message":{"content":"해줘"}}' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"$T/.claude/plans/20260916-mine/draft.md\",\"content\":\"x\"}}]}}" > "$T/tr-mine.jsonl"
out=$(runtr "/go" "$T/tr-mine.jsonl")
printf '%s' "$out" | grep -q '20260916-mine/plan.md' && ok "내 초안 → 그 디렉토리의 plan.md 로 옮겨라" || ng "내 초안 이관 안내" "$out"
printf '%s' "$out" | grep -q '20260916-theirs' && ng "남의 초안이 섞였다" "$out" || ok "⭐ 남의 초안은 안내에 없다"
printf '%s\n' '{"type":"user","message":{"content":"해줘"}}' > "$T/tr-none.jsonl"
out=$(runtr "/go" "$T/tr-none.jsonl")
printf '%s' "$out" | grep -q '다른 세션의 초안 2개' && ok "내 초안이 없고 남의 것만 → 「옮기지 마라」(개수 2)" || ng "남의 초안 경고" "$out"
printf '%s' "$out" | grep -q '그대로.*옮겨라' && ng "남의 초안을 옮기라고 했다" "$out" || ok "⭐ 옮기라는 안내가 없다"
# 경로 ① — plans/ 의 계획을 채택한 세션
rm -f "$T/.claude/plans/20260916-mine/draft.md" "$T/.claude/plans/20260916-theirs/draft.md"
printf -- '# 계획\n\n작업 위치: %s\n\n## 목표 계약\n원 요청: "x"\n\n## R — 리뷰\n- [ ] R1\n' "$T" > "$T/.claude/plans/20260916-mine/plan.md"
printf '%s\n' '{"type":"user","message":{"content":"해줘"}}' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"$T/.claude/plans/20260916-mine/plan.md\",\"content\":\"x\"}}]}}" > "$T/tr-plan.jsonl"
out=$(runtr "/go" "$T/tr-plan.jsonl")
printf '%s' "$out" | grep -q '기존 계획.*20260916-mine/plan.md' && ok "plans/ 의 내 계획 → 경로 ①(채택)" || ng "plans 경로 ①" "$out"
cleanup

echo "=== ⭐⭐ go-tester 미연결 안내 — 묻지 않고 한 번만 알린다 (2026-09-16 · 사용자 지시)"
# 사용자 지적: 「최초로 로컬 모델을 쓰겠다고 하면 endpoint + API 키를 입력받나?」 → 받지 않는다.
# 구성이 비면 판정이 `ask` 인 채 `no_endpoint` 가 되고, 종전 문구는 「Q-T 를 넣어라」라고 말했다.
# 넣어도 못 쓰므로 **틀린 사유**였고, 처음 쓰는 사람은 질문이 왜 안 뜨는지 알 수 없었다.
hintrun(){ # hintrun <session_id>
  python3 -c "import json,sys;print(json.dumps({'prompt':'/go','session_id':sys.argv[1],'transcript_path':''}))" "$1" \
    | CLAUDE_PROJECT_DIR="$T" bash "$HOOK" 2>/dev/null; }
TESTY="$DRAFT"'- [ ] P0-3 테스트와 대조군을 붙인다
'
PLAINY="$DRAFT"'- [ ] P0-3 문구를 다듬는다
'
rm -f "${TMPDIR:-/tmp}"/claude-tester-hint-t7* 2>/dev/null

setup; tester_unconfigured; printf '%s' "$TESTY" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(hintrun t7-a)
printf '%s' "$out" | grep -q 'go-tester 가 아직 연결되지 않았다' && ok "구성이 비고 테스트 항목이 있으면 알린다" || ng "미연결 안내 없음" "$out"
printf '%s' "$out" | grep -q 'tester.env' && ok "키를 둘 자리를 말한다" || ng "키 자리 미안내" "$out"
printf '%s' "$out" | grep -q 'config.json 에 적지 마라' && ok "⭐ 키를 구성에 적지 말라고 경고한다(그 파일은 저장소에 들어간다)" || ng "키 경고 없음" "$out"
printf '%s' "$out" | grep -q 'Q-T)이 없다' && ng "⛔ 못 쓰는 상태인데 Q-T 를 넣으라고 한다(틀린 사유)" "$out" || ok "⛔ 그때는 Q-T 를 요구하지 않는다"

echo "--- 세션당 한 번"
out=$(hintrun t7-a)
printf '%s' "$out" | grep -q 'go-tester 가 아직 연결되지 않았다' && ng "같은 세션에서 또 알린다(소음)" "$out" || ok "⭐ 같은 세션 2회차는 조용하다"
out=$(hintrun t7-b)
printf '%s' "$out" | grep -q 'go-tester 가 아직 연결되지 않았다' && ok "⭐ 다른 세션에는 다시 알린다" || ng "다른 세션인데 조용하다" "$out"
cleanup

echo "--- 위임할 것이 없으면 조용하다(쓸 일 없는데 설정을 권하지 않는다)"
rm -f "${TMPDIR:-/tmp}"/claude-tester-hint-t7* 2>/dev/null
setup; tester_unconfigured; printf '%s' "$PLAINY" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(hintrun t7-c)
printf '%s' "$out" | grep -q 'go-tester 가 아직 연결되지 않았다' && ng "테스트 항목이 없는데 알렸다" "$out" || ok "테스트 항목이 없으면 조용하다"
cleanup

echo "--- ⭐ 사보타주 — 미연결 판별을 지우면 옛 동작(틀린 Q-T 안내)으로 돌아간다"
rm -f "${TMPDIR:-/tmp}"/claude-tester-hint-t7* 2>/dev/null
setup; tester_unconfigured; printf '%s' "$TESTY" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
# ⚠⚠ 사보타주본을 **혼자 떼어 두면 안 된다.** 이 훅은 `dirname $0` 에서 `_planpath.sh`·
#   `_plugins.sh` 를 읽으므로, 임시 경로에 스크립트만 복사하면 초안 해석기가 통째로 없어져
#   출력이 0 이 된다 — 사보타주가 「탐지기를 껐다」가 아니라 「스크립트를 죽였다」가 되고,
#   그러면 이 검사는 무엇도 증명하지 못한다(2026-09-16 실측으로 밟았다).
mkdir -p "$T/sabdir"
cp "$(dirname "$HOOK")/_planpath.sh" "$(dirname "$HOOK")/_plugins.sh" "$T/sabdir/" 2>/dev/null
sed 's@no_endpoint@절대안맞는사유@' "$HOOK" > "$T/sabdir/go-precheck.sh"
out=$(python3 -c "import json;print(json.dumps({'prompt':'/go','session_id':'t7-d','transcript_path':''}))" \
      | CLAUDE_PROJECT_DIR="$T" bash "$T/sabdir/go-precheck.sh" 2>/dev/null)
printf '%s' "$out" | grep -q 'Q-T)이 없다' && ok "사보타주하면 못 쓰는 상태에서 Q-T 를 요구한다(탐지기가 살아 있다)" || ng "사보타주해도 그대로다" "$out"
rm -f "${TMPDIR:-/tmp}"/claude-tester-hint-t7* 2>/dev/null
cleanup

echo "=== ⭐⭐ 형제 플러그인 탐색 — 설치 모양 둘을 다 찾는다 (2026-09-16)"
# 고정 문자열 `~/.claude/skills/go-tester` 는 심링크 설치에만 있다. 마켓플레이스로 받으면
# `…/cache/<마켓>/go-tester/<버전>/` 이고, 그 경로를 못 찾으면 위임이 조용히 rc 70 으로 닫힌다.
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_plugins.sh"
SB=$(mktemp -d)

# ① 심링크 모양 — 형제가 바로 옆에 있다
mkdir -p "$SB/skills/go-review/hooks" "$SB/skills/go-tester/tester"
: > "$SB/skills/go-tester/tester/_config.py"
# ⚠ 반환값은 **정규화된 절대 경로**다(`…/go-review/../go-tester` 를 그대로 주면 안내 문구에
#   그 모양이 실린다). 그래서 기대값도 정규화해서 비교한다.
want=$(CDPATH='' cd -- "$SB/skills/go-tester" && pwd)
got=$(CLAUDE_PLUGIN_ROOT="$SB/skills/go-review" sibling_plugin go-tester tester/_config.py)
[ "$got" = "$want" ] && ok "① 심링크 모양에서 찾는다" || ng "심링크 모양" "$got"

# ② 마켓플레이스 모양 — 형제가 한 단계 위에 있고 버전 디렉토리가 낀다
mkdir -p "$SB/cache/mk/go-review/0.6.0/hooks" "$SB/cache/mk/go-tester/0.1.0/tester"
: > "$SB/cache/mk/go-tester/0.1.0/tester/_config.py"
got=$(CLAUDE_PLUGIN_ROOT="$SB/cache/mk/go-review/0.6.0" sibling_plugin go-tester tester/_config.py)
case "$got" in *"/go-tester/0.1.0") ok "② 마켓플레이스 모양에서 찾는다" ;;
               *) ng "마켓플레이스 모양" "$got" ;; esac

# ③ ⭐ 대조군 — 이름만 맞고 **내용이 없으면** 채택하지 않는다
mkdir -p "$SB/empty/go-review/hooks" "$SB/empty/go-tester"
HOME_ORIG="$HOME"; export HOME="$SB/nohome"
if CLAUDE_PLUGIN_ROOT="$SB/empty/go-review" sibling_plugin go-tester tester/_config.py >/dev/null; then
  ng "빈 껍데기를 채택했다" "확인 파일이 없는데 찾았다고 말한다"
else
  ok "③ ⭐ 확인 파일이 없으면 못 찾은 것으로 본다(틀린 경로를 주지 않는다)"
fi

# ④ ⭐ 대조군 — 아무 데도 없으면 rc 1 이고 출력이 비어 있다
got=$(CLAUDE_PLUGIN_ROOT="$SB/empty/go-review" sibling_plugin go-없는것 x/y 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ok "④ 없으면 rc 1 · 빈 출력" || ng "부재 처리" "rc=$rc out=$got"
export HOME="$HOME_ORIG"
rm -rf "$SB"

echo "=== ⭐⭐ 이 세션의 초안이 둘 이상일 때 (2026-09-16)"
# 실측: draft_pick 이 이름순 첫 것에서 멈춰 뒤엣것이 **존재조차 보이지 않았다.**
# 그날 승인 범위(P1~P6)는 뒤 초안의 단계 구성이었고, 안내대로 따랐으면 승인받지 않은
# 계획을 착수했을 것이다. ⚠ 고르는 것을 막지 않는다 — 위험한 것은 **조용한 것**이다.
setup
mkdir -p "$T/.claude/plans/20260916-aaa" "$T/.claude/plans/20260916-zzz"
printf '%s' "$DRAFT" > "$T/.claude/plans/20260916-aaa/draft.md"
printf '%s' "$DRAFT" > "$T/.claude/plans/20260916-zzz/draft.md"
setmtime "$T/.claude/plans/20260916-aaa/draft.md" "$NOW"
setmtime "$T/.claude/plans/20260916-zzz/draft.md" "$NOW"
out=$(run "/go-review:go P1~P6")
printf '%s' "$out" | grep -q '이 세션의 초안이 더 있다' && ok "① 나머지 초안이 있다고 말한다" || ng "둘째 초안 침묵" "$out"
printf '%s' "$out" | grep -q 'zzz' && ok "①-b 어느 것인지 이름을 말한다" || ng "이름 누락" "$out"
printf '%s' "$out" | grep -q '계획 초안 있음' && ok "①-c 그래도 하나를 지목한다(착수를 막지 않는다)" || ng "지목 실패" "$out"
cleanup

setup
printf '%s' "$DRAFT" > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go-review:go 전부")
printf '%s' "$out" | grep -q '이 세션의 초안이 더 있다' && ng "② 초안 하나인데 알렸다" "$out" \
  || ok "② 대조군 — 초안이 하나면 조용하다"
cleanup

echo "=== ⭐⭐ 위임 판정 격자 축 (2026-09-16)"
# plan.md §6-b 2단계가 항목마다 격자 판정을 요구한다. 이 축은 **세기만** 한다 —
# 차단하지 않는 것이 규약이고, 「명세부터」 갈래가 나와도 통과시켜야 한다(그것도 정상 판정이다).

GRID_HEAD='# 제목

## 목표 계약
원 요청: "격자를 시험한다"
수용 기준:
  - 판정이 항목마다 붙는다
범위 밖: 없음

## 결정 필요(승인 전)
- [x] Q1 [질문] 무엇 — 답: 그것

## P1
'

setup
# ① 판정이 전부 있으면 조용하다(✅ 로만 말한다)
{ printf '%s' "$GRID_HEAD"
  printf -- '- [ ] P1-1 하나\n      · **테스트부터(위임 가능 full)** — 순수 테스트다\n'
  printf -- '- [ ] P1-2 둘\n      · **로컬 구현** — 명세 있음 · 테스트 있음 · 파일 1\n'
  printf -- '- [ ] P1-3 셋\n      · **세션 모델** — 되돌리기 어렵다\n'
  printf -- '- [ ] P1-4 넷\n      · **명세부터** — 경계가 안 정해졌다\n'
} > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go-review:go 전부")
printf '%s' "$out" | grep -q '위임 판정: 작업 항목 4개 전부에 있다' \
  && ok "① 판정이 전부 있으면 ✅ 로 말한다(결정 절 항목은 세지 않는다)" || ng "전부 있음" "$out"

# ④ ⭐ 「명세부터」 갈래가 있어도 **통과시킨다** — 그 갈래가 쓸 수 있어야 격자가 도는 것이다
printf '%s' "$out" | grep -q '명세부터.*착수하지' \
  && ng "명세부터를 막았다" "그 갈래는 정상 판정이다" \
  || ok "④ ⭐ 「명세부터」 판정이 있어도 막지 않는다"
cleanup

# ② 하나 빠지면 개수와 함께 말한다
setup
{ printf '%s' "$GRID_HEAD"
  printf -- '- [ ] P1-1 하나\n      · **테스트부터(위임 가능 full)** — 순수 테스트다\n'
  printf -- '- [ ] P1-2 둘\n      · **로컬 구현** — 파일 1\n'
  printf -- '- [ ] P1-3 셋\n      · **세션 모델** — 되돌리기 어렵다\n'
  printf -- '- [ ] P1-4 넷 (판정 없음)\n'
} > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go-review:go 전부")
printf '%s' "$out" | grep -q '3/4 항목' && ok "② 빠진 항목이 있으면 3/4 로 센다" || ng "부분 누락" "$out"
cleanup

# ③ 격자가 아예 없는 옛 형식 초안 — 「하나도 없다」로 말한다(차단은 아니다)
setup
{ printf '%s' "$GRID_HEAD"
  printf -- '- [ ] P1-1 하나\n- [ ] P1-2 둘\n- [ ] P1-3 셋\n- [ ] P1-4 넷\n'
} > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go-review:go 전부")
printf '%s' "$out" | grep -q '위임 판정이 하나도 없다' && ok "③ 옛 형식은 「하나도 없다」로 알린다" || ng "옛 형식" "$out"
printf '%s' "$out" | grep -q '승인할 계획이 없다' && ng "옛 형식을 차단했다" "알림이어야 한다" \
  || ok "③-b 옛 형식이어도 착수를 막지는 않는다"
cleanup

# ⑤ ⭐⭐ 대조군 — **본문 산문에 판정 이름이 나와도 세지 않는다**
#   격자 자체를 도입하는 계획이 그렇다(자기 참조). `·` 로 시작하는 표기 줄만 세는지 확인한다.
setup
{ printf '%s' "$GRID_HEAD"
  printf -- '- [ ] P1-1 격자를 넣는다 — 판정은 **명세부터** · **테스트부터** · **로컬 구현** 다섯이다\n'
  printf -- '- [ ] P1-2 둘\n- [ ] P1-3 셋\n- [ ] P1-4 넷\n'
} > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go-review:go 전부")
printf '%s' "$out" | grep -q '위임 판정이 하나도 없다' \
  && ok "⑤ ⭐⭐ 산문 속 판정 이름은 세지 않는다(표기 줄만 센다)" || ng "산문 오탐" "$out"
cleanup

# ⑥ 항목이 적으면(4 미만) 말하지 않는다 — 두 줄짜리 계획에 잔소리하지 않는다
setup
{ printf '%s' "$GRID_HEAD"; printf -- '- [ ] P1-1 하나\n- [ ] P1-2 둘\n'; } > "$T/.claude/plan-draft.md"
setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go-review:go 전부")
printf '%s' "$out" | grep -q '위임 판정' && ng "작은 계획에 발화" "$out" || ok "⑥ 항목 4개 미만이면 조용하다"
cleanup

# ⑦ ⭐⭐ 고정 절(`## R — 리뷰` · `## C — 자원 회수`)은 판정을 요구하지 않는다
#   go.md §3·§3-c 가 그 두 절의 형식을 정해 주는데 거기엔 판정 표기가 없다. 빼지 않으면
#   **모든 계획이 언제나 붉고**, 언제나 붉은 검사는 아무도 보지 않는다.
#   실측(2026-09-16): 이 축을 처음 붙였을 때 실제 계획에서 빠진 5건이 전부 그 두 절이었다.
setup
{ printf '%s' "$GRID_HEAD"
  printf -- '- [ ] P1-1 하나\n      · **로컬 구현** — 파일 1\n'
  printf -- '- [ ] P1-2 둘\n      · **세션 모델** — 되돌리기 어렵다\n'
  printf -- '- [ ] P1-3 셋\n      · **테스트부터(위임 가능 full)** — 순수 테스트다\n'
  printf -- '- [ ] P1-4 넷\n      · **명세부터** — 경계가 안 정해졌다\n'
  printf '\n## R — 리뷰\n- [ ] R1 review-loop 1회\n- [ ] R2 must_fix 반영 후 게이트 재통과\n'
  printf '\n## C — 자원 회수\n- [ ] C1 worker-release\n- [ ] C2 cleanup --apply\n- [ ] C3 opt-in.json 삭제\n'
} > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go-review:go 전부")
printf '%s' "$out" | grep -q '위임 판정: 작업 항목 4개 전부에 있다' \
  && ok "⑦ ⭐⭐ R·C 절의 5항목은 판정 대상에서 뺀다" || ng "고정 절 오탐" "$out"
cleanup

# ⑦-b 대조군 — 고정 절 **밖**의 항목은 그대로 센다(제외가 너무 넓어지지 않았나)
setup
{ printf '%s' "$GRID_HEAD"
  printf -- '- [ ] P1-1 하나\n      · **로컬 구현** — 파일 1\n'
  printf -- '- [ ] P1-2 둘 (판정 없음)\n'
  printf -- '- [ ] P1-3 셋\n      · **세션 모델** — 되돌리기 어렵다\n'
  printf -- '- [ ] P1-4 넷\n      · **명세부터** — 경계가 안 정해졌다\n'
  printf '\n## R — 리뷰\n- [ ] R1 review-loop 1회\n'
  printf '\n## P2 — 고정 절 다음에도 작업 절이 올 수 있다\n'
  printf -- '- [ ] P2-1 다섯 (판정 없음)\n'
} > "$T/.claude/plan-draft.md"; setmtime "$T/.claude/plan-draft.md" "$NOW"
out=$(run "/go-review:go 전부")
printf '%s' "$out" | grep -q '3/5 항목' \
  && ok "⑦-b 고정 절 뒤에 온 작업 절은 다시 센다(제외가 절 경계에서 끝난다)" || ng "제외 범위" "$out"
cleanup

printf '\npass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
