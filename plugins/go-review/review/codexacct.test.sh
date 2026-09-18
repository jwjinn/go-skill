#!/usr/bin/env bash
# codexacct.test.sh — codex **계정 게이트**의 대조군 (2026-09-18).
#
# ⭐ 이 스위트가 생긴 이유: 사용자가 codex 계정을 둘 갖고 있고(개인·회사), 리뷰가
#   개인 계정으로 돌면 **산출물이 똑같아 보인다.** 즉 사람이 알아차릴 신호가 없다.
#   그래서 「막았다」를 주장하려면 **막히는 것을 실제로 관측**해야 한다 —
#   이 레포의 규약 그대로다: 「대조군 없는 테스트는 근거가 아니다」.
#
# ⚠ codex 를 실제로 부르지 않는다. 계정 판정과 두 입구(_config.py · codex-ro.sh)의
#   거부 동작만 본다. codex-ro.sh 축은 **가짜 codex** 를 PATH 에 두어 호출 여부를 센다.
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ACCT="$SELF/_codexacct.py"
RO="$SELF/codex-ro.sh"
CFG="$SELF/_config.py"
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# 픽스처: <홈이름> <이메일|-> [apikey|broken|noemail]
mkhome() {
  local name="$1" email="$2" kind="${3:-}"
  local h="$W/$name"; mkdir -p "$h"
  python3 - "$h/auth.json" "$email" "$kind" <<'PY'
import base64, json, sys
path, email, kind = sys.argv[1], sys.argv[2], sys.argv[3]
def jwt(claims):
    b = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "hdr.%s.sig" % b
if kind == "apikey":
    data = {"auth_mode": "apikey", "OPENAI_API_KEY": "sk-test", "tokens": None}
elif kind == "broken":
    data = {"auth_mode": "chatgpt", "tokens": []}
elif kind == "noemail":
    data = {"auth_mode": "chatgpt", "tokens": {"id_token": jwt({"sub": "x"})}}
else:
    data = {"auth_mode": "chatgpt", "tokens": {"id_token": jwt({"email": email})}}
open(path, "w").write(json.dumps(data))
PY
  echo "$h"
}

H_COMPANY=$(mkhome company  sw_platform_ai08@maymust.com)
H_PERSON=$(mkhome  person   jwjinn@gmail.com)
H_LOOKALIKE=$(mkhome lookalike someone@evil-maymust.com)
H_UPPER=$(mkhome upper   SW_Platform_AI08@MayMust.com)
H_APIKEY=$(mkhome apikey  - apikey)
H_BROKEN=$(mkhome broken  - broken)
H_NOEMAIL=$(mkhome noemail - noemail)
H_EMPTY="$W/empty"; mkdir -p "$H_EMPTY"

# want <이름> <기대rc> <기대문구|-> <CODEX_HOME> [env 추가...]
want() {
  local n="$1" e="$2" m="$3" home="$4"; shift 4
  local out rc
  out=$(env CODEX_HOME="$home" CLAUDE_REVIEW_CODEX_DOMAINS="maymust.com" \
            CLAUDE_REVIEW_CODEX_ACCOUNT_GATE="" CLAUDE_PROJECT_DIR="$W" "$@" \
            python3 "$ACCT" 2>&1); rc=$?
  if [ "$rc" != "$e" ]; then bad "$n → rc=$rc want=$e ($out)"; return; fi
  if [ "$m" != "-" ] && ! printf '%s' "$out" | grep -q -- "$m"; then
    bad "$n → 다른 사유로 판정했다(출력에 '$m' 없음): $out"; return
  fi
  ok "$n"
}

echo "=== ⭐ ① 허용 계정만 연다 (fail-closed)"
want "회사 계정은 통과한다"                  0 "maymust.com"        "$H_COMPANY"
want "⛔ 개인 계정은 거부한다(이 스위트의 존재 이유)" 1 "jwjinn@gmail.com" "$H_PERSON"
want "⚠ 유사 도메인은 거부한다(endswith 함정)" 1 "evil-maymust.com"  "$H_LOOKALIKE"
want "대문자 표기도 같은 계정으로 본다"        0 "maymust.com"        "$H_UPPER"

