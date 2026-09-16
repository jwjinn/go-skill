#!/usr/bin/env bash
# coordinator-send.test.sh — 대조군.
#
# ⭐ 진짜 orca 를 부르지 않는다. PATH 앞에 가짜 `orca` 를 두고 **argv 를 파일에 적게** 해서
#   「무엇을 몇 번 불렀나」를 센다. 이 래퍼가 존재하는 이유가 「두 가지를 같이 한다」이므로,
#   그 둘이 실제로 불렸는지는 호출 기록으로만 증명된다.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SH="$HERE/coordinator-send.sh"
PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✅ $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  ⛔ $1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 — 기대 $3 실제 $2"; fi; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"
export TMPDIR="$SB"

# 가짜 orca — argv 를 $SB/argv 에 한 줄씩 적고, inbox·worker-show 는 픽스처를 낸다.
mk_orca() { # mk_orca [inbox JSON] [worker-show JSON | NONE]
  IB="${1:-}"; WS="${2:-}"
  cat > "$SB/bin/orca" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SB/argv"
case "\$*" in
  *"worker-show"*) [ "${WS:-NONE}" = NONE ] && exit 1 || cat "${WS:-/dev/null}" ;;
  *"inbox"*)       [ -n "${IB:-}" ] && cat "${IB}" || echo '{"result":{"messages":[]}}' ;;
  *"terminal send"*) [ -n "\${FAKE_TERM_FAIL:-}" ] && exit 1 || echo '{"ok":true}' ;;
  *) echo '{"ok":true}' ;;
