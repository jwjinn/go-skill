#!/usr/bin/env bash
# coordinator-inbox-gate.test.sh — 대조군 (2026-09-16 에 worker-question-gate 에서 개명)
#
# ⭐ 실제 orca 를 부르지 않는다. PATH 앞에 가짜 `orca` 를 두어 inbox JSON 을 조종한다.
#   진짜 런타임을 부르면 이 테스트가 그때그때의 워커 상태에 따라 달라진다.
#
# 무엇을 증명하나 — 「미답변이 있으면 막고 · 답하면 통과하고 · 못 재면 통과한다」.
#   특히 세 번째가 중요하다. 판정 불가에 차단하면 orca 를 안 쓰는 세션이 통째로 멈춘다.
#
# ⭐⭐ 2026-09-16 에 축이 셋이 됐다(미답변 question · 미읽음 worker_done · 미읽음 escalation)
#   + run 스코프 + heartbeat 공백 알림. 축마다 「막는다 · 처리하면 통과 · 남의 run 은 통과」
#   셋을 짝으로 두고, 스코프·문구·경계에 사보타주를 붙였다.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/coordinator-inbox-gate.sh"
PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  ⛔ $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 (rc $2)"; else bad "$1 — 기대 rc $3 실제 rc $2"; fi; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"
export TMPDIR="$SB"                     # 카운터 스탬프를 샌드박스로

mk_orca() { # mk_orca <inbox JSON 파일 | NONE | BROKEN> [worker-list JSON 파일 | NONE]
  cat > "$SB/bin/orca" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"worker-list"*)
    case "${2:-NONE}" in
      NONE) exit 0 ;;
      *)    cat "${2:-}" ;;
    esac ;;
  *"inbox"*)
    case "$1" in
      NONE)   exit 1 ;;
      BROKEN) echo "이건 JSON 이 아니다" ;;
      *)      cat "$1" ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$SB/bin/orca"
}
# ⚠ stdin 을 닫고 부른다 — transcript 가 없으면 run 스코프로 좁히지 않는다(종전 동작).
#   스코프를 재는 검사는 아래 `runtr` 를 쓴다.
run(){ rm -f "$SB/coordinator-inbox-gate.$(id -u).count"; PATH="$SB/bin:$PATH" bash "$GATE" >"$SB/out" 2>"$SB/err" </dev/null; echo $?; }
runtr(){ # runtr <transcript> — 그 세션의 기록으로 돌린다
  rm -f "$SB/coordinator-inbox-gate.$(id -u).count"
  printf '{"session_id":"s","transcript_path":"%s","stop_hook_active":false}' "$1" \
    | PATH="$SB/bin:$PATH" bash "$GATE" >"$SB/out" 2>"$SB/err"; echo $?; }

# ── 픽스처 ────────────────────────────────────────────────────────────────
cat > "$SB/pending.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_q1","type":"question","thread_id":"msg_q1","from_handle":"dispatch:ctx_aaa",
  "payload":"{\"question\":\"파일 넷이 필요합니다\"}"}
]}}
JSON
cat > "$SB/answered.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_q1","type":"question","thread_id":"msg_q1","from_handle":"dispatch:ctx_aaa",
  "payload":"{\"question\":\"파일 넷이 필요합니다\"}"},
 {"id":"msg_a1","type":"status","thread_id":"msg_q1","to_handle":"dispatch:ctx_aaa",
  "body":"[코디네이터 답] 승인한다"}
]}}
JSON
cat > "$SB/other-thread.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_q1","type":"question","thread_id":"msg_q1","from_handle":"dispatch:ctx_aaa",
  "payload":"{\"question\":\"파일 넷이 필요합니다\"}"},
 {"id":"msg_a1","type":"status","thread_id":"msg_OTHER","to_handle":"dispatch:ctx_aaa",
  "body":"[코디네이터 답] 다른 스레드에 적었다"}
]}}
JSON
cat > "$SB/empty.json" <<'JSON'
{"result":{"messages":[]}}
JSON
cat > "$SB/two.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_q1","type":"question","thread_id":"msg_q1","from_handle":"dispatch:ctx_aaa","payload":"{\"question\":\"첫째\"}"},
 {"id":"msg_q2","type":"question","thread_id":"msg_q2","from_handle":"dispatch:ctx_bbb","payload":"{\"question\":\"둘째\"}"}
]}}
JSON

