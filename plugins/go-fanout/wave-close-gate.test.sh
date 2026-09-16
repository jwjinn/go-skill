#!/usr/bin/env bash
# wave-close-gate.test.sh — 대조군
#
# ⭐ 진짜 orca 를 부르지 않는다. PATH 앞에 가짜 `orca` 를 두어 worker-list JSON 을 조종한다.
#   진짜를 부르면 이 검사가 그때그때의 파도 상태에 따라 달라진다.
#
# 무엇을 증명하나 — 「전원 끝났는데 자원이 남았으면 막고 · 아직 돌면 통과하고 ·
#   다 회수했으면 통과하고 · 워커 세션에서는 아예 안 돈다」.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/wave-close-gate.sh"
PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  ⛔ $1"; [ -n "${2:-}" ] && echo "       $2"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1 (rc $2)"; else bad "$1 — 기대 rc $3 실제 rc $2"; fi; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"
export TMPDIR="$SB"

mk_orca() { # mk_orca <worker-list JSON 파일 | BROKEN>
  cat > "$SB/bin/orca" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"worker-list"*)
    case "$1" in
      BROKEN) echo "이건 JSON 이 아니다" ;;
      *)      cat "$1" ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$SB/bin/orca"
}
# ⚠ stdin 을 비운다 — 훅은 stdin 의 JSON(transcript_path)으로 세션 스코프를 판별하고, 없으면 종전대로 전부 본다.
run(){ rm -f "$SB/wave-close-gate.$(id -u).count"; PATH="$SB/bin:$PATH" bash "$GATE" </dev/null >"$SB/out" 2>"$SB/err"; echo $?; }
runtr(){ # runtr <transcript 경로> — Stop 훅 stdin 모양으로 transcript_path 를 준다
  rm -f "$SB/wave-close-gate.$(id -u).count"
  printf '{"session_id":"s","transcript_path":"%s"}' "$1" | PATH="$SB/bin:$PATH" bash "$GATE" >"$SB/out" 2>"$SB/err"; echo $?; }

w() { # w <state> <dispatchStatus> <releaseCompletedAt|null> <id> <handle>
  printf '{"dispatchId":"%s","runId":"run_x","workerState":"%s","dispatchStatus":"%s","agentTerminalHandle":"%s","resource":{"releaseCompletedAt":%s}}' \
    "$4" "$1" "$2" "$5" "$3"
}

wr() { # wr <state> <dispatchStatus> <releaseCompletedAt|null> <id> <handle> <retainedReason>
  printf '{"dispatchId":"%s","runId":"run_x","workerState":"%s","dispatchStatus":"%s","agentTerminalHandle":"%s","resource":{"releaseCompletedAt":%s,"retainedReason":"%s"}}' \
    "$4" "$1" "$2" "$5" "$3" "$6"
}

echo "== t1. 전원 끝났는데 자원이 남아 있으면 막는다 =="
printf '{"result":{"workers":[%s,%s]}}' \
  "$(w succeeded completed null ctx_a term_a)" "$(w succeeded completed null ctx_b term_b)" > "$SB/held.json"
mk_orca "$SB/held.json"; eq "차단" "$(run)" "2"
grep -q 'ctx_a' "$SB/err" && ok "미회수 자원을 나열한다" || bad "목록이 없다" "$(cat "$SB/err")"
grep -q 'wave-close.sh' "$SB/err" && ok "마감 명령을 알려 준다" || bad "명령이 없다"

echo "== t2. ⭐ 대조군 — 아직 도는 워커가 있으면 통과한다(파도가 안 끝났다) =="
printf '{"result":{"workers":[%s,%s]}}' \
  "$(w succeeded completed null ctx_a term_a)" "$(w ready dispatched null ctx_b term_b)" > "$SB/live.json"
mk_orca "$SB/live.json"; eq "통과" "$(run)" "0"

echo "== t3. ⭐ 대조군 — 전부 회수됐으면 통과한다 =="
printf '{"result":{"workers":[%s,%s]}}' \
  "$(w succeeded completed '"2026-09-15T10:00:00Z"' ctx_a term_a)" \
  "$(w succeeded completed '"2026-09-15T10:00:00Z"' ctx_b term_b)" > "$SB/done.json"
mk_orca "$SB/done.json"; eq "통과" "$(run)" "0"

