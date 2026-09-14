#!/usr/bin/env bash
# todo-completion-gate.sh 대조군 테스트
# ⚠ 절대경로를 박지 마라 — 플러그인으로 옮기면 **다른 레포의 스크립트**를 검사한다.
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
H="$SELF/todo-completion-gate.sh"
D=$(mktemp -d)
pass=0; fail=0


# ⚠ 반복 실행 위생 — 세션당 차단 상한(8) 카운터가 $TMPDIR 에 남는다.
#   비우지 않으면 두 번째 실행부터 상한에 걸려 **차단 기대 케이스가 거짓 통과**한다
#   (2026-09-02 실측: claude-todo-gate-<세션> 이 8 이 되어 6건이 got=PASS 로 뒤집혔다).
rm -f "${TMPDIR:-/tmp}"/claude-todo-gate-* 2>/dev/null || true

mk() { # $1=file $2=todos-json
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TodoWrite\",\"input\":{\"todos\":$2}}]}}" > "$D/$1"
}

run() { # $1=label $2=transcript $3=session $4=expect(BLOCK|PASS)
  out=$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$3" "$2" | bash "$H")
  got=$(printf '%s' "$out" | jq -r '.decision // "PASS"' 2>/dev/null)
  [ -z "$got" ] && got=PASS
  if [ "$got" = "$4" ] || { [ "$4" = "BLOCK" ] && [ "$got" = "block" ]; }; then
    echo "  ok   $1  → $got"; pass=$((pass+1))
  else
    echo "  FAIL $1  → got=$got want=$4"; fail=$((fail+1))
  fi
}

echo "=== 발화해야 하는 경우"
mk t1.jsonl '[{"content":"1단계","status":"completed"},{"content":"2단계","status":"pending"},{"content":"3단계","status":"pending"}]'
run "미완료 2개 남음" "$D/t1.jsonl" s-block1 BLOCK

mk t2.jsonl '[{"content":"진행중","status":"in_progress"}]'
run "in_progress 도 미완료" "$D/t2.jsonl" s-block2 BLOCK

echo "=== 조용해야 하는 경우(오탐 방지)"
mk t3.jsonl '[{"content":"1단계","status":"completed"},{"content":"2단계","status":"completed"}]'
run "전부 completed" "$D/t3.jsonl" s-pass1 PASS

printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"todo 없음"}]}}' > "$D/t4.jsonl"
run "TodoWrite 자체가 없음" "$D/t4.jsonl" s-pass2 PASS

run "transcript 파일 부재" "$D/없는파일.jsonl" s-pass3 PASS

echo "=== 마지막 TodoWrite 만 본다(과거 미완료는 무시)"
{ printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"a","status":"pending"}]}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"a","status":"completed"}]}}]}}'
} > "$D/t5.jsonl"
run "옛 pending → 최신 completed" "$D/t5.jsonl" s-pass4 PASS

echo "=== 낡은 계획 판별(2026-08-19) — 사용자가 계획 이후 말했나"
# ⭐ 이 두 대조군이 이 판별의 전부다. 하나만 있으면 「전부 통과」와 구분되지 않는다.

# ① 계획이 **마지막 사용자 메시지 뒤** → 원래 잡으려던 경우. 여전히 차단돼야 한다.
{ printf '%s\n' '{"type":"user","message":{"content":"C1~C6 다 해줘"}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"C1","status":"completed"},{"content":"C2","status":"pending"}]}}]}}'
} > "$D/t6.jsonl"
run "계획이 사용자 메시지 뒤 → 차단 유지" "$D/t6.jsonl" s-stale1 BLOCK

