#!/usr/bin/env bash
# coder.sh 대조군. 실행: bash <플러그인>/coder/coder.test.sh
#
# ⭐⭐ 이 스위트의 본체는 **통제가 실제로 거부하는가**다. 「정상 경로가 돈다」는 절반이고,
#   나머지 절반은 위반을 일부러 만들어 그것이 걸리는지 본다. 거부가 안 되면 이 도구는
#   codex 를 부르는 래퍼일 뿐이고, 그러면 있으나 마나다.
#
# ⚠ codex 는 **스텁**이다. 실물을 부르면 느리고 비싸고, 여기서 재는 것은 「모델이 잘 고치나」가
#   아니라 「우리 통제가 도는가」다. 스텁은 실물의 근사이므로, 실물에서 새 거부 사유가 나오면
#   **스텁에 먼저 넣어라**(go-fanout cleanup.sh 가 같은 규약을 쓴다).
set -u

SELF="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CODER="$SELF/coder.sh"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
ng(){ printf '  NG   %s  (%s)\n' "$1" "$2"; fail=$((fail+1)); }

# ── 픽스처 ────────────────────────────────────────────────────────────────────
# 레포 하나 · 대상 파일 하나 · 게이트 하나(target.txt 에 FIXED 가 있으면 초록).
setup() {
  T=$(mktemp -d)
  mkdir -p "$T/repo/.claude/coder" "$T/bin" "$T/home/.codex"
  git -C "$T/repo" init -q 2>/dev/null
  git -C "$T/repo" config user.email t@example.com
  git -C "$T/repo" config user.name tester
  printf 'BROKEN\n' > "$T/repo/target.txt"
  printf 'other\n'  > "$T/repo/other.txt"
  printf '#!/bin/sh\ngrep -q FIXED target.txt\n' > "$T/repo/gate.sh"
  chmod +x "$T/repo/gate.sh"
  git -C "$T/repo" add -A 2>/dev/null
  git -C "$T/repo" commit -qm init 2>/dev/null

  # 가짜 codex — FAKE_MODE 로 동작을 바꾼다
  cat > "$T/bin/codex" <<'STUB'
#!/bin/sh
OUT=""; prev=""
for a in "$@"; do
  [ "$prev" = "--output-last-message" ] && OUT="$a"
  prev="$a"
done
cat > /dev/null    # stdin(프롬프트) 소비
case "${FAKE_MODE:-fix}" in
  fix)     printf 'FIXED\n' > target.txt ;;
  prebumped) printf 'FIXED\n' > target.txt; printf '자식이 또 고쳤다\n' > other.txt ;;
  outside) printf 'FIXED\n' > target.txt; printf 'dirty\n' > other.txt ;;
  newfile) printf 'FIXED\n' > target.txt; printf 'x\n' > sneaky.txt ;;
  nofix)   : ;;
  plan)    printf 'FIXED\n' > target.txt; printf '훼손\n' > "$FAKE_PLAN" ;;
  nojson)  printf 'FIXED\n' > target.txt; OUT="" ;;
  badjson) printf 'FIXED\n' > target.txt
           [ -n "$OUT" ] && printf '{"summary":"x"}' > "$OUT"; OUT="" ;;
esac
[ -n "$OUT" ] && printf '{"summary":"고쳤다","files_changed":["target.txt"],"gate_ran":true,"notes":"막힌 것 없다","rounds":2}' > "$OUT"
exit 0
STUB
  chmod +x "$T/bin/codex"
  : > "$T/home/.codex/testprof.config.toml"
  printf '{"enabled":"on","profile":"testprof","ledger":".claude/coder/coder.jsonl","max_files":2}\n' \
    > "$T/repo/.claude/coder/config.json"
  printf '지시서: target.txt 에 FIXED 를 넣어라.\n' > "$T/task.md"
}
cleanup(){ rm -rf "$T"; }

# run [추가 env...] — coder.sh 를 픽스처 환경에서 돌리고 rc 를 돌려준다
run() {
  ( export PATH="$T/bin:$PATH" HOME="$T/home" CLAUDE_PROJECT_DIR="$T/repo"
    cd "$T/repo" || exit 99
    "$@" bash "$CODER" --task "$T/task.md" --targets 'target.txt' \
         --gate 'bash gate.sh' --cwd "$T/repo" --out "$T/out.json"
  ) >"$T/log" 2>&1
  printf '%s' $?
}