echo "== t4. ⛔⛔ 워커 세션에서는 아예 돌지 않는다 =="
# 같은 부류의 훅이 워커의 턴을 막았고 워커는 그것을 풀 수단이 없었다(2026-09-15).
mk_orca "$SB/held.json"
rm -f "$SB/wave-close-gate.$(id -u).count"
PATH="$SB/bin:$PATH" ORCA_TERMINAL_HANDLE=term_a bash "$GATE" </dev/null >/dev/null 2>&1; rc=$?
eq "내 핸들이 워커 목록에 있으면 통과" "$rc" "0"

echo "== t5. ⭐ 대조군 — 코디네이터 핸들은 그대로 막힌다 =="
# 이것이 없으면 t4 의 판별이 「게이트를 통째로 끈 것」과 구분되지 않는다.
mk_orca "$SB/held.json"
rm -f "$SB/wave-close-gate.$(id -u).count"
PATH="$SB/bin:$PATH" ORCA_TERMINAL_HANDLE=term_coordinator bash "$GATE" </dev/null >/dev/null 2>&1; rc=$?
eq "차단" "$rc" "2"

echo "== t6. ⭐ 판정 불가는 통과한다 =="
mk_orca BROKEN;        eq "JSON 이 깨져도 통과" "$(run)" "0"
# ⚠ PATH 에서 지우는 것만으로는 「없다」가 안 된다 — 시스템 orca 가 뒤에 남아 **진짜
#   worker-list 를 읽는다**. 같은 부류를 질문 게이트에서도 밟았다.
rm -f "$SB/bin/orca"
rc=$(rm -f "$SB/wave-close-gate.$(id -u).count"; PATH="$SB/bin:$PATH" ORCA_BIN=/nonexistent/orca bash "$GATE" </dev/null >/dev/null 2>&1; echo $?)
eq "orca 가 없으면 통과" "$rc" "0"

echo "== t7. 실패로 끝난 워커도 「끝난 것」으로 센다 =="
# failed 를 진행 중으로 세면 실패한 워커 하나 때문에 파도를 영영 못 닫는다.
printf '{"result":{"workers":[%s,%s]}}' \
  "$(w failed failed null ctx_a term_a)" "$(w succeeded completed null ctx_b term_b)" > "$SB/failed.json"
mk_orca "$SB/failed.json"; eq "그래도 미회수라 차단" "$(run)" "2"

echo "== t8. ⭐ 세션당 상한을 넘으면 통과한다(무한 차단 금지) =="
mk_orca "$SB/held.json"
rm -f "$SB/wave-close-gate.$(id -u).count"
LAST=9
for i in 1 2 3; do PATH="$SB/bin:$PATH" CLAUDE_WAVE_CLOSE_GATE_MAX=2 bash "$GATE" </dev/null >/dev/null 2>&1; LAST=$?; done
eq "3회째는 통과" "$LAST" "0"

echo "== t9. ⭐ 대조군의 대조군 — 회수 판정을 사보타주하면 t3 이 붉어진다 =="
SAB="$SB/gate-sab.sh"
sed 's/not res.get("releaseCompletedAt")/True/' "$GATE" > "$SAB"
mk_orca "$SB/done.json"
rm -f "$SB/wave-close-gate.$(id -u).count"
PATH="$SB/bin:$PATH" bash "$SAB" </dev/null >/dev/null 2>&1; rc=$?
eq "회수 여부를 안 보면 다 치운 파도도 막힌다" "$rc" "2"

echo "== t10. ⭐⭐ 보류 표식이 있으면 조용히 통과한다 =="
# 마감을 막는 사유가 **사람의 PR 머지**뿐일 때가 있다. 그때 코디네이터는 풀 수단이 없는 채로
# 매 턴 막히고 상한 8회를 소음으로 태운다. `wave-close.sh` 가 재 보고 남긴 표식만 인정한다.
mkdir -p "$SB/go-fanout"
printf '{"run":"run_x","reason":"소스 교차","at":"2026-09-15T22:00:00+09:00"}\n' > "$SB/go-fanout/deferred.run_x.json"
mk_orca "$SB/held.json"; eq "표식이 있으면 통과" "$(run)" "0"

