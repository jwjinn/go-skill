#!/usr/bin/env bash
# deps-check.sh · _deps.sh 대조군.
#
# ⭐ 이 스위트가 지키는 것은 「검사가 초록이다」가 아니라 **「도구를 빼면 실제로 잡는다」** 다.
#   의존성 검사기가 죽어 있으면 그 초록은 이 체인이 가장 싫어하는 것 —「그 축을 아예 안 봤다」— 이고,
#   하필 이 스크립트가 잡으려는 결함이 바로 그 부류다(jq 부재 시 게이트의 조용한 통과).
#
# ⚠ 도구를 진짜로 지울 수는 없으므로 **PATH 를 좁혀서** 없는 상태를 만든다.
#   그래서 「그 기계에 무엇이 깔렸나」와 무관하게 결정적으로 돈다.
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SELF/.." && pwd)
CHK="$SELF/deps-check.sh"

pass=0; fail=0
chk() { # $1=label $2=출력 $3=패턴 $4=yes|no
  if printf '%s' "$2" | grep -q -- "$3"; then got=yes; else got=no; fi
  if [ "$got" = "$4" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1  → got=$got want=$4  (패턴: $3)"; fail=$((fail+1)); fi
}
chkrc() { # $1=label $2=실제rc $3=기대rc
  if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1  → rc=$2 want=$3"; fail=$((fail+1)); fi
}

# ── PATH 를 좁힌 가짜 환경 ──────────────────────────────────────────────────
# $1 에 나열한 것 **말고** 기본 도구만 심링크한다.
BASE_TOOLS="bash sh sed grep cat date stat printf tr wc cut ls basename dirname mktemp cksum awk rm head tail env chmod mkdir sleep expr uname"
mkbin() {  # mkbin "추가로 넣을 도구들"
  BIN=$(mktemp -d)
  for c in $BASE_TOOLS $1; do
    p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$BIN/$c"
  done
  printf '%s' "$BIN"
}

echo "=== ① 이 기계의 실제 상태 — 필수가 다 있으면 판정 0"
out=$(bash "$CHK" 2>&1); rc=$?
chk "검사 개수를 말한다(초록 한 줄로 끝내지 않는다)" "$out" '검사' yes
chk "필수 절이 있다"                                  "$out" '── 필수' yes
chk "선택 절이 있다"                                  "$out" '── 선택' yes
chk "리뷰 구성을 해석한다"                            "$out" '리뷰 자리' yes
if [ "$rc" -le 1 ]; then echo "  ok   판정이 0 또는 1 이다(rc=$rc)"; pass=$((pass+1));
else echo "  FAIL 판정이 2 다 — 이 기계에 필수 도구가 없다(rc=$rc)"; fail=$((fail+1)); fi

echo
echo "=== ⭐ 사보타주 ② jq 를 빼면 — **필수 부재로 판정 2** 여야 한다"
BIN=$(mkbin "git python3"); rm -f "$BIN/jq"
out=$(PATH="$BIN" bash "$CHK" 2>&1); rc=$?
chkrc "판정 2(필수 부재)"                    "$rc" 2
chk "jq 를 이름으로 지목한다"                "$out" 'jq' yes
chk "무엇이 죽는지 말한다(Stop 게이트)"      "$out" 'Stop 게이트' yes
chk "설치 명령을 준다"                       "$out" 'brew install jq' yes
chk "「막지 않는다」를 경고한다"              "$out" '아무것도 막지 않는다' yes
rm -rf "$BIN"

echo
echo "=== ⭐ 사보타주 ③ python3 를 빼면 — 판정 2 이고 구성 해석이 **미검사**로 남는다"
BIN=$(mkbin "git jq"); rm -f "$BIN/python3"
out=$(PATH="$BIN" bash "$CHK" 2>&1); rc=$?
chkrc "판정 2"                               "$rc" 2
chk "python3 를 지목한다"                    "$out" 'python3' yes
chk "구성을 「해석했다」고 말하지 않는다"     "$out" '리뷰 자리:' no
rm -rf "$BIN"

echo
echo "=== ⭐ 사보타주 ④ codex·timeout 만 빼면 — 체인은 도니까 **판정 1**(경고)"
BIN=$(mkbin "git jq python3")
out=$(PATH="$BIN" bash "$CHK" 2>&1); rc=$?
chkrc "판정 1(선택 부재)"                    "$rc" 1
chk "codex 부재를 경고로 센다"               "$out" 'codex' yes
chk "필수 부재로 승격하지 않는다"            "$out" '부재 0' yes
chk "「체인은 돈다」를 말한다"                 "$out" '체인은 돈다' yes
rm -rf "$BIN"

echo
echo "=== ⑤ timeout 이름 해석 — timeout 없고 gtimeout 만 있으면 gtimeout 을 고른다"
BIN=$(mkbin "")
p=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
if [ -n "$p" ]; then
  ln -sf "$p" "$BIN/gtimeout"
  got=$(PATH="$BIN" bash -c '. "$1/hooks/_deps.sh"; deps_timeout_cmd' _ "$ROOT")
  if [ "$got" = "gtimeout" ]; then echo "  ok   gtimeout 으로 폴백한다"; pass=$((pass+1));
  else echo "  FAIL gtimeout 폴백 실패 → '$got'"; fail=$((fail+1)); fi
else
  echo "  ok   (이 기계에 timeout 계열이 없어 건너뛴다 — 미검사이지 통과가 아니다)"; pass=$((pass+1))
fi
rm -f "$BIN/timeout" "$BIN/gtimeout"
got=$(PATH="$BIN" bash -c '. "$1/hooks/_deps.sh"; deps_timeout_cmd' _ "$ROOT")
if [ -z "$got" ]; then echo "  ok   둘 다 없으면 **빈 값**이다(없는 것을 있다고 말하지 않는다)"; pass=$((pass+1));
else echo "  FAIL 둘 다 없는데 '$got' 을 돌려줬다"; fail=$((fail+1)); fi
rm -rf "$BIN"

echo
echo "=== ⑥ codex-ro.sh — timeout 이 없어도 **죽지 않고** 상한 없이 부른다"
BIN=$(mkbin "git python3 jq")
# codex 자리에 「인자를 그대로 찍는」 가짜를 둔다(실제 codex 를 부르지 않는다).
printf '#!/bin/sh\necho CALLED\n' > "$BIN/codex"; chmod +x "$BIN/codex"
out=$(PATH="$BIN" bash "$ROOT/review/codex-ro.sh" 'ping' 2>&1); rc=$?
chkrc "rc 0 (127 로 죽지 않는다)"            "$rc" 0
chk "codex 가 실제로 불렸다"                 "$out" 'CALLED' yes
chk "상한 없이 부른다는 사실을 말한다"        "$out" '시간 상한 없이' yes
# 대조군: timeout 이 있으면 그 문구가 **뜨지 않아야** 한다
p=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
if [ -n "$p" ]; then
  ln -sf "$p" "$BIN/timeout"
  out=$(PATH="$BIN" bash "$ROOT/review/codex-ro.sh" 'ping' 2>&1)
  chk "⭐ 대조군 — timeout 이 있으면 그 경고가 없다" "$out" '시간 상한 없이' no
  chk "⭐ 대조군 — 그래도 codex 는 불린다"           "$out" 'CALLED' yes
fi
rm -rf "$BIN"

echo
echo "=== ⭐⭐ 사보타주 ⑦ jq 부재 시 Stop 게이트가 **침묵하지 않는다**"
# 이것이 이 파일의 존재 이유다. 종전에는 출력 0바이트 · rc=0 이었다.
BIN=$(mkbin "git python3")   # jq 없음
P=$(mktemp -d); mkdir -p "$P/.claude"
printf '# 계획\n작업 위치: %s\n- [ ] 하나\n- [ ] 둘\n' "$P" > "$P/.claude/plan-active.md"
# ⚠ 계획 게이트는 2026-09-16 부터 「이 세션이 그 계획을 **채택**했나」를 본다 — 픽스처의 사람
#   프롬프트가 go 호출이어야 차단 기대가 성립한다(아니면 남의 계획으로 보고 알림만 낸다).
printf '{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user","content":"<command-name>/go-review:go</command-name>"}}\n' > "$P/t.jsonl"
IN="{\"session_id\":\"s1\",\"transcript_path\":\"$P/t.jsonl\"}"
for h in plan-file-gate todo-completion-gate review-gate; do
  out=$(printf '%s' "$IN" | PATH="$BIN" CLAUDE_DEPS_NOTICE_TTL=0 CLAUDE_PROJECT_DIR="$P" bash "$ROOT/hooks/$h.sh" 2>&1)
  chk "$h 가 jq 부재를 알린다"     "$out" 'jq' yes
  chk "$h 가 무장 안 됨을 말한다"  "$out" '무장되지 않았다' yes
done
out=$(printf '%s' "$IN" | PATH="$BIN" CLAUDE_DEPS_NOTICE_TTL=0 CLAUDE_PROJECT_DIR="$P" bash "$ROOT/hooks/goal-echo.sh" 2>&1)
chk "goal-echo 도 알린다(평문 이벤트)" "$out" 'jq' yes

echo "  — 출력이 **유효한 JSON** 인가(Stop 훅 계약)"
if printf '%s' "$IN" | PATH="$BIN" CLAUDE_DEPS_NOTICE_TTL=0 CLAUDE_PROJECT_DIR="$P" bash "$ROOT/hooks/plan-file-gate.sh" 2>/dev/null \
   | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "systemMessage" in d else 1)' 2>/dev/null; then
  echo "  ok   jq 없이 만든 JSON 이 파싱된다"; pass=$((pass+1))