esac
EOF
  chmod +x "$SB/bin/orca"
  : > "$SB/argv"
}
run(){ PATH="$SB/bin:$PATH" bash "$SH" "$@" >"$SB/out" 2>"$SB/err"; echo $?; }
# ⚠ `grep -c` 는 0 매치일 때 stdout 에 0 을 내면서 rc 1 을 준다 — `|| echo 0` 을 붙이면
#   출력이 「0\n0」이 되어 비교가 전부 어긋난다(이 레포군의 「판정을 파이프 뒤에서 읽지 마라」 부류).
count(){ n=$(grep -c -- "$1" "$SB/argv" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac; echo "$n"; }

cat > "$SB/ws.json" <<'JSON'
{"result":{"worker":{"agentTerminalHandle":"term_w1"}}}
JSON
now_iso(){ date -u -v-"$1"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-$1 seconds" +%Y-%m-%dT%H:%M:%SZ; }
mk_inbox(){ # mk_inbox <초 전>
  printf '{"result":{"messages":[{"id":"msg_q1","type":"question","run_id":"run_mine","thread_id":"msg_q1","read":0,"created_at":"%s","payload":"{\\"dispatchId\\":\\"ctx_aaa\\"}"}]}}\n' "$(now_iso "$1")" > "$SB/inbox.json"
}

echo "== t1. --to dispatch — inbox 로 보내고 터미널로 깨운다(둘 다) =="
# 이 래퍼의 존재 이유다. 실측: 단독 send 55건 중 54건이 미읽음이었다.
mk_orca "" "$SB/ws.json"
eq "rc" "$(run --to dispatch:ctx_aaa --subject "정리" --body "P3 로 가라")" 0
eq "orchestration send 1회" "$(count 'orchestration send')" 1
eq "terminal send 1회"      "$(count 'terminal send')" 1
grep -q 'terminal send --terminal term_w1' "$SB/argv" && ok "worker-show 가 준 핸들로 깨운다" || bad "핸들이 다르다"
grep -q -- '--enter' "$SB/argv" && ok "Enter 를 붙인다(안 붙이면 줄이 프롬프트에 남는다)" || bad "--enter 가 없다"
grep -q 'check --ack' "$SB/argv" && ok "깨우기 문구가 check --ack 를 말한다" || bad "문구가 틀리다"
grep -q 'P3 로 가라' "$SB/argv" && ! grep -q 'terminal send.*P3 로 가라' "$SB/argv" \
  && ok "⭐ 본문은 inbox 에만 간다(터미널에 타이핑하지 않는다)" || bad "본문이 터미널로 갔다"

echo "== t2. --no-nudge 는 터미널을 건드리지 않는다 =="
mk_orca "" "$SB/ws.json"
eq "rc" "$(run --to dispatch:ctx_aaa --body "조용히" --no-nudge)" 0
eq "orchestration send 1회" "$(count 'orchestration send')" 1
eq "terminal send 0회"      "$(count 'terminal send')" 0

echo "== t3. ⭐ --reply 가 신선하면(600초 안) 깨우지 않는다 =="
# 실측: ask 로 기다리는 워커에게 간 reply 는 600초 안 57/57 이 읽혔다. 깨울 이유가 없다.
mk_inbox 60; mk_orca "$SB/inbox.json" "$SB/ws.json"
eq "rc" "$(run --reply msg_q1 --body "승인한다")" 0
eq "orchestration reply 1회" "$(count 'orchestration reply')" 1
eq "terminal send 0회"       "$(count 'terminal send')" 0

echo "== t4. ⭐ --reply 가 오래됐으면(600초 초과) 깨운다 =="
# 실측: 600초 넘어 보낸 reply 4건 중 1건이 미읽음이었다. 워커가 ask 에서 빠져나와 있다.
mk_inbox 1200; mk_orca "$SB/inbox.json" "$SB/ws.json"
eq "rc" "$(run --reply msg_q1 --body "늦었다")" 0
eq "orchestration reply 1회" "$(count 'orchestration reply')" 1
eq "terminal send 1회"       "$(count 'terminal send')" 1

echo "== t5. ⭐ 경계 — 599초와 601초가 갈린다 =="
mk_inbox 599; mk_orca "$SB/inbox.json" "$SB/ws.json"; run --reply msg_q1 --body x >/dev/null
eq "599초 → 안 깨운다" "$(count 'terminal send')" 0
mk_inbox 601; mk_orca "$SB/inbox.json" "$SB/ws.json"; run --reply msg_q1 --body x >/dev/null
eq "601초 → 깨운다"    "$(count 'terminal send')" 1

echo "== t6. ⛔ 핸들을 못 구해도 보낸 것은 성공이다 =="
# 여기서 실패로 보고하면 코디네이터가 같은 메시지를 다시 보낸다(중복 발송).
mk_orca "" NONE
eq "rc 0" "$(run --to dispatch:ctx_aaa --body "본문")" 0
eq "send 는 했다"      "$(count 'orchestration send')" 1
eq "terminal send 0회" "$(count 'terminal send')" 0
grep -q '핸들을 못 구했다' "$SB/err" && ok "못 깨웠다고 stderr 에 적는다" || bad "조용히 넘어갔다"

echo "== t7. ⛔ 터미널 전송이 실패해도 보낸 것은 성공이다 =="
mk_orca "" "$SB/ws.json"
rc=$(PATH="$SB/bin:$PATH" FAKE_TERM_FAIL=1 bash "$SH" --to dispatch:ctx_aaa --body "x" >"$SB/out" 2>"$SB/err"; echo $?)
eq "rc 0" "$rc" 0
grep -q '깨우지 못했다' "$SB/err" && ok "실패를 stderr 에 적는다" || bad "조용히 넘어갔다"
grep -q 'nudged:false' "$SB/out" && ok "출력이 nudged:false 라고 말한다" || bad "출력이 틀리다"

echo "== t8. --nudge-only 는 inbox 를 건드리지 않는다(§819 죽은 워커 깨우기) =="
mk_orca "" "$SB/ws.json"
eq "rc" "$(run --to terminal:term_dead --nudge-only)" 0
eq "orchestration send 0회" "$(count 'orchestration send')" 0
eq "terminal send 1회"      "$(count 'terminal send')" 1
grep -q 'term_dead' "$SB/argv" && ok "준 핸들을 그대로 쓴다" || bad "핸들이 다르다"

echo "== t9. ⛔ orca 가 없으면 rc 2 — 조용히 성공하지 않는다 =="
rm -f "$SB/bin/orca"
rc=$(PATH="$SB/bin:$PATH" ORCA_BIN=/nonexistent/orca bash "$SH" --to dispatch:ctx_aaa --body x >/dev/null 2>&1; echo $?)
eq "rc 2" "$rc" 2

echo "== t10. ⛔ 인자가 모자라면 rc 2 =="
mk_orca "" "$SB/ws.json"
eq "--to 도 --reply 도 없으면 rc 2" "$(run --body x)" 2
eq "본문이 없으면 rc 2"             "$(run --to dispatch:ctx_aaa)" 2
eq "모르는 인자면 rc 2"             "$(run --엉뚱)" 2

echo "== t11. ⭐ --wait-read 가 읽음 여부를 출력에 적는다 =="
mk_inbox 60
# ⚠ 답 메시지는 `to_handle` 이 `dispatch:` 로 시작한다 — 그것이 「코디네이터가 워커에게 보낸
#   답」의 표식이다. 원 질문(id == thread_id)과 구분하는 축이라 픽스처도 실제 모양이어야 한다.
printf '{"result":{"messages":[{"id":"msg_q1","type":"question","thread_id":"msg_q1","read":1},{"id":"msg_a1","type":"status","thread_id":"msg_q1","to_handle":"dispatch:ctx_aaa","read":1}]}}\n' > "$SB/inbox-read.json"
cat > "$SB/bin/orca" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SB/argv"
case "\$*" in
  *"worker-show"*) cat "$SB/ws.json" ;;
  *"inbox"*)
    if [ -f "$SB/flip" ]; then cat "$SB/inbox-read.json"; else cat "$SB/inbox.json"; : > "$SB/flip"; fi ;;
  *) echo '{"ok":true}' ;;