echo "== t1. 미답변 질문이 있으면 막는다 =="
mk_orca "$SB/pending.json"; check "차단" "$(run)" "2"
grep -q 'msg_q1' "$SB/err" && ok "질문 id 를 알린다" || bad "id 가 없다"
grep -q '파일 넷이 필요합니다' "$SB/err" && ok "질문 본문을 보여준다" || bad "본문이 없다"

echo "== t2. 답하면 통과한다 =="
mk_orca "$SB/answered.json"; check "통과" "$(run)" "0"

echo "== t3. ⭐ 다른 스레드에 답한 것은 답이 아니다(실측으로 겪은 자리) =="
mk_orca "$SB/other-thread.json"; check "여전히 차단" "$(run)" "2"

echo "== t4. 질문이 없으면 통과 =="
mk_orca "$SB/empty.json"; check "통과" "$(run)" "0"

echo "== t5. ⭐ 판정 불가는 통과한다(차단이 아니다) =="
mk_orca BROKEN;             check "JSON 이 깨져도 통과" "$(run)" "0"
mk_orca NONE;               check "inbox 가 실패해도 통과" "$(run)" "0"
# ⚠ PATH 에서 지우는 것만으로는 「없다」가 안 된다 — 시스템 orca 가 뒤에 남아 **진짜
#   인박스를 읽는다**. 실측으로 이 검사가 그때그때의 파도 상태에 따라 결과가 달라졌다.
rm -f "$SB/bin/orca"
rc=$(rm -f "$SB/coordinator-inbox-gate.$(id -u).count"; PATH="$SB/bin:$PATH" ORCA_BIN=/nonexistent/orca bash "$GATE" >/dev/null 2>&1 </dev/null; echo $?)
check "orca 가 없으면 통과" "$rc" "0"

echo "== t6. 여러 건이면 전부 센다 =="
mk_orca "$SB/two.json"; RC=$(run)
check "차단" "$RC" "2"
grep -q '2건' "$SB/err" && ok "개수를 말한다" || bad "개수가 없다"
grep -q 'msg_q2' "$SB/err" && ok "둘째도 나열한다" || bad "둘째가 빠졌다"

echo "== t7. ⭐ 세션당 상한을 넘으면 통과한다(무한 차단 금지) =="
mk_orca "$SB/pending.json"
rm -f "$SB/coordinator-inbox-gate.$(id -u).count"
LAST=9
for i in 1 2 3; do PATH="$SB/bin:$PATH" CLAUDE_WORKER_Q_GATE_MAX=2 bash "$GATE" >/dev/null 2>&1 </dev/null; LAST=$?; done
check "3회째는 통과" "$LAST" "0"

echo "== t8. ⭐ 대조군의 대조군 — 답변 판정을 사보타주하면 t2 가 붉어진다 =="
SAB="$SB/gate-sab.sh"
sed 's/answers\[t\] = o/pass/' "$GATE" > "$SAB"
mk_orca "$SB/answered.json"
rm -f "$SB/coordinator-inbox-gate.$(id -u).count"
PATH="$SB/bin:$PATH" bash "$SAB" >/dev/null 2>&1 </dev/null; RC=$?
check "답변을 못 세면 통과가 차단으로 바뀐다" "$RC" "2"

echo "== t9. ⛔⛔ 워커 세션에서는 돌지 않는다(2026-09-15 · 워커 둘이 독립 보고) =="
# 이 훅은 브랜치에 커밋돼 모든 워크트리에 퍼진다. 워커도 orca 를 갖고 있어서 **남의 질문
# 때문에 워커의 턴이 막혔다.** 그 워커는 코디네이터 문맥이 없어 답할 수도 없다.
cat > "$SB/wl.json" <<'JSON'
{"result":{"workers":[
 {"agentTerminalHandle":"term_worker_aaa"},
 {"agentTerminalHandle":"term_worker_bbb"}
]}}
JSON
mk_orca "$SB/pending.json" "$SB/wl.json"
rm -f "$SB/coordinator-inbox-gate.$(id -u).count"
PATH="$SB/bin:$PATH" ORCA_TERMINAL_HANDLE=term_worker_aaa bash "$GATE" >"$SB/out" 2>"$SB/err" </dev/null; RC=$?
check "내 핸들이 워커 목록에 있으면 통과" "$RC" "0"