echo "== t11. ⭐ 대조군 — 표식이 오래되면 다시 막는다 =="
# 표식이 영구면 게이트가 통째로 꺼진다. 사람이 잊은 것과 기다리는 것은 다르다.
# ⚠ `CLAUDE_WAVE_DEFER_HOURS=0` 으로는 못 잰다 — 방금 만든 파일은 `find -mmin +0` 에
#   걸리지 않는다(0분보다 오래되지 않았다). **파일을 실제로 늙혀서** 재야 한다.
touch -t 202601010000 "$SB/go-fanout/deferred.run_x.json"
mk_orca "$SB/held.json"; eq "표식이 오래되면 다시 차단" "$(run)" "2"
# 되돌린다(뒤 검사가 신선한 표식을 전제한다)
printf '{"run":"run_x","reason":"소스 교차","at":"2026-09-15T22:00:00+09:00"}\n' > "$SB/go-fanout/deferred.run_x.json"

echo "== t12. ⭐ 대조군 — **다른 run** 의 표식으로는 통과하지 않는다 =="
# run 을 안 보면 아무 파도의 표식 하나로 모든 파도의 게이트가 열린다.
mv "$SB/go-fanout/deferred.run_x.json" "$SB/go-fanout/deferred.run_other.json"
mk_orca "$SB/held.json"; eq "남의 표식은 안 통한다" "$(run)" "2"
rm -f "$SB/go-fanout/deferred.run_other.json"

echo "== t13. ⭐ 대조군 — 표식이 있어도 **아직 도는 워커**가 있으면 판정이 바뀌지 않는다 =="
# 표식은 「회수를 미룬다」는 뜻이지 「파도가 끝났다」는 뜻이 아니다.
printf '{"run":"run_x","reason":"소스 교차","at":"2026-09-15T22:00:00+09:00"}\n' > "$SB/go-fanout/deferred.run_x.json"
mk_orca "$SB/live.json"; eq "도는 워커가 있으면 그대로 통과(막을 이유가 없다)" "$(run)" "0"
rm -f "$SB/go-fanout/deferred.run_x.json"

echo "== t14. ⛔ **코디네이터가 닫을 수 없는 자원**은 미회수로 세지 않는다 (2026-09-16) =="
# `worker-release` 는 사용자가 인수한 터미널을 구조적으로 닫지 않는다(그 명령의 Notes 가
# "Never closes ... user-taken-over terminals"). 그것을 미회수로 세면 코디네이터가 할 수 있는
# 일이 없는데도 게이트가 세션당 상한 여덟 번을 다 쓸 때까지 막는다.
printf '{"result":{"workers":[%s,%s]}}' \
  "$(wr succeeded completed null ctx_tk1 term_tk1 user_takeover)" \
  "$(wr succeeded completed null ctx_tk2 term_tk2 user_takeover)" > "$SB/takeover.json"
mk_orca "$SB/takeover.json"; eq "user_takeover 만 남았으면 통과" "$(run)" "0"

echo "== t14-b. ⭐ 닫을 수 없는 사유는 **셋**이다 (2026-09-16) =="
# `worker-release --help` Notes: "Never closes setup terminals, configured tabs, reused or
# pre-existing terminals, user-taken-over terminals, or unproven identities."
# 하나만 면제했더니 나머지 둘로 run 둘이 계속 막혔다(실측).
for r in external_terminal identity_unproven; do
  printf '{"result":{"workers":[%s,%s]}}' \
    "$(wr succeeded completed null ctx_x1 term_x1 "$r")" \
    "$(wr succeeded completed null ctx_x2 term_x2 "$r")" > "$SB/reason.json"
  mk_orca "$SB/reason.json"; eq "$r 만 남았으면 통과" "$(run)" "0"
done

echo "== t15. ⭐ 대조군 — **다른 사유**의 보류는 그대로 막는다 =="
# 이것이 없으면 위 완화가 「사유를 안 보고 전부 통과」로 흘러가도 아무도 모른다.
printf '{"result":{"workers":[%s,%s]}}' \
  "$(wr succeeded completed null ctx_o1 term_o1 pending_cleanup)" \
  "$(wr succeeded completed null ctx_o2 term_o2 pending_cleanup)" > "$SB/other.json"
mk_orca "$SB/other.json"; eq "다른 사유는 차단" "$(run)" "2"

echo "== t16. ⭐ 대조군 — **섞여 있으면** 나머지만 세어 막는다 =="
# user_takeover 하나가 섞였다고 나머지가 면제되면 안 된다.
printf '{"result":{"workers":[%s,%s]}}' \
  "$(wr succeeded completed null ctx_m1 term_m1 user_takeover)" \
  "$(w succeeded completed null ctx_m2 term_m2)" > "$SB/mixed.json"
