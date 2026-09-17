#!/usr/bin/env bash
# claudepath.test.sh — `eval.sh claude` 경로(로컬 모델·opus 를 **같은 코드로** 부르는 자리)의 대조군.
# 2026-09-17.
#
# # 왜 있나
#
# `eval.sh` 가 자동 실행할 수 있는 리뷰어는 `codex` 하나뿐이었다. 머리말은 「Claude 리뷰어는
# 셸에서 못 부른다」고 적었는데 그것은 **서브에이전트를 전제한 문장**이고, `claude -p` 경로는
# 그 전제 밖이다(go-tester 가 그 경로로 로컬 모델을 부른다).
#
# ⭐ 그리고 같은 코드로 **opus 도 부를 수 있다** — 프록시 env 를 세우지 않으면 기본
#   엔드포인트로 간다. 한 서브커맨드로 둘을 재면 **조건이 같아져 비교가 정직해진다.**
#
# # 무엇을 잠그나 — 축 셋
#
#   ① 엔드포인트를 주면 프록시 env 를 세우고, 안 주면 세우지 않는다
#   ② 호출이 실패한 케이스는 「놓침」이 아니라 **「미측정」**으로 채점기에 넘어간다
#   ③ 산출이 **JSON 으로 파싱되지 않으면** 그 케이스는 미측정이다
#     ⚠ 이 축의 이름을 「스키마 위반」이라 적었다가 리뷰가 잡았다(2026-09-17) — 실제 검사는
#       파싱과 `findings` 키 존재뿐이고 required 필드는 보지 않는다. **이름과 잠그는 것을 맞춘다.**
#
# ⚠⚠ **산출 JSON 을 셀 때 `manifest.json` 을 빼라.** `_prepare.py` 가 준비 단계에서 그것을
#    만들기 때문에 `*.json` 로 세면 **언제나 「있음」**이 나온다 — 첫 판이 그렇게 틀렸다.
#    세는 대상은 **케이스 id 이름의 JSON**(`<id>.json`)이다. 「탐지기를 먼저 의심하라」.
#
# ⚠ 실제 모델을 부르지 않는다. `PATH` 앞에 가짜 `claude` 를 세워 **우리 배선**만 잰다
#   (이 레포의 `frame-header-check.test.sh` 관례와 같다). 여기서 재는 것은 「모델이 잘하나」가
#   아니라 **「우리 코드가 도는가」**다.
#
# 판정: 0 통과 · 1 실패 · 2 검사 자체가 불가
set -uo pipefail

SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
EVAL="$SELF/eval.sh"
pass=0; fail=0

[ -f "$EVAL" ] || { echo "eval.sh 가 없다 — 검사 불가"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 이 없다 — 검사 불가"; exit 2; }

chk() { # chk <라벨> <실제> <기대>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1  → got=$2 want=$3"; fail=$((fail+1)); fi
}

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

CASES="$W/cases.jsonl"
cat > "$CASES" <<'J'
{"id":"d1","class":"팬텀 심볼","lang":"tsx","defect":true,"diff":"--- a/x.tsx\n+++ b/x.tsx\n@@ -1 +1,2 @@\n+const c = `w${n}`;\n","expect":{"file":"x.tsx","line":1,"any_of":["정의"],"min_severity":"major"}}
{"id":"c1","class":"대조군","lang":"go","defect":false,"diff":"--- a/ok.go\n+++ b/ok.go\n@@ -1 +1,2 @@\n+// 정상\n"}
J

# ── 가짜 claude — 환경을 기록하고 시나리오대로 응답한다 ─────────────────────
mkstub() { # mkstub <bin디렉토리> <시나리오>
  local bin="$1" mode="$2"
  mkdir -p "$bin"
  cat > "$bin/claude" <<STUB
#!/usr/bin/env bash
# 호출될 때의 env 를 남긴다(축 ①이 이것을 본다)
{
  echo "BASE=\${ANTHROPIC_BASE_URL:-}"
  echo "TOKEN_SET=\$([ -n "\${ANTHROPIC_AUTH_TOKEN:-}" ] && echo yes || echo no)"
} >> "$W/env.log"
case "$mode" in
  ok)      printf '{"findings":[{"file":"x.tsx","line":1,"severity":"major","title":"정의가 없다","failure_scenario":"런타임에 undefined","introduced_by_this_change":true}]}' ;;
  fail)    exit 3 ;;
  badjson) printf 'not json at all' ;;