echo "== t10. ⭐ 대조군 — 코디네이터 핸들은 그 목록에 없으므로 그대로 막힌다 =="
# 이것이 없으면 t9 의 수정이 「게이트를 통째로 끈 것」과 구분되지 않는다.
mk_orca "$SB/pending.json" "$SB/wl.json"
rm -f "$SB/coordinator-inbox-gate.$(id -u).count"
PATH="$SB/bin:$PATH" ORCA_TERMINAL_HANDLE=term_coordinator bash "$GATE" >"$SB/out" 2>"$SB/err" </dev/null; RC=$?
check "코디네이터는 차단" "$RC" "2"

echo "== t11. ⭐ 핸들이 없거나 목록을 못 받으면 게이트를 계속 돈다 =="
# 판별 불가를 「나는 워커다」로 읽으면 게이트가 조용히 통째로 꺼진다.
mk_orca "$SB/pending.json" NONE
rm -f "$SB/coordinator-inbox-gate.$(id -u).count"
PATH="$SB/bin:$PATH" ORCA_TERMINAL_HANDLE=term_whatever bash "$GATE" >"$SB/out" 2>"$SB/err" </dev/null; RC=$?
check "worker-list 가 비면 차단이 유지된다" "$RC" "2"
mk_orca "$SB/pending.json" "$SB/wl.json"
rm -f "$SB/coordinator-inbox-gate.$(id -u).count"
PATH="$SB/bin:$PATH" bash "$GATE" >"$SB/out" 2>"$SB/err" </dev/null; RC=$?
check "핸들 환경변수가 없어도 차단이 유지된다" "$RC" "2"

echo "== t12. ⭐ 앞선 답이 뒤에 온 질문까지 덮지 않는다 =="
# 같은 스레드에 질문이 두 번 오면, 첫 답이 두 번째 질문까지 「답했다」로 만들면 안 된다.
cat > "$SB/reask.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_q1","type":"question","thread_id":"msg_t","sequence":1,"from_handle":"dispatch:ctx_aaa","payload":"{\"question\":\"첫 질문\"}"},
 {"id":"msg_a1","type":"status","thread_id":"msg_t","sequence":2,"to_handle":"dispatch:ctx_aaa","body":"답"},
 {"id":"msg_q2","type":"question","thread_id":"msg_t","sequence":3,"from_handle":"dispatch:ctx_aaa","payload":"{\"question\":\"다시 묻는다\"}"}
]}}
JSON
mk_orca "$SB/reask.json"; RC=$(run)
check "답 뒤에 다시 물으면 차단" "$RC" "2"
grep -q '다시 묻는다' "$SB/err" && ok "뒤에 온 질문을 보여준다" || bad "뒤에 온 질문이 빠졌다"


# ════════════════════════════════════════════════════════════════════════════
# ⭐⭐ 2026-09-16 — 축 셋 · run 스코프 · heartbeat 공백
# ════════════════════════════════════════════════════════════════════════════

cat > "$SB/done-unread.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_d1","type":"worker_done","run_id":"run_mine","read":0,"from_handle":"term_w1",
  "subject":"P3 완주 — PR #200","payload":"{\"dispatchId\":\"ctx_aaa\",\"outcome\":\"succeeded\"}"}
]}}
JSON
cat > "$SB/done-read.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_d1","type":"worker_done","run_id":"run_mine","read":1,"from_handle":"term_w1",
  "subject":"P3 완주 — PR #200","payload":"{\"dispatchId\":\"ctx_aaa\"}"}
]}}
JSON
cat > "$SB/esc-unread.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_e1","type":"escalation","run_id":"run_mine","read":0,"from_handle":"term_w1",
  "subject":"게이트가 워커 세션에서 오발화한다"}
]}}
JSON
cat > "$SB/esc-read.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_e1","type":"escalation","run_id":"run_mine","read":1,"from_handle":"term_w1","subject":"읽었다"}
]}}
JSON
cat > "$SB/q-scoped.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_q1","type":"question","run_id":"run_mine","thread_id":"msg_q1","from_handle":"dispatch:ctx_aaa",
  "payload":"{\"question\":\"파일 넷이 필요합니다\"}"}
]}}
JSON
# 이 세션이 run_mine 을 도구로 다룬 기록 / 아무것도 안 다룬 기록
printf '%s\n' '{"type":"user","message":{"content":"파도 봐줘"}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"orca orchestration worker-list --run run_mine --json"}}]}}' > "$SB/tr-mine.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"훅 점검해줘"}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}' > "$SB/tr-other.jsonl"