esac
EOF
chmod +x "$SB/bin/orca"; : > "$SB/argv"; rm -f "$SB/flip"
run --reply msg_q1 --body "답" --wait-read 6 >/dev/null
grep -q 'read:true' "$SB/out" && ok "읽히면 read:true" || bad "read 상태가 틀리다 ($(cat "$SB/out"))"

echo "== t13. ⛔ 원 질문만 read 인 인박스를 「답이 읽혔다」로 읽지 않는다 =="
# 코디네이터가 게이트 지시대로 check 로 인박스를 소비하면 원 질문이 read=1 이 된다.
# 그것을 답으로 세면 워커가 답을 못 받았는데 「읽혔다」가 보고된다(2026-09-16 리뷰가 잡았다).
printf '{"result":{"messages":[{"id":"msg_q1","type":"question","thread_id":"msg_q1","read":1}]}}\n' > "$SB/inbox-qonly.json"
cat > "$SB/bin/orca" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SB/argv"
case "\$*" in
  *"worker-show"*) cat "$SB/ws.json" ;;
  *"inbox"*)       cat "$SB/inbox-qonly.json" ;;
  *) echo '{"ok":true}' ;;
esac
EOF
chmod +x "$SB/bin/orca"; : > "$SB/argv"
run --reply msg_q1 --body "답" --wait-read 4 >/dev/null
grep -q 'read:false' "$SB/out" && ok "⭐ 원 질문의 read 는 답이 아니다" || bad "원 질문을 답으로 셌다 ($(cat "$SB/out"))"

echo "== t14. ⛔ --to 경로의 --wait-read 는 못 잰다고 말한다(false 로 단정하지 않는다) =="
# 이 래퍼의 주 용법이고, 여기서 거짓 음성이 나면 코디네이터가 같은 지시를 다시 보낸다.
mk_orca "" "$SB/ws.json"
run --to dispatch:ctx_aaa --body "본문" --wait-read 4 >/dev/null
grep -q 'read:unknown' "$SB/out" && ok "read:unknown 으로 남긴다" || bad "출력이 틀리다 ($(cat "$SB/out"))"
grep -q -- '--reply 에서만 잰다' "$SB/err" && ok "왜 못 재는지 말한다" || bad "사유가 없다"

echo "== t12. ⭐ 사보타주 — 깨우기 단계를 지우면 t1 이 붉어진다 =="
sed 's@^    if "\$ORCA_BIN" terminal send@    if false \&\& "$ORCA_BIN" terminal send@' "$SH" > "$SB/sab.sh"
mk_orca "" "$SB/ws.json"
PATH="$SB/bin:$PATH" bash "$SB/sab.sh" --to dispatch:ctx_aaa --body x >/dev/null 2>&1
eq "사보타주하면 terminal send 가 0 이 된다" "$(count 'terminal send')" 0

echo
echo "검사 $((PASS+FAIL))개 · 통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ]