# ② 사용자가 그 계획 **이후로** 말했다 → 낡은 목록. 붙잡으면 오탐이다.
#    (실사고: TodoWrite 도구가 MCP 단절로 사라져 목록을 닫을 수단이 없었다.)
{ printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"C1","status":"completed"},{"content":"C2","status":"pending"}]}}]}}'
  printf '%s\n' '{"type":"user","message":{"content":"다른 걸 먼저 해줘"}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"했습니다"}]}}'
} > "$D/t7.jsonl"
run "사용자가 계획 이후 말함 → 통과" "$D/t7.jsonl" s-stale2 PASS

# ③ 사용자 메시지가 **아예 없는** transcript → 판별 불가. 모르는 것으로 게이트를 열지 않는다.
mk t8.jsonl '[{"content":"C2","status":"pending"}]'
run "사용자 메시지 없음 → 차단 유지(판별 포기)" "$D/t8.jsonl" s-stale3 BLOCK

echo "=== ⭐ 도구 결과는 「사용자 메시지」가 아니다(2026-08-22 무장해제 사고)"
# 실사고: 도구 결과도 type:"user" 로 기록되는데(실측 user 행의 92.9%) 그것까지 세는 바람에
# TodoWrite 뒤에 도구가 한 번만 더 돌아도 「낡은 계획」이 되어 게이트가 **항상** 통과했다.
# 라이브 12/12 재현. ⚠ 위 t6/t7 가 이것을 못 잡았다 — 도구결과가 섞인 모양을 재현하지 않아서다.

# ④ 사람 지시 → 계획 → 그 턴 안에서 도구가 더 돎(도구결과 user 행) → 여전히 차단돼야 한다.
{ printf '%s\n' '{"type":"user","message":{"content":"C1~C6 다 해줘"}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"C1","status":"completed"},{"content":"C2","status":"pending"}]}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'
  printf '%s\n' '{"type":"user","toolUseResult":{"stdout":"a.txt"},"message":{"content":[{"type":"tool_result","content":"a.txt"}]}}'
} > "$D/t9.jsonl"
run "계획 뒤 도구결과만 있음 → 차단 유지" "$D/t9.jsonl" s-tool1 BLOCK

# ⑤ ⭐ 반대 방향(2026-09-02 개정) — 사람 지시가 목록보다 **뒤**여도 이제는 차단이다.
#    ⚠⚠ 여기 있던 케이스가 「마지막 발화 뒤면 낡음」을 **정답으로 고정**하고 있었고,
#      그것이 이 게이트를 구조적으로 무력화했다. 대화형 세션은 사람 발화가 목록 뒤에
#      오는 것이 정상이므로 그것으로 낡음을 판정하면 **목록을 만든 턴에만** 무장된다.
#      기준을 **첫** 발화로 바꿨으므로 이 모양은 차단이 옳다.
#    이 케이스가 지키는 것: 도구 결과·isMeta 를 **첫 발화 판별에서도** 제외한다
#    (안 걸러 첫 행 도구결과를 첫 발화로 세면 그 뒤의 TodoWrite 가 「세션 전」으로 오판된다).
{ cat "$D/t9.jsonl"
  printf '%s\n' '{"type":"user","message":{"content":"다른 걸 먼저 해줘"}}'
} > "$D/t10.jsonl"
run "⭐ 도구결과 뒤 사람 지시 → **차단**(첫 발화가 기준이다)" "$D/t10.jsonl" s-tool2 BLOCK

# ⑤-b ⭐⭐ 다중 턴 — 이 픽스처가 없어서 게이트가 무장해제돼 있었다
#     사람 발화 → TodoWrite(미완료) → 사람 발화 → Stop. 실사용에서 가장 흔한 모양이다.
{ printf '%s\n' '{"type":"user","message":{"content":"P0~P4 해줘"}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"P1","status":"completed"},{"content":"P2","status":"pending"}]}}]}}'
  printf '%s\n' '{"type":"user","toolUseResult":{},"message":{"content":[]}}'
  printf '%s\n' '{"type":"user","message":{"content":"계속해줘"}}'
} > "$D/t11.jsonl"
run "⭐ 사람→목록→사람 (실사용 모양) → **차단**" "$D/t11.jsonl" s-multi BLOCK

