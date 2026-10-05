#!/usr/bin/env bash
# _plancheck.py 대조군. 실행: bash <플러그인>/hooks/plancheck.test.sh
#
# 이 검사기가 잡으려는 것은 「초안이 요구를 빠뜨렸다」·「닫힌 결정을 대조하지 않았다」·「최종 검증 단계가 없다」다.
# 그러니 시험의 본체는 **통과 사례가 아니라 빠뜨린 사례가 붉어지는지**다 — 행 하나를 지우면 rc 1 이 나와야 하고,
# 사람 발화가 아닌 줄(도구 결과 · 작업 알림 · 다른 에이전트 보고)은 세지 않아야 한다.
set -u
PC="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_plancheck.py"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
ng(){ printf '  NG   %s  (%s)\n' "$1" "$2"; fail=$((fail+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
B="$T/.claude"; mkdir -p "$B/plans/20261005-new" "$B/plans/20261004-old"
TR="$T/tr.jsonl"

# ── 대화 기록 픽스처 — 사람 발화 넷 + 사람이 아닌 줄 여섯 ─────────────────────────
python3 - "$TR" <<'PY'
import json,sys
L=[]
def u(ts,content,**kw): L.append(dict(type="user",timestamp=ts,uuid="u"+ts,message={"role":"user","content":content},**kw))
u("2026-10-05T01:00:00Z","이 줄은 추적 시작 전의 발화라서 세지 않는다")
u("2026-10-05T02:00:00Z","알림 전송 채널은 지금 안보이는데 고쳐 줘")                       # 사람 ①
u("2026-10-05T02:01:00Z",[{"type":"text","text":"GPU 맵에서 노드 이름을 쿠버 이름으로 바꾸자"},{"type":"image"}])  # 사람 ②
u("2026-10-05T02:02:00Z","응")                                                              # 짧은 응답 — 세지 않는다
u("2026-10-05T02:03:00Z",[{"type":"tool_result","content":"도구 결과 안의 긴 문장은 사람 발화가 아니다"}])
u("2026-10-05T02:04:00Z","스킬 본문이 주입된 줄은 사람 발화가 아니다 길게 길게",isMeta=True)
u("2026-10-05T02:05:00Z","Another Claude session sent a message: 에이전트 보고는 사람 발화가 아니다")
L.append(dict(type="attachment",timestamp="2026-10-05T02:06:00Z",uuid="a1",attachment=dict(
  type="queued_command",prompt="작업 중에 보낸 메시지도 요구다 이상탐지 화면을 빼자",source_uuid="s1",commandMode="prompt",origin="{'kind': 'human'}")))  # 사람 ③
L.append(dict(type="attachment",timestamp="2026-10-05T02:07:00Z",uuid="a2",attachment=dict(
  type="queued_command",prompt="<task-notification>배경 작업이 끝났다는 알림</task-notification>",source_uuid="s2",commandMode="task-notification",origin="{'kind': 'task-notification'}")))
L.append(dict(type="user",timestamp="2026-10-05T02:08:00Z",uuid="u9",message={"role":"user","content":[{"type":"tool_result","content":"x"}]},
  toolUseResult={"questions":[{"question":"Q1","options":[{"label":"A안"},{"label":"B안"}]},{"question":"Q2","options":[{"label":"예"}]}],
                 "answers":{"Q1":"A와 B를 같이 하고 싶네 토글로 보여 줘","Q2":"예"}}))  # 사람 ④(직접 입력) · 「예」는 선택지 그대로라 세지 않는다
open(sys.argv[1],"w").write("\n".join(json.dumps(x,ensure_ascii=False) for x in L)+"\n")
PY

echo "=== 사람 발화 뽑기"
out=$(python3 "$PC" humans --transcript "$TR" --since 2026-10-05T01:30:00Z); n=$(printf '%s\n' "$out" | grep -c .)
[ "$n" -eq 5 ] && ok "추적 시작 뒤 사람 줄 5개(긴 발화 4 + 짧은 응답 1)" || ng "사람 줄 수" "$n · $out"
printf '%s' "$out" | grep -q '작업 중에 보낸 메시지도' && ok "작업 중 메시지(queued_command · human)를 센다" || ng "queued human" "$out"
printf '%s' "$out" | grep -q 'A와 B를 같이' && ok "질문 도구에 직접 입력한 답을 센다" || ng "직접 입력 답" "$out"
printf '%s' "$out" | grep -qE '도구 결과 안의|스킬 본문|에이전트 보고|배경 작업|추적 시작 전' && ng "사람이 아닌 줄이 섞였다" "$out" || ok "도구 결과·isMeta·에이전트 보고·작업 알림·시작 전 줄은 빠진다"
# ⚠ 맥 grep 은 -P 가 없다 — 오류가 나면 「|| ok」로 빠져 탐지기가 죽은 채 초록이 된다(2026-10-05 첫 실행에서 실제로 그랬다).
#   그래서 판정을 파이썬으로 하고, 그 판정기가 살아 있는지 같은 자리에서 대조군으로 확인한다.
has_label_ans(){ printf '%s\n' "$1" | python3 -c 'import sys; sys.exit(0 if any(l.rstrip("\n").split("\t")[-1]=="예" for l in sys.stdin) else 1)'; }
has_label_ans "$out" && ng "선택지 그대로 고른 답이 섞였다" "$out" || ok "선택지를 그대로 고른 답은 요구로 세지 않는다"
has_label_ans "$(printf '2026-10-05T00:00:00\t예')" && ok "대조군: 그 판정기는 「예」 줄을 실제로 잡는다" || ng "판정기 죽음" "선택지 답 판정기가 아무것도 못 잡는다"

GOOD='# 새 계획

## 목표 계약
원 요청: "…"

## 요구 추적
추적 시작: 2026-10-05T01:30:00Z
| 발화(인용) | 분류 | 대응 |
|---|---|---|
| 알림 전송 채널은 지금 안보이는데 | 요구 | P1-1 |
| 노드 이름을 쿠버 이름으로 | 요구 | P2-1 |
| 이상탐지 화면을 빼자 | 요구 | P3-1 |
| A와 B를 같이 하고 싶네 | 결정 | Q-N |

## 결정 필요(승인 전)
- [x] Q-N 노드 자원 — 합본

## 이전 결정 대조
- 20261004-old: 「자격 증명 암호화 현행 유지」와 부딪히는 항목 없음

## P1
- [ ] P1-1 채널
## P2
- [ ] P2-1 노드 이름
## P3
- [ ] P3-1 이상탐지 제거

## V — 최종 검증
- [ ] V1 수용 기준 충족표
- [ ] V2 독립 검증자가 다시 잰다
'
OLD='# 옛 계획
## 목표 계약
범위 밖: 자격 증명 암호화(현행 유지)
## 결정 필요(승인 전)
- [x] Q12 자격 증명 암호화 — 현행 유지
'
D="$B/plans/20261005-new/draft.md"
printf '%s' "$OLD" > "$B/plans/20261004-old/plan.md"
put(){ printf '%s' "$1" > "$D"; }
pc(){ python3 "$PC" "$@" --draft "$D" --transcript "$TR" --base "$B" >"$T/out" 2>&1; echo $?; }

echo "=== 요구 추적"
put "$GOOD"; rc=$(pc reqtrace); [ "$rc" = 0 ] && ok "네 발화가 모두 표에 있으면 rc 0" || ng "통과 사례" "rc $rc · $(cat "$T/out")"
grep -q '사람 발화 5건(짧은 응답 1건 제외)' "$T/out" && ok "출력이 센 수(사람 발화 · 짧은 응답)를 밝힌다" || ng "수 표기" "$(cat "$T/out")"
put "$(printf '%s' "$GOOD" | grep -v '이상탐지 화면을 빼자 |')"; rc=$(pc reqtrace)
[ "$rc" = 1 ] && grep -q '이상탐지 화면을 빼자' "$T/out" && ok "대조군: 작업 중 메시지 행을 지우면 rc 1 + 그 발화를 지목" || ng "대조군 queued" "rc $rc · $(cat "$T/out")"
put "$(printf '%s' "$GOOD" | grep -v 'A와 B를 같이')"; rc=$(pc reqtrace)
[ "$rc" = 1 ] && ok "대조군: 직접 입력한 답의 행을 지우면 rc 1" || ng "대조군 답" "rc $rc"
put "$(printf '%s' "$GOOD" | sed 's/^추적 시작:.*$//')"; rc=$(pc reqtrace)
[ "$rc" = 1 ] && grep -q '추적 시작' "$T/out" && ok "추적 시작 줄이 없으면 rc 1" || ng "추적 시작 없음" "rc $rc"
put "$(printf '%s' "$GOOD" | sed 's/| P2-1 |/| P9-9 |/')"; rc=$(pc reqtrace)
[ "$rc" = 1 ] && grep -q 'P9-9' "$T/out" && ok "대응 항목이 초안에 없는 번호면 rc 1" || ng "없는 항목" "rc $rc · $(cat "$T/out")"
put "$(printf '%s' "$GOOD" | sed 's/^## 요구 추적$/## 요구사항/')"; rc=$(pc reqtrace)
[ "$rc" = 1 ] && ok "요구 추적 절이 없으면 rc 1" || ng "절 없음" "rc $rc"
put "$GOOD"; rc=$(python3 "$PC" reqtrace --draft "$D" --transcript "$T/없음.jsonl" --base "$B" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] && ok "대화 기록이 없으면 rc 2(통과가 아니다)" || ng "기록 없음" "rc $rc"
put "$(printf '%s' "$GOOD" | sed 's/^추적 시작:.*$/추적 시작: 2027-01-01T00:00:00Z/')"; rc=$(pc reqtrace)
[ "$rc" = 2 ] && ok "추적 시작 이후 발화 0건이면 rc 2(탐지기부터 의심)" || ng "발화 0건" "rc $rc"

echo "=== 이전 결정 대조"
put "$GOOD"; rc=$(pc decisions); [ "$rc" = 0 ] && ok "다른 계획을 대조했다고 적으면 rc 0" || ng "통과" "rc $rc · $(cat "$T/out")"
put "$(printf '%s' "$GOOD" | sed 's/^- 20261004-old:.*$/- (없음)/')"; rc=$(pc decisions)
[ "$rc" = 1 ] && grep -q '20261004-old' "$T/out" && ok "대조군: 다른 계획 이름이 빠지면 rc 1 + 그 이름" || ng "대조군 slug" "rc $rc"
put "$(printf '%s' "$GOOD" | sed 's/^## 이전 결정 대조$/## 참고/')"; rc=$(pc decisions)
[ "$rc" = 1 ] && ok "절이 없으면 rc 1" || ng "절 없음" "rc $rc"
rc=$(python3 "$PC" decisions --draft "$D" --base "$B" --show >"$T/out" 2>&1; echo $?)
grep -q '현행 유지' "$T/out" && ok "--show 가 다른 계획의 닫힌 결정을 보여 준다" || ng "--show" "$(cat "$T/out")"

echo "=== 최종 검증(V) 절"
put "$GOOD"; rc=$(pc vstage); [ "$rc" = 0 ] && ok "독립 검증 + 수용 기준 충족표가 있으면 rc 0" || ng "통과" "rc $rc"
put "$(printf '%s' "$GOOD" | grep -v '독립 검증자')"; rc=$(pc vstage)
[ "$rc" = 1 ] && grep -q '독립 검증' "$T/out" && ok "대조군: 독립 검증 항목을 지우면 rc 1" || ng "대조군 독립" "rc $rc"
put "$(printf '%s' "$GOOD" | sed 's/^## V — 최종 검증$/## 마무리/')"; rc=$(pc vstage)
[ "$rc" = 1 ] && ok "V 절이 없으면 rc 1" || ng "V 절 없음" "rc $rc"

echo "=== all — 위반이 「잴 수 없음」보다 먼저"
put "$(printf '%s' "$GOOD" | grep -v '독립 검증자')"
rc=$(python3 "$PC" all --draft "$D" --transcript "$T/없음.jsonl" --base "$B" >/dev/null 2>&1; echo $?)
[ "$rc" = 1 ] && ok "rc 2(기록 없음) + rc 1(V 위반) → rc 1" || ng "우선순위" "rc $rc"
put "$GOOD"; rc=$(pc all); [ "$rc" = 0 ] && ok "셋 다 통과면 rc 0" || ng "all 통과" "rc $rc · $(cat "$T/out")"

echo
echo "합계: 통과 $pass · 실패 $fail"
[ "$fail" -eq 0 ]