echo "== t13. ⭐⭐ 축 ② 미읽음 worker_done — 막는다 · 읽었으면 통과 · 남의 run 은 통과 =="
# 실측 2026-09-16: worker_done 40건 중 13건이 미읽음이고 run 7 중 6 에서 소비 0 이었다.
mk_orca "$SB/done-unread.json"; check "미읽음 완료 보고 → 차단" "$(runtr "$SB/tr-mine.jsonl")" "2"
grep -q 'msg_d1' "$SB/err" && ok "메시지 id 를 알린다" || bad "id 가 없다"
grep -q '완료 보고' "$SB/err" && ok "축 이름을 말한다" || bad "축 이름이 없다"
mk_orca "$SB/done-read.json";   check "읽었으면 통과" "$(runtr "$SB/tr-mine.jsonl")" "0"
mk_orca "$SB/done-unread.json"; check "⭐ 남의 run 이면 통과" "$(runtr "$SB/tr-other.jsonl")" "0"

echo "== t14. ⭐⭐ 축 ③ 미읽음 escalation — 같은 셋 =="
mk_orca "$SB/esc-unread.json"; check "미읽음 에스컬레이션 → 차단" "$(runtr "$SB/tr-mine.jsonl")" "2"
grep -q '문제를 알렸는데' "$SB/err" && ok "축 이름을 말한다" || bad "축 이름이 없다"
mk_orca "$SB/esc-read.json";   check "읽었으면 통과" "$(runtr "$SB/tr-mine.jsonl")" "0"
mk_orca "$SB/esc-unread.json"; check "⭐ 남의 run 이면 통과" "$(runtr "$SB/tr-other.jsonl")" "0"

echo "== t15. ⭐ 축 ① question 도 run 스코프를 탄다 =="
mk_orca "$SB/q-scoped.json"; check "내 run 의 질문 → 차단" "$(runtr "$SB/tr-mine.jsonl")" "2"
mk_orca "$SB/q-scoped.json"; check "⭐ 남의 run 의 질문 → 통과" "$(runtr "$SB/tr-other.jsonl")" "0"

echo "== t16. ⛔ transcript 를 못 읽으면 좁히지 않는다(게이트를 끄지 않는다) =="
mk_orca "$SB/done-unread.json"; check "transcript 부재 → 종전대로 차단" "$(runtr "$SB/없는파일.jsonl")" "2"
mk_orca "$SB/done-unread.json"; check "stdin 이 없으면 → 종전대로 차단" "$(run)" "2"

echo "== t17. ⛔⛔ 긴 기록에서도 좁힌다 — 재료를 인자로 넘기면 게이트가 조용히 꺼진다 =="
# 실측(2026-09-16): 관여 재료를 환경변수로 넘겼더니 긴 세션에서 python 호출이 인자 길이
# 상한으로 통째로 실패했고, 그 실패가 `|| exit 0` 을 타고 **통과**가 됐다. 미읽음 5건이
# 있는데 rc 0 이었다. 게이트가 꺼지는 조건이 「세션이 길어지는 것」이면 최악이다.
{ printf '%s\n' '{"type":"user","message":{"content":"긴 세션"}}'
  i=0; while [ $i -lt 400 ]; do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$(printf 'x%.0s' $(seq 1 700))"
    i=$((i+1))
  done
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"orca x --run run_mine"}}]}}'
} > "$SB/tr-long.jsonl"
mk_orca "$SB/done-unread.json"
check "기록이 280KB 를 넘어도 차단이 유지된다" "$(runtr "$SB/tr-long.jsonl")" "2"

