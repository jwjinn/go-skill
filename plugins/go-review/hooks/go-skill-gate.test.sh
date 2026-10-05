#!/usr/bin/env bash
# go-skill-gate.sh 대조군. 실행: bash <플러그인>/hooks/go-skill-gate.test.sh
#
# 이 훅의 본체는 「모델이 스스로 /go 를 부를 때, 승인받을 모양이 아니면 거부한다」다.
# 그러니 거부해야 할 때 exit 2 가 나는지(대조군)와 **엉뚱한 호출을 막지 않는지**(다른 Skill · 다른 도구 ·
# 이미 채택된 계획 · 깨진 입력)를 함께 잰다. 막지 않아야 할 것을 막으면 사람은 훅을 끈다.
set -u
HOOK="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/go-skill-gate.sh"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
ng(){ printf '  NG   %s  (%s)\n' "$1" "$2"; fail=$((fail+1)); }
command -v jq >/dev/null 2>&1 || { echo "jq 없음 — 채택 판별(plan_session_claims)이 rc 2 로만 돌아 이 시험이 뜻을 잃는다. 건너뛴다"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
B="$T/.claude"; S="$B/plans/20261005-x"; mkdir -p "$S"
D="$S/draft.md"; TR="$T/tr.jsonl"

GOOD='# 계획
## 목표 계약
원 요청: "채널을 고쳐 줘"
## 요구 추적
추적 시작: 2026-10-05T01:00:00Z
| 발화 | 분류 | 대응 |
|---|---|---|
| 알림 전송 채널을 고쳐 줘 | 요구 | P1-1 |
## 결정 필요(승인 전)
- [x] Q-A 방식 — 닫힘
## 이전 결정 대조
- 다른 계획 없음
## P1
- [ ] P1-1 채널
## V — 최종 검증
- [ ] V1 수용 기준 충족표
- [ ] V2 독립 검증자
'
# 대화 기록: 사람 발화 하나 + 이 세션이 초안을 Write 한 흔적(채택 판별의 근거)
mk_tr(){ python3 - "$TR" "$1" <<'PY'
import json,sys
tr,path=sys.argv[1],sys.argv[2]
L=[dict(type="user",timestamp="2026-10-05T02:00:00Z",uuid="u1",message={"role":"user","content":"알림 전송 채널을 고쳐 줘 지금 안 보인다"})]
if path:
    L.append(dict(type="assistant",timestamp="2026-10-05T02:01:00Z",uuid="a1",message={"role":"assistant","content":[
        {"type":"tool_use","id":"t1","name":"Write","input":{"file_path":path,"content":"…"}}]}))
open(tr,"w").write("\n".join(json.dumps(x,ensure_ascii=False) for x in L)+"\n")
PY
}
call(){  # <tool> <skill>
  python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"skill":sys.argv[2]},"transcript_path":sys.argv[3],"session_id":"s"}))' "$1" "$2" "$TR" \
    | CLAUDE_PROJECT_DIR="$T" bash "$HOOK" 2>"$T/err" >/dev/null; echo $?
}

echo "=== 막지 않아야 할 것"
printf '%s' "$GOOD" > "$D"; mk_tr "$D"
rc=$(call Bash ""); [ "$rc" = 0 ] && ok "Skill 이 아닌 도구 → 통과" || ng "다른 도구" "rc $rc"
rc=$(call Skill "go-review:plan"); [ "$rc" = 0 ] && ok "다른 Skill(go-review:plan) → 통과" || ng "다른 skill" "rc $rc"
rc=$(call Skill "go-review:go"); [ "$rc" = 0 ] && ok "모양이 다 갖춰진 초안 → 통과" || ng "통과 사례" "rc $rc · $(cat "$T/err")"
rc=$(printf '이건 JSON 이 아니다' | CLAUDE_PROJECT_DIR="$T" bash "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" = 0 ] && ok "깨진 입력 → 통과(훅 고장은 통과)" || ng "깨진 입력" "rc $rc"

echo "=== 막아야 할 것(대조군)"
printf '%s' "$GOOD" | sed 's/^- \[x\] Q-A 방식 — 닫힘$/- [ ] Q-A 방식 — 사용자 선택 대기/' > "$D"
rc=$(call Skill "go-review:go"); [ "$rc" = 2 ] && grep -q '열린 항목 1건' "$T/err" && ok "열린 결정 1건 → 거부 + 사유" || ng "열린 결정" "rc $rc · $(cat "$T/err")"
printf '%s' "$GOOD" | sed 's/^## 요구 추적$/## 요구/' > "$D"
rc=$(call Skill "go-review:go"); [ "$rc" = 2 ] && grep -q '요구 추적' "$T/err" && ok "요구 추적 절 없음 → 거부" || ng "요구 추적 없음" "rc $rc · $(cat "$T/err")"
printf '%s' "$GOOD" | grep -v '독립 검증자' > "$D"
rc=$(call Skill "go"); [ "$rc" = 2 ] && grep -q '독립 검증' "$T/err" && ok "V 절에 독립 검증 없음 → 거부(skill 이름 'go' 도 본다)" || ng "V 없음" "rc $rc"
printf '%s' "$GOOD" > "$D"; mk_tr ""   # 이 세션이 초안을 쓴 흔적이 없다 → 남의 초안
rc=$(call Skill "go-review:go"); [ "$rc" = 2 ] && grep -q '초안' "$T/err" && ok "이 세션의 초안이 없음(남의 초안만) → 거부" || ng "남의 초안" "rc $rc · $(cat "$T/err")"

echo "=== 경로 ① — 이미 채택된 계획은 이어 간다"
rm -f "$D"; printf '%s' "$GOOD" | sed 's/^## 요구 추적$/## 요구/' > "$S/plan.md"; mk_tr "$S/plan.md"
rc=$(call Skill "go-review:go"); [ "$rc" = 0 ] && ok "이 세션이 채택한 미완료 plan.md → 통과(이미 승인된 계획)" || ng "경로 ①" "rc $rc · $(cat "$T/err")"

echo
echo "합계: 통과 $pass · 실패 $fail"
[ "$fail" -eq 0 ]
