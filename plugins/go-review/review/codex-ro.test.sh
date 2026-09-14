#!/usr/bin/env bash
# codex-ro.test.sh — 리뷰 경로의 codex 가 **정말** 읽기 전용인가.
#
# ⭐ 이 스위트가 생긴 이유(2026-09-02 실측):
#   역할 정본 3종은 "구조적으로 읽기 전용이라 코드를 고칠 수 없다"고 주장한다.
#   Claude 서브에이전트에서는 참이다(`tools: Read, Grep, Glob` — 쓰기 도구가 **없다**).
#   그런데 병합자·리뷰어가 codex 로 내려가면 그 frontmatter 는 **무력**해지고,
#   보장은 `-c sandbox_mode="read-only"` 플래그 하나에 얹힌다.
#   ⛔ 대조군으로 확인: 플래그 없이 돌리면 codex 가 파일을 **실제로 만들었다**
#     (기본 `workspace-write [workdir, /tmp, $TMPDIR]` · **workdir 은 작업 중인 프로젝트**).
#   → 규율을 구조로 바꾼다: 입구를 `codex-ro.sh` 하나로 좁히고, 스킬 문서에 남은
#     맨 `codex exec` 를 이 테스트가 잡는다.
#
# ⚠ 기본은 **codex 를 실제로 호출하지 않는다**(느리고 토큰을 쓴다). 인자·문서 축만 본다.
#   실호출 대조군은 CLAUDE_CODEX_LIVE=1 일 때만 돈다.
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
RO="$SELF/codex-ro.sh"
pass=0; fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
want() { # want <이름> <기대exit> <기대메시지조각|-> <명령...>
  # ⚠ exit 코드만 보면 **어느 분기가 거부했는지** 알 수 없다 — 포괄 분기(`-*`)도 같은 64 를
  #   낸다. 그래서 사유 문구까지 본다(그래야 ④ 사보타주가 의미를 갖는다).
  local n="$1" e="$2" m="$3"; shift 3
  local out; out=$("$@" 2>&1); local g=$?
  if [ "$g" != "$e" ]; then bad "$n → exit=$g want=$e"; return; fi
  if [ "$m" != "-" ] && ! printf '%s' "$out" | grep -q -- "$m"; then
    bad "$n → 다른 분기가 거부했다(사유에 '$m' 없음)"; return
  fi
  ok "$n"
}

echo "=== ⭐ ① 읽기 전용을 깨는 인자는 거부한다 (통제를 인자로 끌 수 없다)"
want "--full-auto 거부(전용 분기)"                    64 "읽기 전용을 덮어쓴다" bash "$RO" --full-auto "x"
want "--dangerously-bypass... 거부"                  64 "읽기 전용을 덮어쓴다" bash "$RO" --dangerously-bypass-approvals-and-sandbox "x"
want "--yolo 거부"                                   64 "읽기 전용을 덮어쓴다" bash "$RO" --yolo "x"
want "-c sandbox_mode 거부"                          64 "맨 '-c' 는 받지 않는다" bash "$RO" -c sandbox_mode=workspace-write "x"
want "-c approval_policy 거부"                       64 "맨 '-c' 는 받지 않는다" bash "$RO" -c approval_policy=never "x"
want "⭐ 모르는 -c 도 거부(화이트리스트 없음)"        64 "맨 '-c' 는 받지 않는다" bash "$RO" -c model_reasoning_effort=high "x"
want "모르는 옵션 거부(포괄 분기)"                    64 "모르는 옵션" bash "$RO" --write-everything "x"
want "프롬프트 없으면 거부"                          64 "프롬프트가 없다" bash "$RO" --out /dev/null

echo "=== ② 스크립트가 실제로 붙이는 플래그 (소스 축)"
chk() { if printf '%s' "$2" | grep -q -- "$3"; then g=yes; else g=no; fi
  [ "$g" = "$4" ] && ok "$1" || bad "$1 → got=$g want=$4 ($3)"; }
src=$(cat "$RO")
chk "sandbox_mode=read-only 를 붙인다"   "$src" 'sandbox_mode="read-only"' yes
chk "approval_policy=never 를 붙인다"    "$src" 'approval_policy="never"' yes
chk "⚠ < /dev/null 을 붙인다(멈춤 방지)"  "$src" '< /dev/null' yes
chk "스키마를 주면 JSON 파싱을 확인한다"   "$src" 'json.load' yes