echo "== t18. ⛔ 해법 문구가 inbox 를 가리키면 안 된다 =="
# `inbox` 는 read 를 바꾸지 않는다(실측). 해법에 그것을 적으면 코디네이터가 불러도 미읽음이
# 남아 다음 턴에 또 막힌다 — 풀 수 없는 게이트가 된다.
mk_orca "$SB/done-unread.json"; runtr "$SB/tr-mine.jsonl" >/dev/null
grep -q 'check --ack' "$SB/err" && ok "check --ack 를 해법으로 말한다" || bad "check --ack 가 없다"
if grep -E '→ .*orchestration inbox' "$SB/err" >/dev/null; then bad "해법 줄이 inbox 를 가리킨다"
else ok "해법 줄에 inbox 가 없다"; fi

echo "== t19. ⭐ heartbeat 공백은 알림이다(차단 아님) · 경계 둘 =="
cat > "$SB/hb.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_h1","type":"heartbeat","run_id":"run_mine","read":1,"created_at":"2026-09-16T15:00:00Z",
  "payload":"{\"dispatchId\":\"ctx_live\"}"}
]}}
JSON
cat > "$SB/wl-live.json" <<'JSON'
{"result":{"workers":[
 {"dispatchId":"ctx_live","runId":"run_mine","workerState":"running","agentTerminalHandle":"term_live"}
]}}
JSON
mk_orca "$SB/hb.json" "$SB/wl-live.json"
rc=$(rm -f "$SB/coordinator-inbox-gate.$(id -u).count"; printf '{"transcript_path":"%s"}' "$SB/tr-mine.jsonl" \
     | PATH="$SB/bin:$PATH" CLAUDE_GATE_NOW=2026-09-16T15:31:00Z bash "$GATE" >"$SB/out" 2>"$SB/err"; echo $?)
check "31분 조용해도 차단하지 않는다" "$rc" "0"
grep -q 'ctx_live' "$SB/err" && ok "어느 워커인지 알린다" || bad "워커를 안 알린다"
grep -q '31분' "$SB/err" && ok "경과 시간을 말한다" || bad "경과가 없다"
rc=$(rm -f "$SB/coordinator-inbox-gate.$(id -u).count"; printf '{"transcript_path":"%s"}' "$SB/tr-mine.jsonl" \
     | PATH="$SB/bin:$PATH" CLAUDE_GATE_NOW=2026-09-16T15:29:00Z bash "$GATE" >"$SB/out" 2>"$SB/err"; echo $?)
check "⭐ 대조군 — 29분이면 조용하다" "$rc" "0"
if [ -s "$SB/err" ]; then bad "29분인데 알렸다"; else ok "29분에는 아무 말도 없다"; fi

echo "== t20. ⭐ 끝난 워커의 heartbeat 공백은 알리지 않는다 =="
# settled 워커는 조용한 것이 정상이다. 이것을 안 거르면 파도가 끝날 때마다 알림이 쏟아진다.
cat > "$SB/wl-done.json" <<'JSON'
{"result":{"workers":[
 {"dispatchId":"ctx_live","runId":"run_mine","workerState":"succeeded","agentTerminalHandle":"term_live"}
]}}
JSON
mk_orca "$SB/hb.json" "$SB/wl-done.json"
rc=$(rm -f "$SB/coordinator-inbox-gate.$(id -u).count"; printf '{"transcript_path":"%s"}' "$SB/tr-mine.jsonl" \
     | PATH="$SB/bin:$PATH" CLAUDE_GATE_NOW=2026-09-16T16:00:00Z bash "$GATE" >"$SB/out" 2>"$SB/err"; echo $?)
check "통과" "$rc" "0"
if [ -s "$SB/err" ]; then bad "끝난 워커를 알렸다"; else ok "끝난 워커는 알리지 않는다"; fi

echo "== t21. ⭐⭐ 사보타주 둘 — 축과 스코프가 정말 그 조건을 보는가 =="
# (a) 축 ② 를 지우면 t13 의 차단이 통과로 바뀐다.
sed 's/if t not in ("worker_done", "escalation") or not mine(m):/if True:/' "$GATE" > "$SB/sab-axis.sh"
mk_orca "$SB/done-unread.json"
rc=$(rm -f "$SB/coordinator-inbox-gate.$(id -u).count"; printf '{"transcript_path":"%s"}' "$SB/tr-mine.jsonl" \
     | PATH="$SB/bin:$PATH" bash "$SB/sab-axis.sh" >/dev/null 2>&1; echo $?)
