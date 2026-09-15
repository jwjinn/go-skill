#!/usr/bin/env bash
# worker-question-gate.test.sh — 대조군
#
# ⭐ 실제 orca 를 부르지 않는다. PATH 앞에 가짜 `orca` 를 두어 inbox JSON 을 조종한다.
#   진짜 런타임을 부르면 이 테스트가 그때그때의 워커 상태에 따라 달라진다.
#
# 무엇을 증명하나 — 「미답변이 있으면 막고 · 답하면 통과하고 · 못 재면 통과한다」.
#   특히 세 번째가 중요하다. 판정 불가에 차단하면 orca 를 안 쓰는 세션이 통째로 멈춘다.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/worker-question-gate.sh"
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
run(){ rm -f "$SB/worker-question-gate.$(id -u).count"; PATH="$SB/bin:$PATH" bash "$GATE" >"$SB/out" 2>"$SB/err"; echo $?; }

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
rc=$(rm -f "$SB/worker-question-gate.$(id -u).count"; PATH="$SB/bin:$PATH" ORCA_BIN=/nonexistent/orca bash "$GATE" >/dev/null 2>&1; echo $?)
check "orca 가 없으면 통과" "$rc" "0"

echo "== t6. 여러 건이면 전부 센다 =="
mk_orca "$SB/two.json"; RC=$(run)
check "차단" "$RC" "2"
grep -q '2건' "$SB/err" && ok "개수를 말한다" || bad "개수가 없다"
grep -q 'msg_q2' "$SB/err" && ok "둘째도 나열한다" || bad "둘째가 빠졌다"

echo "== t7. ⭐ 세션당 상한을 넘으면 통과한다(무한 차단 금지) =="
mk_orca "$SB/pending.json"
rm -f "$SB/worker-question-gate.$(id -u).count"
LAST=9
for i in 1 2 3; do PATH="$SB/bin:$PATH" CLAUDE_WORKER_Q_GATE_MAX=2 bash "$GATE" >/dev/null 2>&1; LAST=$?; done
check "3회째는 통과" "$LAST" "0"

echo "== t8. ⭐ 대조군의 대조군 — 답변 판정을 사보타주하면 t2 가 붉어진다 =="
SAB="$SB/gate-sab.sh"
sed 's/answers\[t\] = o/pass/' "$GATE" > "$SAB"
mk_orca "$SB/answered.json"
rm -f "$SB/worker-question-gate.$(id -u).count"
PATH="$SB/bin:$PATH" bash "$SAB" >/dev/null 2>&1; RC=$?
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
rm -f "$SB/worker-question-gate.$(id -u).count"
PATH="$SB/bin:$PATH" ORCA_TERMINAL_HANDLE=term_worker_aaa bash "$GATE" >"$SB/out" 2>"$SB/err"; RC=$?
check "내 핸들이 워커 목록에 있으면 통과" "$RC" "0"

echo "== t10. ⭐ 대조군 — 코디네이터 핸들은 그 목록에 없으므로 그대로 막힌다 =="
# 이것이 없으면 t9 의 수정이 「게이트를 통째로 끈 것」과 구분되지 않는다.
mk_orca "$SB/pending.json" "$SB/wl.json"
rm -f "$SB/worker-question-gate.$(id -u).count"
PATH="$SB/bin:$PATH" ORCA_TERMINAL_HANDLE=term_coordinator bash "$GATE" >"$SB/out" 2>"$SB/err"; RC=$?
check "코디네이터는 차단" "$RC" "2"

echo "== t11. ⭐ 핸들이 없거나 목록을 못 받으면 게이트를 계속 돈다 =="
# 판별 불가를 「나는 워커다」로 읽으면 게이트가 조용히 통째로 꺼진다.
mk_orca "$SB/pending.json" NONE
rm -f "$SB/worker-question-gate.$(id -u).count"
PATH="$SB/bin:$PATH" ORCA_TERMINAL_HANDLE=term_whatever bash "$GATE" >"$SB/out" 2>"$SB/err"; RC=$?
check "worker-list 가 비면 차단이 유지된다" "$RC" "2"
mk_orca "$SB/pending.json" "$SB/wl.json"
rm -f "$SB/worker-question-gate.$(id -u).count"
PATH="$SB/bin:$PATH" bash "$GATE" >"$SB/out" 2>"$SB/err"; RC=$?
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

echo
echo "검사 $((PASS+FAIL))개 · 통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ]
