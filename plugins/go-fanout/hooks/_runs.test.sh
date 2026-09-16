#!/usr/bin/env bash
# _runs.test.sh — 「이 세션이 관여한 run 인가」 판별의 대조군.
#
# ⭐ 이 판별을 게이트 둘이 공유하므로(완주·인박스), 여기가 조용히 꺼지면 두 게이트가 함께 꺼진다.
#   그래서 각 검사마다 **반대 방향**(관여가 아닌 것은 관여로 세지 않는다)을 짝으로 둔다.
set -u
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SELF/_runs.sh"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
ng(){ echo "  ⛔ $1 — 기대 $2 실제 $3"; fail=$((fail+1)); }
owns(){ session_owns_run "$1" "$2"; echo $?; }
eq(){ if [ "$2" = "$3" ]; then ok "$1 (rc $2)"; else ng "$1" "$3" "$2"; fi; }

echo "== t1. 도구 호출의 입력에 run 이 있으면 관여다 =="
printf '%s\n' '{"type":"user","message":{"content":"파도 닫아"}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"orca orchestration worker-list --run run_abc --json"}}]}}' > "$D/in.jsonl"
eq "도구 입력" "$(owns "$D/in.jsonl" run_abc)" 0
eq "⭐ 대조군 — 같은 기록에서 **다른 run** 은 남의 것" "$(owns "$D/in.jsonl" run_zzz)" 1

echo "== t2. 도구 **결과**에만 있어도 관여다(인계로 이어받은 세션) =="
printf '%s\n' '{"type":"user","message":{"content":"상태 봐줘"}}' \
  '{"type":"user","toolUseResult":{"stdout":"runId run_abc dispatched"},"message":{"content":[{"type":"tool_result","content":"x"}]}}' > "$D/res.jsonl"
eq "도구 결과" "$(owns "$D/res.jsonl" run_abc)" 0

echo "== t3. ⭐⭐ 모델이 산문에 인용한 run 은 관여가 아니다 =="
# 이 게이트에 막힌 세션은 run_id 를 답변에 적게 된다. 그것을 세면 자기 출력이 자기 근거가 된다.
printf '%s\n' '{"type":"user","message":{"content":"훅 점검"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"run_abc 에 잔여 컨텍스트 2개가 있습니다."}]}}' > "$D/prose.jsonl"
eq "산문 인용" "$(owns "$D/prose.jsonl" run_abc)" 1

echo "== t4. ⭐ 사람 발화 행(게이트의 차단 문구)도 관여가 아니다 =="
printf '%s\n' '{"type":"user","message":{"content":"Stop hook feedback: run run_abc — 워커 전원 종료, 자원 2개가 살아 있다"}}' > "$D/fb.jsonl"
eq "차단 문구" "$(owns "$D/fb.jsonl" run_abc)" 1

echo "== t5. ⭐ isMeta 행은 하네스가 넣은 것이라 세션의 행위가 아니다 =="
printf '%s\n' '{"type":"user","isMeta":true,"toolUseResult":{"stdout":"run_abc"},"message":{"content":"x"}}' > "$D/meta.jsonl"
eq "isMeta 도구 결과" "$(owns "$D/meta.jsonl" run_abc)" 1
printf '%s\n' '{"type":"assistant","isMeta":true,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"orca x --run run_abc"}}]}}' > "$D/meta2.jsonl"
eq "isMeta 도구 호출" "$(owns "$D/meta2.jsonl" run_abc)" 1

echo "== t6. ⛔ 판별 불가는 rc 2 다 — 「관여 아님」으로 접지 않는다 =="
# 이것을 1(남의 것)로 접으면 transcript 를 못 읽는 조건에서 게이트가 통째로 꺼진다.
eq "transcript 부재"     "$(owns "$D/없는파일.jsonl" run_abc)" 2
eq "경로가 빈 문자열"     "$(owns "" run_abc)" 2
: > "$D/empty.jsonl"
eq "빈 파일은 읽히므로 rc 1(관여한 run 이 없다)" "$(owns "$D/empty.jsonl" run_abc)" 1
eq "run 인자가 없으면 rc 2" "$(owns "$D/in.jsonl" "")" 2

echo "== t7. JSON 이 깨진 줄이 섞여도 나머지를 읽는다 =="
printf '%s\n' '깨진 줄 {{{' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"orca x --run run_abc"}}]}}' > "$D/broken.jsonl"
eq "깨진 줄 혼재" "$(owns "$D/broken.jsonl" run_abc)" 0

echo "== t8. ⭐ 목록(session_runs)은 진단용이고 판정과 일치해야 한다 =="
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"orca a --run run_abc; orca b --run run_x"}}]}}' > "$D/two.jsonl"
got=$(session_runs "$D/two.jsonl" | tr '\n' ' ')
if [ "$got" = "run_abc run_x " ]; then ok "둘 다 나열한다 ($got)"; else ng "목록" "run_abc run_x " "$got"; fi
session_runs "$D/없는파일.jsonl" >/dev/null 2>&1; eq "부재는 rc 2" "$?" 2
# ⚠ 목록의 패턴이 판정보다 좁으면(예 16진만) 실제 형식이 바뀔 때 조용히 빈다 — 그 부류를 여기서 잠근다.
if session_runs "$D/two.jsonl" | grep -qx 'run_x'; then ok "⭐ 16진이 아닌 식별자도 나열한다(패턴을 좁히지 마라)"
else ng "느슨한 식별자" "run_x 포함" "미포함"; fi

echo "== t9. ⭐ 사보타주 — 산문 제외를 지우면 t3 이 붉어져야 한다 =="
# ⚠ 구분자를 / 로 쓰면 필터 안의 // 때문에 sed 가 죽는다(이 레포군이 여러 번 밟은 이식성 함정)
sed 's@select(.type=="tool_use") | .input | tostring@(.text // (.input | tostring))@' "$SELF/_runs.sh" > "$D/sab.sh"
( . "$D/sab.sh"; session_owns_run "$D/prose.jsonl" run_abc ) && sab=0 || sab=$?
if [ "$sab" -eq 0 ]; then ok "사보타주하면 산문 인용이 관여로 잡힌다(탐지기가 살아 있다)"
else ng "사보타주" "0(잡힌다)" "$sab"; fi

echo
echo "검사 $((pass+fail))개 · 통과 $pass · 실패 $fail"
[ "$fail" -eq 0 ]