# ⑤-c 사보타주 — tail -1(마지막 발화)로 되돌리면 위 케이스가 통과한다
SAB="$D/todo-sab.sh"
sed -e 's/| head -1)/| tail -1)/' -e 's/\[ "\$todo_at" -lt "\$user_at" \]/[ "$user_at" -gt "$todo_at" ]/' "$H" > "$SAB"
outs=$(printf '{"session_id":"s-sab","transcript_path":"%s","stop_hook_active":false}' "$D/t11.jsonl" | bash "$SAB")
if printf '%s' "$outs" | grep -q '"block"'; then
  echo "  FAIL 사보타주가 발화하지 않았다 — 이 테스트는 무엇도 지키지 않는다"; fail=$((fail+1))
else
  echo "  ok   ⭐ 사보타주하면 통과한다(= 그것이 무장해제의 정체였다)"; pass=$((pass+1))
fi
rm -f "$SAB"

# ⑥ isMeta(스킬·슬래시명령 주입)는 사람 지시가 아니다 → 차단 유지.
{ cat "$D/t9.jsonl"
  printf '%s\n' '{"type":"user","isMeta":true,"message":{"content":"Base directory for this skill: /x"}}'
} > "$D/t11.jsonl"
run "isMeta 주입은 사람 아님 → 차단 유지" "$D/t11.jsonl" s-tool3 BLOCK

echo "=== 무한루프 상한"
CLAUDE_TODO_GATE_MAX=2
export CLAUDE_TODO_GATE_MAX
s=s-cap-$$
run "1회차" "$D/t1.jsonl" "$s" BLOCK
run "2회차" "$D/t1.jsonl" "$s" BLOCK
run "3회차(상한 도달 → 통과)" "$D/t1.jsonl" "$s" PASS
unset CLAUDE_TODO_GATE_MAX

echo "=== 라이브 transcript(직전 세션 실물 — 기대값은 데이터에서 파생)"
# ⭐ 실물 transcript 로 한 번은 돌려라 — 합성 입력만으로는 「내 파서가 실제 포맷을 읽나」에
#   답하지 못한다. 원 레포에서 이 훅이 3일간 무장해제돼 있던 것을 잡은 것이 이 대조군이다.
# ⚠ 절대경로를 박지 마라(기계마다 다르다). 지정이 없으면 **가장 최근** transcript 를 쓰고,
#   하나도 없으면 조용히 건너뛴다 — 다만 "건너뛰었다"고 **말한다**(정직 공백).
LIVE="${CLAUDE_GATE_LIVE_TRANSCRIPT:-}"
if [ -z "$LIVE" ]; then
  LIVE=$(ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -1)
fi
if [ -n "$LIVE" ] && [ -f "$LIVE" ]; then
  # ⚠ 기대값을 손으로 적지 마라. 처음에 "3 pending 이니 BLOCK" 이라 적었다가 틀렸다 —
  #    그 파일의 *마지막* TodoWrite 는 전부 completed 였다(3 pending 은 그 앞 건).
  n=$(jq -c 'select(.type=="assistant") | .message.content[]?
             | select(.type=="tool_use" and .name=="TodoWrite") | .input.todos' "$LIVE" 2>/dev/null \
      | tail -1 | jq '[.[] | select(.status != "completed")] | length' 2>/dev/null)
  want=PASS; [ "${n:-0}" -gt 0 ] 2>/dev/null && want=BLOCK
  run "실물 파싱(미완료 ${n:-0}개 → $want)" "$LIVE" s-live "$want"
else
  echo "  skip 실물 transcript 없음 — CLAUDE_GATE_LIVE_TRANSCRIPT 로 지정하면 이 대조군이 돈다"
fi

echo
echo "pass=$pass fail=$fail"
rm -rf "$D"
[ "$fail" -eq 0 ]