echo "=== 정상 경로"
setup
rc=$(run env FAKE_MODE=fix)
[ "$rc" = "0" ] && ok "① 붉은 게이트 → 자식이 고침 → 초록 → rc 0" || ng "정상 경로" "rc=$rc $(cat "$T/log")"
grep -q FIXED "$T/repo/target.txt" && ok "①-b 대상 파일이 실제로 바뀌었다" || ng "파일 미변경" "$(cat "$T/repo/target.txt")"
[ -s "$T/repo/.claude/coder/coder.jsonl" ] && ok "①-c 원장에 한 줄 남는다" || ng "원장 없음" ""
python3 -c "
import io,json,sys
d=json.loads(io.open(sys.argv[1],encoding='utf-8').read().strip().split(chr(10))[-1])
need=['gate_rc_before','gate_rc_after','rounds','elapsed_sec','files']
missing=[k for k in need if k not in d]
sys.exit(1 if missing or d['gate_rc_before']==0 or d['gate_rc_after']!=0 else 0)
" "$T/repo/.claude/coder/coder.jsonl" \
  && ok "①-d ⭐ 원장에 착수 전/후 게이트와 왕복·소요·파일 수가 있다(성능을 나중에 잰다)" \
  || ng "원장 필드" "$(cat "$T/repo/.claude/coder/coder.jsonl")"
cleanup

echo "=== ⭐⭐ 통제 ① 착수 전 게이트가 이미 초록이면 거부한다 (rc 67)"
# 고칠 것이 없는 상태에서 시작하면 「고쳤다」를 판정할 방법이 없다. go-tester 의 rc 67
# (대조군 미관측)에 대응하는 자리이고, 이 도구가 근거 없는 성공 주장을 막는 지점이다.
setup
printf 'FIXED\n' > "$T/repo/target.txt"       # 이미 초록으로 만든다
git -C "$T/repo" commit -qam green 2>/dev/null
rc=$(run env FAKE_MODE=fix)
[ "$rc" = "67" ] && ok "② 착수 전 게이트가 초록이면 rc 67" || ng "rc 67 미발화" "rc=$rc $(cat "$T/log")"
cleanup

echo "=== ⭐⭐ 통제 ② 대상 파일 밖을 고치면 거부하고 되돌린다 (rc 66)"
setup
rc=$(run env FAKE_MODE=outside)
[ "$rc" = "66" ] && ok "③ 대상 밖(기존 파일)을 고치면 rc 66" || ng "rc 66 미발화" "rc=$rc $(cat "$T/log")"
grep -q '^other$' "$T/repo/other.txt" && ok "③-b 그 파일이 원래 내용으로 되돌아왔다" || ng "미복원" "$(cat "$T/repo/other.txt")"
cleanup

setup
rc=$(run env FAKE_MODE=newfile)
[ "$rc" = "66" ] && ok "④ 대상 밖에 **새 파일**을 만들어도 rc 66" || ng "신규 파일 미탐지" "rc=$rc $(cat "$T/log")"
[ ! -f "$T/repo/sneaky.txt" ] && ok "④-b 그 새 파일이 지워졌다" || ng "새 파일 잔존" ""
cleanup

echo "=== ⭐ 착수 전부터 미커밋이던 파일은 **되돌리지 않는다**"
# ⛔ 이것이 이 도구에서 가장 위험한 자리다. 자식이 고친 것과 부모가 작업 중이던 것을
#   가리지 못한 채 되돌리면 **부모의 미커밋 작업을 지운다.** 그래서 스냅샷을 앞뒤로 뜬다.
setup
printf '부모가 작업 중\n' > "$T/repo/other.txt"     # 착수 전부터 더럽다
rc=$(run env FAKE_MODE=fix)
[ "$rc" = "0" ] && ok "⑤ 부모의 미커밋이 있어도 정상 경로가 돈다" || ng "오탐" "rc=$rc $(cat "$T/log")"
grep -q '부모가 작업 중' "$T/repo/other.txt" \
  && ok "⑤-b ⭐⭐ 부모의 미커밋 작업이 살아 있다(되돌리지 않았다)" || ng "부모 작업 유실" "$(cat "$T/repo/other.txt")"
cleanup