check "축 ②③ 를 지우면 미읽음이 안 잡힌다" "$rc" "0"
# (b) 스코프를 지우면 남의 run 으로도 막힌다.
sed 's/^    return r in seen$/    return True/' "$GATE" > "$SB/sab-scope.sh"
mk_orca "$SB/done-unread.json"
rc=$(rm -f "$SB/coordinator-inbox-gate.$(id -u).count"; printf '{"transcript_path":"%s"}' "$SB/tr-other.jsonl" \
     | PATH="$SB/bin:$PATH" bash "$SB/sab-scope.sh" >/dev/null 2>&1; echo $?)
check "스코프를 지우면 남의 run 이 차단된다" "$rc" "2"

echo "== t22. ⭐ 축이 섞이면 전부 세고 축마다 나눠 보여준다 =="
cat > "$SB/mixed.json" <<'JSON'
{"result":{"messages":[
 {"id":"msg_q1","type":"question","run_id":"run_mine","thread_id":"msg_q1","from_handle":"dispatch:ctx_aaa","payload":"{\"question\":\"물어본다\"}"},
 {"id":"msg_d1","type":"worker_done","run_id":"run_mine","read":0,"from_handle":"term_w1","subject":"끝났다"},
 {"id":"msg_e1","type":"escalation","run_id":"run_mine","read":0,"from_handle":"term_w2","subject":"막혔다"}
]}}
JSON
mk_orca "$SB/mixed.json"; check "셋이 섞이면 차단" "$(runtr "$SB/tr-mine.jsonl")" "2"
grep -q '3건' "$SB/err" && ok "합계 3건을 말한다" || bad "합계가 틀리다"
grep -q '답을 기다린다' "$SB/err" && ok "축 ① 절이 있다" || bad "축 ① 절이 없다"
grep -q '완료 보고' "$SB/err"   && ok "축 ② 절이 있다" || bad "축 ② 절이 없다"
grep -q '문제를 알렸' "$SB/err" && ok "축 ③ 절이 있다" || bad "축 ③ 절이 없다"

echo "== t23. ⛔ 문서 축 — SKILL.md 의 **코드 블록**이 맨 전송 명령을 처방하면 안 된다 =="
# 실측: 단독 send 55건 중 54건 미읽음. 처방이 래퍼를 가리켜야 그 98%가 닫힌다.
# ⚠ 산문의 인라인 언급(`orca orchestration send ...` 는 inbox 메일이다)은 **설명**이라
#   세면 문서가 이유를 못 적는다. 그래서 세는 것은 bash 코드 블록 안의 줄뿐이다.
SK="$HERE/../skills/fanout/SKILL.md"
CHK="$SB/doc-axis.py"
cat > "$CHK" <<'PYEOF'
import io, re, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
bad = 0
for block in re.findall(r"```bash\n(.*?)```", s, re.S):
    for line in block.splitlines():
        t = line.strip()
        if t.startswith("#"):
            continue
        if (re.search(r"orca +orchestration +send +--to +dispatch:", t)
                or re.search(r"orca +orchestration +reply +--id", t)
                or re.search(r"orca +terminal +send", t)):
            bad += 1
print(bad)
PYEOF
if [ -f "$SK" ]; then
  check "코드 블록 안의 맨 전송 명령" "$(python3 "$CHK" "$SK")" 0
  grep -q 'coordinator-send.sh" --reply' "$SK" && ok "질문 답은 래퍼를 처방한다" || bad "래퍼 처방이 없다"
  grep -q 'coordinator-send.sh" --to dispatch:' "$SK" && ok "도중 메시지도 래퍼를 처방한다" || bad "래퍼 처방이 없다"
  grep -q 'nudge-only' "$SK" && ok "죽은 워커 깨우기도 래퍼다" || bad "819 절이 맨 명령이다"
  grep -q 'send --type escalation' "$SK" && ok "워커 프리앰블에 escalation 채널이 있다" || bad "escalation 채널이 없다"
  grep -q 'check --ack --json' "$SK" && ok "대기 루프가 check --ack 를 처방한다" || bad "check --ack 처방이 없다"
else
  bad "SKILL.md 를 못 찾았다($SK)"
fi

echo
echo "검사 $((PASS+FAIL))개 · 통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ]