echo "=== ② 확인하지 못하면 닫는다 (모르는 것을 근거로 열지 않는다)"
want "auth.json 이 없으면 거부"               1 "로그인 기록이 없다" "$H_EMPTY"
want "API 키 모드는 거부(계정을 알 수 없다)"  1 "API 키 모드"        "$H_APIKEY"
want "tokens 형식이 깨지면 거부(죽지 않는다)" 1 "ChatGPT 토큰이 없다" "$H_BROKEN"
want "email 클레임이 없으면 거부"             1 "이메일을 읽지 못했다" "$H_NOEMAIL"

echo "=== ③ 정책이 어디서 오나"
out=$(env CODEX_HOME="$H_PERSON" CLAUDE_REVIEW_CODEX_DOMAINS="" \
          CLAUDE_REVIEW_CODEX_ACCOUNT_GATE="" CLAUDE_PROJECT_DIR="$W" python3 "$ACCT" 2>&1)
[ $? -eq 0 ] && ok "정책이 없으면 가리지 않는다(공용 플러그인 기본)" \
              || bad "정책이 없는데 닫혔다 — 남의 기기에서 리뷰가 통째로 막힌다: $out"

mkdir -p "$W/.claude/review"
cat > "$W/.claude/review/config.json" <<'JSON'
{"preset": "P2", "codex_account_domains": ["maymust.com"]}
JSON
out=$(env CODEX_HOME="$H_PERSON" CLAUDE_REVIEW_CODEX_DOMAINS="" \
          CLAUDE_REVIEW_CODEX_ACCOUNT_GATE="" CLAUDE_PROJECT_DIR="$W" python3 "$ACCT" 2>&1)
[ $? -eq 1 ] && ok "⭐ config.json 의 정책만으로도 닫힌다(env 없이)" \
              || bad "레포 정책이 먹지 않았다: $out"

out=$(env CODEX_HOME="$H_PERSON" CLAUDE_REVIEW_CODEX_DOMAINS="maymust.com" \
          CLAUDE_REVIEW_CODEX_ACCOUNT_GATE="off" CLAUDE_PROJECT_DIR="$W" python3 "$ACCT" 2>&1)
[ $? -eq 0 ] && ok "사람이 명시적으로 끄면 열린다(=off)" \
              || bad "끄는 스위치가 동작하지 않는다: $out"

out=$(env CODEX_HOME="$H_PERSON" CLAUDE_REVIEW_CODEX_DOMAINS="maymust.com" \
          CLAUDE_REVIEW_CODEX_ACCOUNT_GATE="1" CLAUDE_PROJECT_DIR="$W" python3 "$ACCT" 2>&1)
[ $? -eq 1 ] && ok "⚠ 'off' 가 아닌 값(1)은 끈 것으로 보지 않는다" \
              || bad "스위치 값이 여럿이다 — 껐다고 착각하는 경로가 생긴다: $out"

echo "=== ⭐⭐ ④ 입구 둘이 실제로 거부하나 (여기가 본체다)"
# 가짜 codex — 불리면 흔적을 남긴다. 게이트가 살아 있으면 흔적이 없어야 한다.
mkdir -p "$W/bin"
cat > "$W/bin/codex" <<'FAKE'
#!/usr/bin/env bash
echo called >> "$FAKE_CODEX_LOG"
exit 0
FAKE
chmod +x "$W/bin/codex"
LOG="$W/codex-called.log"; : > "$LOG"

out=$(env PATH="$W/bin:$PATH" FAKE_CODEX_LOG="$LOG" CODEX_HOME="$H_PERSON" \
          CLAUDE_REVIEW_CODEX_DOMAINS="maymust.com" CLAUDE_REVIEW_CODEX_ACCOUNT_GATE="" \
          CLAUDE_PROJECT_DIR="$W" bash "$RO" --out /dev/null "프롬프트" 2>&1); rc=$?