echo "=== ⭐⭐ 착수 전부터 더럽던 파일을 자식이 고치면 — 되돌리지 않되 **알린다**"
# 2026-09-16 리뷰 must_fix: 주석은 「되돌리지 않고 **알리기만** 한다」고 선언했는데
# **알리는 코드가 없었다.** 차집합에 안 나와 rc 0 으로 통과했고 README 의 rc 0 정의
# (「대상 파일만 바뀌었다」)가 거짓이 됐다. 되돌리지 않는 판단은 그대로 두고 알림만 더했다.
setup
printf '부모가 작업 중\n' > "$T/repo/other.txt"      # 착수 전부터 더럽다
rc=$( ( export PATH="$T/bin:$PATH" HOME="$T/home" CLAUDE_PROJECT_DIR="$T/repo"
        cd "$T/repo" || exit 99
        FAKE_MODE=prebumped bash "$CODER" --task "$T/task.md" --targets 'target.txt' \
             --gate 'bash gate.sh' --cwd "$T/repo" --out "$T/out.json"
      ) >"$T/log" 2>&1; printf '%s' $? )
[ "$rc" = "0" ] && ok "⑰ 되돌리지 않으므로 rc 0 은 유지된다" || ng "겹침에 rc 를 바꿨다" "rc=$rc $(cat "$T/log")"
grep -q '자식이 또 고쳤다' "$T/repo/other.txt" && ok "⑰-b 부모 파일을 되돌리지 않았다" || ng "되돌렸다" "$(cat "$T/repo/other.txt")"
grep -q '착수 전부터 미커밋이던 파일이 바뀌었다' "$T/log" \
  && ok "⑰-c ⭐⭐ 그 사실을 **알린다**(선언된 설계의 나머지 절반)" || ng "침묵했다" "$(cat "$T/log")"
cleanup

setup
# 대조군 — 부모 파일이 그대로면 알리지 않는다(오탐 방지)
printf '부모가 작업 중\n' > "$T/repo/other.txt"
rc=$(run env FAKE_MODE=fix)
grep -q '착수 전부터 미커밋이던 파일이 바뀌었다' "$T/log" \
  && ng "⑱ 안 바뀐 파일에 알렸다" "$(cat "$T/log")" || ok "⑱ 부모 파일이 그대로면 조용하다"
cleanup

echo "=== ⭐⭐ 통제 ③ 완료 후 게이트가 붉으면 거부한다 (rc 69)"
setup
rc=$(run env FAKE_MODE=nofix)
[ "$rc" = "69" ] && ok "⑥ 자식이 아무것도 안 고치면 rc 69" || ng "rc 69 미발화" "rc=$rc $(cat "$T/log")"
cleanup

echo "=== 계획 파일 보호 (rc 68)"
setup
printf '# 계획\n- [ ] P1 남은 것\n' > "$T/repo/.claude/plan-active.md"
rc=$( ( export PATH="$T/bin:$PATH" HOME="$T/home" CLAUDE_PROJECT_DIR="$T/repo" \
               FAKE_MODE=plan FAKE_PLAN="$T/repo/.claude/plan-active.md"
        cd "$T/repo" || exit 99
        bash "$CODER" --task "$T/task.md" --targets 'target.txt' \
             --gate 'bash gate.sh' --cwd "$T/repo" --out "$T/out.json"
      ) >"$T/log" 2>&1; printf '%s' $? )
[ "$rc" = "68" ] && ok "⑦ 자식이 계획 파일을 고치면 rc 68" || ng "rc 68 미발화" "rc=$rc $(cat "$T/log")"
grep -q 'P1 남은 것' "$T/repo/.claude/plan-active.md" && ok "⑦-b 계획 파일이 복원됐다" || ng "미복원" "$(cat "$T/repo/.claude/plan-active.md")"
cleanup

echo "=== 자식 출력 — 판정에 쓰지 않는다"
setup
rc=$(run env FAKE_MODE=nojson)
[ "$rc" = "65" ] && ok "⑧ 자식이 아무 출력도 없으면 rc 65(codex 자체가 실패한 것이다)" || ng "rc 65 미발화" "rc=$rc $(cat "$T/log")"
cleanup