echo "=== ⭐⭐ ③ 문서 축 — 스킬이 맨 codex exec 를 부르지 않는가"
# ⭐ 이것이 「규율 → 구조」의 실제 집행점이다. 래퍼가 있어도 문서가 직접 부르면 무의미하다.
# ⚠ 줄 단위로 보면 **플래그가 다음 줄에 있는 명령**을 오탐한다(백슬래시 연결).
#   그래서 연결된 줄을 이어 붙인 뒤 명령 단위로 판정한다 — 탐지기부터 의심하라.
DET="$SELF/_codexflags.py"
bare=$(python3 "$DET" "$SELF/../commands")
if [ -z "$(printf '%s' "$bare" | tr -d '[:space:]')" ]; then
  ok "⭐⭐ 스킬 문서의 모든 codex exec 가 플래그를 달거나 래퍼를 쓴다"
else
  bad "플래그 없는 codex exec 가 남아 있다:"; printf '       %s\n' "$bare"
fi

# ⭐ 대조군 — 탐지기가 **살아 있는지** 먼저 증명한다("0 이 나오면 탐지기부터 의심하라").
#   위 ③ 이 초록이어도 탐지기가 죽어 있으면 아무것도 지키지 않는다.
DB=$(mktemp -d); DG=$(mktemp -d)
printf '%s\n' 'timeout 900 codex exec "$(cat p.txt)" \' '  -o out.json' > "$DB/bad.md"
printf '%s\n' 'timeout 900 codex exec "$(cat p.txt)" \' '  -c sandbox_mode="read-only" \' '  -o out.json' > "$DG/ok.md"
[ -n "$(python3 "$DET" "$DB")" ] \
  && ok "⭐ 탐지기 생존 — 플래그 없는 명령을 실제로 잡는다" \
  || bad "탐지기가 죽어 있다 — ③ 의 초록은 「돌았다」가 아니라 「실패하지 않았다」다"
[ -z "$(python3 "$DET" "$DG" | tr -d '[:space:]')" ] \
  && ok "⭐⭐ 플래그가 **다음 줄**에 있으면 오탐하지 않는다(줄 연결을 폈다)" \
  || bad "오탐 — 플래그가 다음 줄에 있는데 위반으로 봤다"
rm -rf "$DB" "$DG"

echo "=== ④ 사보타주 — 거부 목록을 지우면 발화하는가"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
sed 's/    --full-auto|--dangerously-bypass-approvals-and-sandbox|--yolo)/    --nonexistent-flag-xyz)/' \
    "$RO" > "$W/sab.sh"
# ⚠ 사보타주해도 포괄 분기(`-*`)가 같은 exit 64 를 낸다 — **사유 문구**로 갈라야 한다.
#   (처음엔 exit 만 봤고, 그래서 사보타주가 「발화하지 않았다」고 잘못 보고했다)
sab_out=$(bash "$W/sab.sh" --full-auto "x" 2>&1)
if printf '%s' "$sab_out" | grep -q '읽기 전용을 덮어쓴다'; then
  bad "사보타주가 발화하지 않았다 — 전용 거부 분기가 하중을 받지 않는다는 뜻이다"
else
  ok "⭐ 전용 분기를 지우면 --full-auto 가 다른 사유로 떨어진다(대조군 발화)"
fi

echo "=== ⚠ ⑤ 실호출 대조군 (CLAUDE_CODEX_LIVE=1 일 때만)"
if [ "${CLAUDE_CODEX_LIVE:-0}" = "1" ]; then
  P="$W/live-write-probe.txt"
  rm -f "$P"
  bash "$RO" --out /dev/null --err "$W/e.log" \
    "$P 파일에 wrote 라고 써라. 다른 말은 하지 마라." >/dev/null 2>&1
  [ -f "$P" ] && bad "⛔ 래퍼를 거쳐도 파일이 만들어졌다 — 읽기 전용이 깨졌다" \
               || ok "⭐ 래퍼 경유는 파일을 만들지 못한다"
  rm -f "$P"
  timeout 120 codex exec "$P 파일에 wrote 라고 써라. 다른 말은 하지 마라." \
    < /dev/null >/dev/null 2>&1
  [ -f "$P" ] && ok "⛔ 대조군: 플래그 없이는 실제로 만들어진다(래퍼가 하중을 받는다)" \
               || bad "대조군이 발화하지 않았다 — 기본이 이미 read-only 면 이 스위트의 전제가 틀렸다"
  rm -f "$P"
else
  echo "  skip 실호출 생략 — CLAUDE_CODEX_LIVE=1 로 켜라 (⚠ 2회 codex 호출 비용)"
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