else
  echo "  FAIL jq 없이 만든 JSON 이 깨졌다"; fail=$((fail+1))
fi

echo "  — ⭐ 대조군: jq 가 **있으면** 그 알림 대신 **진짜 차단**이 나와야 한다"
out=$(printf '%s' "$IN" | CLAUDE_DEPS_NOTICE_TTL=0 CLAUDE_PROJECT_DIR="$P" bash "$ROOT/hooks/plan-file-gate.sh" 2>&1)
chk "차단 판정이 나온다"                 "$out" '"decision": "block"' yes
chk "jq 부재 알림은 나오지 않는다"        "$out" '무장되지 않았다' no
rm -rf "$BIN" "$P"

echo
echo "=== ⑧ 알림 TTL — 같은 말을 매 턴 반복하지 않는다"
BIN=$(mkbin "git python3")
P=$(mktemp -d); mkdir -p "$P/.claude"
printf '# 계획\n작업 위치: %s\n- [ ] 하나\n' "$P" > "$P/.claude/plan-active.md"
# ⚠ 계획 게이트는 2026-09-16 부터 「이 세션이 그 계획을 **채택**했나」를 본다 — 픽스처의 사람
#   프롬프트가 go 호출이어야 차단 기대가 성립한다(아니면 남의 계획으로 보고 알림만 낸다).
printf '{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user","content":"<command-name>/go-review:go</command-name>"}}\n' > "$P/t.jsonl"
IN="{\"session_id\":\"s1\",\"transcript_path\":\"$P/t.jsonl\"}"
rm -f "${TMPDIR:-/tmp}"/claude-go-deps-jq-* 2>/dev/null || true
o1=$(printf '%s' "$IN" | PATH="$BIN" CLAUDE_PROJECT_DIR="$P" bash "$ROOT/hooks/plan-file-gate.sh" 2>&1)
o2=$(printf '%s' "$IN" | PATH="$BIN" CLAUDE_PROJECT_DIR="$P" bash "$ROOT/hooks/plan-file-gate.sh" 2>&1)
chk "첫 번째는 알린다"     "$o1" 'jq' yes
chk "두 번째는 조용하다"   "$o2" 'jq' no
rm -f "${TMPDIR:-/tmp}"/claude-go-deps-jq-* 2>/dev/null || true
rm -rf "$BIN" "$P"