[ "$rc" = "66" ] && ok "codex-ro.sh 가 개인 계정에서 rc 66 으로 거부한다" \
                 || bad "codex-ro.sh rc=$rc (want 66): $out"
[ ! -s "$LOG" ] && ok "⛔ 거부되면 codex 가 **한 번도 불리지 않는다**" \
                || bad "거부했다면서 codex 를 불렀다($(wc -l < "$LOG")회) — 게이트가 장식이다"

: > "$LOG"
out=$(env PATH="$W/bin:$PATH" FAKE_CODEX_LOG="$LOG" CODEX_HOME="$H_COMPANY" \
          CLAUDE_REVIEW_CODEX_DOMAINS="maymust.com" CLAUDE_REVIEW_CODEX_ACCOUNT_GATE="" \
          CLAUDE_PROJECT_DIR="$W" bash "$RO" --out /dev/null "프롬프트" 2>&1); rc=$?
[ -s "$LOG" ] && ok "⭐ 대조군: 회사 계정이면 codex 가 실제로 불린다(게이트가 하중을 받는다)" \
              || bad "허용 계정인데도 안 불렸다 — 게이트가 아니라 다른 것이 막고 있다(rc=$rc): $out"

# _config.py 축 — codex 자리가 비는가
seat_out() {
  env CODEX_HOME="$1" CLAUDE_REVIEW_CODEX_DOMAINS="maymust.com" \
      CLAUDE_REVIEW_CODEX_ACCOUNT_GATE="" CLAUDE_PROJECT_DIR="$W" \
      PATH="$W/bin:$PATH" python3 "$CFG" 2>&1
}
out=$(seat_out "$H_PERSON")
printf '%s' "$out" | grep -q "허용되지 않아" \
  && ok "_config.py 가 개인 계정에서 preset 을 내린다" \
  || bad "_config.py 가 계정을 보지 않는다: $(printf '%s' "$out" | head -3)"
# ⚠ 이 검사는 **자리 표를 직접 본다.** 앞선 판은 `&&`/`||` 로 엮여 있어 표를 못 찾아도
#   ok 가 나왔다 — 「초록은 돌았다가 아니라 실패하지 않았다」의 전형이고, 이 스위트가
#   막으려는 부류와 같은 부류다. 그래서 **표가 실제로 있는지부터** 센다.
seatlines() { printf '%s\n' "$1" | grep -cE '^  (contract|blind|cross|merger) '; }
[ "$(seatlines "$out")" = "4" ] \
  && ok "자리 표를 실제로 읽었다(4줄)" \
  || bad "⛔ 자리 표가 4줄이 아니다($(seatlines "$out")) — 아래 검사들이 무의미하다"
if printf '%s\n' "$out" | grep -qE '^  (contract|blind|cross|merger) +codex'; then
  bad "⛔ 내렸다면서 codex 자리가 남아 있다 — 그 자리는 아무도 리뷰하지 않는다"
else
  ok "⛔ 내린 뒤 codex 자리가 남지 않는다"
fi
printf '%s' "$out" | grep -q "codex 를 설치하라" \
  && bad "⚠ 사유가 계정인데 「설치하라」고 안내한다 — 사람을 반대 방향으로 보낸다" \
  || ok "⚠ 계정 사유에는 계정을 고치라고 안내한다(틀린 사유 금지)"

out=$(seat_out "$H_COMPANY")
printf '%s' "$out" | grep -q "허용되지 않아" \
  && bad "대조군 실패 — 회사 계정인데 내렸다" \
  || ok "⭐ 대조군: 회사 계정에서는 구성이 그대로다"
printf '%s\n' "$out" | grep -qE '^  (contract|blind|cross|merger) +codex' \
  && ok "⭐ 대조군: 그때 codex 자리가 실제로 남아 있다(게이트가 하중을 받는다)" \
  || bad "회사 계정인데 codex 자리가 없다 — 이 스위트가 무엇을 재는지 알 수 없다"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