# ⭐⭐ 2026-09-16 개정 — `--output-schema` 를 포기했으므로 자식의 JSON 은 **부가 정보**다.
#   판정은 게이트(⑨)와 git(⑦)이 하고, JSON 을 못 읽으면 `rounds` 를 **-1(모른다)** 로 남긴다.
#   ⛔ 왜 포기했나: 스키마를 강제하면 작은 모델이 「구조화 출력을 내는 것」을 과업으로 읽고
#      **도구를 한 번도 쓰지 않은 채** 스키마를 채워 끝낸다(실물 2/2 · 토큰 2,830 · 한 턴 ·
#      파일 무변경인데 files_changed 에 파일 이름이 적혀 있었다).
setup
rc=$(run env FAKE_MODE=badjson)
[ "$rc" = "0" ] && ok "⑨ ⭐ JSON 을 못 읽어도 게이트가 초록이면 통과한다(판정은 게이트가 한다)" \
  || ng "부가 정보로 판정했다" "rc=$rc $(cat "$T/log")"
python3 -c "
import io,json,sys
d=json.loads(io.open(sys.argv[1],encoding='utf-8').read().strip().split(chr(10))[-1])
sys.exit(0 if d['rounds']==-1 else 1)
" "$T/repo/.claude/coder/coder.jsonl" \
  && ok "⑨-b ⭐⭐ 못 읽은 값은 -1(모른다)로 남는다 — 0으로 지어내지 않는다" \
  || ng "정직 공백 위반" "$(tail -1 "$T/repo/.claude/coder/coder.jsonl")"
cleanup

echo "=== 폴백 (rc 70) — 실패가 아니라 설계다"
setup
printf '{"enabled":"off","profile":"testprof"}\n' > "$T/repo/.claude/coder/config.json"
rc=$(run env FAKE_MODE=fix)
[ "$rc" = "70" ] && ok "⑩ enabled=off 면 rc 70" || ng "off 미처리" "rc=$rc $(cat "$T/log")"
cleanup

setup
printf '{"enabled":"on","profile":""}\n' > "$T/repo/.claude/coder/config.json"
rc=$(run env FAKE_MODE=fix)
[ "$rc" = "70" ] && ok "⑪ ⭐ 프로파일이 비면 rc 70(기본값을 지어내지 않는다)" || ng "빈 프로파일" "rc=$rc $(cat "$T/log")"
cleanup

setup
printf '{"enabled":"on","profile":"없는프로파일"}\n' > "$T/repo/.claude/coder/config.json"
rc=$(run env FAKE_MODE=fix)
[ "$rc" = "70" ] && ok "⑫ 프로파일 파일이 없으면 rc 70(base config 로 조용히 돌지 않는다)" || ng "부재 프로파일" "rc=$rc $(cat "$T/log")"
cleanup

setup
rc=$( ( export PATH="$T/bin:$PATH" HOME="$T/home" CLAUDE_PROJECT_DIR="$T/repo"
        cd "$T/repo" || exit 99
        FAKE_MODE=fix bash "$CODER" --task "$T/task.md" --targets 'a.txt,b.txt,c.txt' \
             --gate 'bash gate.sh' --cwd "$T/repo" --out "$T/out.json"
      ) >"$T/log" 2>&1; printf '%s' $? )
[ "$rc" = "70" ] && ok "⑬ ⭐ 파일 수가 상한을 넘으면 rc 70(측정된 범위 밖이다)" || ng "상한 미적용" "rc=$rc $(cat "$T/log")"
cleanup

echo "=== 사용법 (rc 64)"
setup
rc=$( ( export PATH="$T/bin:$PATH" HOME="$T/home"
        bash "$CODER" --task "$T/task.md" --gate 'bash gate.sh' --cwd "$T/repo"
      ) >"$T/log" 2>&1; printf '%s' $? )
[ "$rc" = "64" ] && ok "⑭ ⭐ --targets 가 없으면 rc 64(비우면 쓰기 범위 통제가 꺼진다)" || ng "targets 미검사" "rc=$rc"
rc=$( ( export PATH="$T/bin:$PATH" HOME="$T/home"
        bash "$CODER" --task "$T/task.md" --targets 'target.txt' --cwd "$T/repo"
      ) >"$T/log" 2>&1; printf '%s' $? )
[ "$rc" = "64" ] && ok "⑮ --gate 가 없으면 rc 64(착수 전/후를 가를 수 없다)" || ng "gate 미검사" "rc=$rc"
rc=$( ( export PATH="$T/bin:$PATH" HOME="$T/home"
        bash "$CODER" --task "$T/task.md" --targets '/etc/passwd' --gate 'true' --cwd "$T/repo"
      ) >"$T/log" 2>&1; printf '%s' $? )
[ "$rc" = "64" ] && ok "⑯ 절대경로 대상은 rc 64" || ng "절대경로 허용" "rc=$rc"
cleanup

printf '\npass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