echo
echo "=== ⑨ JSON 이스케이프 — 따옴표·역슬래시·개행을 담아도 깨지지 않는다"
esc=$(bash -c '. "$1/hooks/_deps.sh"; deps_json_escape "$2"' _ "$ROOT" 'a"b\c
d')
if printf '{"m":"%s"}' "$esc" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["m"]=="a\"b\\c\nd" else 1)' 2>/dev/null; then
  echo "  ok   이스케이프 왕복이 정확하다"; pass=$((pass+1))
else
  echo "  FAIL 이스케이프 왕복이 틀렸다"; fail=$((fail+1))
fi

echo
echo "=== ⑩ doctor.sh 가 의존성 축을 **실제로 센다**"
BIN=$(mkbin "git python3")   # jq 없음
P=$(mktemp -d); mkdir -p "$P/.claude"; printf '{"hooks":{}}' > "$P/.claude/settings.json"
out=$(PATH="$BIN" CLAUDE_PROJECT_DIR="$P" bash "$ROOT/hooks/doctor.sh" 2>&1)
chk "doctor 가 필수 부재를 결함으로 올린다" "$out" '필수 도구' yes
chk "jq 를 이름으로 지목한다"                "$out" 'jq' yes
rm -rf "$BIN"
out=$(CLAUDE_PROJECT_DIR="$P" bash "$ROOT/hooks/doctor.sh" 2>&1)
chk "⭐ 대조군 — 도구가 다 있으면 그 결함이 없다" "$out" '필수 도구 부재' no
chk "⭐ 대조군 — 대신 충족 개수를 말한다"           "$out" '필수 도구 4/4' yes
rm -rf "$P"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