esac
STUB
  chmod +x "$bin/claude"
}

run_eval() { # run_eval <bin> <출력> [엔드포인트인자…]
  local bin="$1" out="$2"; shift 2
  PATH="$bin:$PATH" bash "$EVAL" claude "$CASES" "$out" "$@" > "$out.log" 2>&1
  echo $?
}

echo "=== ① 엔드포인트 유무에 따라 프록시 env 가 갈린다 ==="
B1="$W/bin1"; mkstub "$B1" ok
: > "$W/env.log"
rc=$(run_eval "$B1" "$W/run-noep")
if grep -q '^BASE=$' "$W/env.log" 2>/dev/null; then g=yes; else g=no; fi
chk "①-a 엔드포인트를 안 주면 ANTHROPIC_BASE_URL 이 비어 있다" "$g" "yes"

: > "$W/env.log"
rc=$(run_eval "$B1" "$W/run-ep" --endpoint "http://stub.invalid/v1" --model "stub-model")
if grep -q '^BASE=http' "$W/env.log" 2>/dev/null; then g=yes; else g=no; fi
chk "①-b 엔드포인트를 주면 ANTHROPIC_BASE_URL 이 세워진다" "$g" "yes"
if grep -q '^TOKEN_SET=yes' "$W/env.log" 2>/dev/null; then g=yes; else g=no; fi
chk "①-c 그때 AUTH_TOKEN 도 세워진다" "$g" "yes"

echo "=== ② 호출 실패는 「놓침」이 아니라 「미측정」이다 ==="
B2="$W/bin2"; mkstub "$B2" fail
rc=$(run_eval "$B2" "$W/run-fail")
# 산출 JSON 이 만들어지지 않아야 채점기가 그 케이스를 미측정으로 센다
if ls "$W/run-fail"/d1.json "$W/run-fail"/c1.json >/dev/null 2>&1; then g=있음; else g=없음; fi
chk "②-a 실패한 케이스의 산출 JSON 이 남지 않는다(미측정으로 넘어간다)" "$g" "없음"
# 그리고 실행 자체는 계속 간다(한 케이스 실패로 전체가 죽지 않는다)
chk "②-b 한 케이스가 실패해도 전체가 죽지 않는다(rc 0)" "$rc" "0"

echo "=== ③ 파싱되지 않는 산출은 미측정이다 ==="
B3="$W/bin3"; mkstub "$B3" badjson
rc=$(run_eval "$B3" "$W/run-bad")
if ls "$W/run-bad"/d1.json "$W/run-bad"/c1.json >/dev/null 2>&1; then g=있음; else g=없음; fi
chk "③ JSON 으로 파싱되지 않는 산출은 남기지 않는다" "$g" "없음"

echo "=== ④ ⭐ 대조군 — 정상 응답은 실제로 산출 JSON 이 남는다 ==="
# ②③이 「언제나 없음」이면 그 검사는 아무것도 잠그지 않는다. 이 축이 그것을 막는다.
B4="$W/bin4"; mkstub "$B4" ok
rc=$(run_eval "$B4" "$W/run-ok")
n=$(ls "$W/run-ok"/d1.json "$W/run-ok"/c1.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -ge 1 ]; then g=yes; else g=no; fi
chk "④ 대조군: 정상 응답이면 산출 JSON 이 1개 이상 남는다" "$g" "yes"

echo "=== ⑤ 케이스가 0건이면 판정 2(검사 불가) ==="
: > "$W/empty.jsonl"
B5="$W/bin5"; mkstub "$B5" ok
PATH="$B5:$PATH" bash "$EVAL" claude "$W/empty.jsonl" "$W/run-empty" > /dev/null 2>&1
chk "⑤ 케이스 0건 → rc 2" "$?" "2"

echo
echo "검사 $((pass+fail))개 · 통과 $pass · 실패 $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