mk_orca "$SB/mixed.json"; eq "섞이면 나머지로 차단" "$(run)" "2"
grep -q 'ctx_m2' "$SB/err" && ok "막는 자원만 나열한다" || bad "목록이 없다" "$(cat "$SB/err")"
grep -q 'ctx_m1' "$SB/err" && bad "닫을 수 없는 자원까지 나열한다" "$(cat "$SB/err")" || ok "user_takeover 는 목록에서 뺀다"

echo "== t16-b. ⛔ stdin 이 **열린 채**로 넘어와도 멈추지 않는다 (2026-09-16) =="
# 종전 판은 `cat` 으로 받아서 그런 호출에 영영 멈췄다. 게이트가 아니라 턴이 서는 부류다.
mk_orca "$SB/held.json"
rm -f "$SB/wave-close-gate.$(id -u).count"
( sleep 30 ) | { PATH="$SB/bin:$PATH" CLAUDE_WAVE_STDIN_TIMEOUT=1 bash "$GATE" >/dev/null 2>&1; echo $? > "$SB/rc-open"; } &
BGPID=$!
WAITED=0
while kill -0 "$BGPID" 2>/dev/null && [ "$WAITED" -lt 10 ]; do sleep 1; WAITED=$((WAITED+1)); done
if kill -0 "$BGPID" 2>/dev/null; then
  kill "$BGPID" 2>/dev/null; bad "stdin 이 열린 채면 멈춘다 — 10초 안에 끝나지 않았다"
else
  ok "열린 stdin 에서도 $WAITED 초 안에 끝난다 (rc $(cat "$SB/rc-open" 2>/dev/null))"
fi
pkill -f 'sleep 30' 2>/dev/null || true

echo "== t17. ⭐⭐ 세션 스코프 — 이 세션이 관여한 run 만 막는다 (2026-09-16) =="
# 훅을 점검하던 세션이 남의 fan-out 세 차수로 매 턴 막혔다. 판별은 transcript 의 도구 호출·결과다.
mk_orca "$SB/held.json"
printf '%s\n' '{"type":"user","message":{"content":"훅 점검해줘"}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}' > "$SB/tr-other.jsonl"
eq "run_x 를 본 적 없는 세션 → 통과" "$(runtr "$SB/tr-other.jsonl")" "0"
printf '%s\n' '{"type":"user","message":{"content":"파도 닫아"}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"orca orchestration worker-list --run run_x --json"}}]}}' > "$SB/tr-mine.jsonl"
eq "run_x 를 도구로 다룬 세션 → 차단" "$(runtr "$SB/tr-mine.jsonl")" "2"
printf '%s\n' '{"type":"user","message":{"content":"x"}}' \
  '{"type":"user","toolUseResult":{"stdout":"runId run_x dispatched"},"message":{"content":[{"type":"tool_result","content":"run_x"}]}}' > "$SB/tr-res.jsonl"
eq "run_x 가 도구 **결과**에만 있어도 관여다 → 차단" "$(runtr "$SB/tr-res.jsonl")" "2"

echo "== t18. ⭐ 대조군 — 게이트 자신의 차단 문구(사람 발화 행)는 관여의 근거가 아니다 =="
# 이것이 없으면 한 번 막힌 세션은 그 문구가 transcript 에 남아 영원히 「관여한 세션」이 된다.
printf '%s\n' '{"type":"user","message":{"content":"Stop hook feedback: run run_x — 워커 2 명 전원 종료, 그런데 2 개가 살아 있다"}}' > "$SB/tr-fb.jsonl"
eq "차단 문구만 있는 세션 → 통과" "$(runtr "$SB/tr-fb.jsonl")" "0"

echo "== t18-b. ⭐ 대조군 — 모델이 **산문에 인용한** run_id 는 관여가 아니다 =="
# 이 게이트에 막힌 세션은 run_id 를 답변에 적게 된다. 그것을 세면 자기 출력이 자기 근거가 된다.
printf '%s\n' '{"type":"user","message":{"content":"훅 점검"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"run_x 에 잔여 컨텍스트 2개가 있습니다."}]}}' > "$SB/tr-prose.jsonl"
eq "산문 인용만 → 통과" "$(runtr "$SB/tr-prose.jsonl")" "0"

echo "== t19. ⭐ 판별 불가는 종전대로 전부 본다 =="
eq "transcript 경로가 없는 파일이면 → 차단(좁히지 않는다)" "$(runtr "$SB/없는것.jsonl")" "2"
eq "stdin 이 비어 있으면 → 차단(종전 동작)" "$(run)" "2"

echo
echo "검사 $((PASS+FAIL))개 · 통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ]
