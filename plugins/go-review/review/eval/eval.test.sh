#!/usr/bin/env bash
# eval.test.sh — 회귀 평가 하네스 자체의 대조군.
#
# ⭐ 이 스위트가 지키는 것 하나: **「전부 결함이라고 답하는 리뷰어」가 만점을 받지 않는다.**
#   결함 케이스만 모은 평가에서는 그 리뷰어가 재현율 100% 로 최고 점수를 받는다.
#   대조군 케이스가 그것을 잡고, 아래 t3 가 **대조군이 실제로 그 일을 하는지** 잡는다.
#   (원 레포가 46행에 걸쳐 배운 「대조군 없는 테스트는 근거가 아니다」를 평가 자신에 적용한 것)
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
pass=0; fail=0

chk() { # $1=label $2=출력 $3=패턴 $4=yes|no
  if printf '%s' "$2" | grep -q -- "$3"; then got=yes; else got=no; fi
  if [ "$got" = "$4" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1  → got=$got want=$4  (패턴: $3)"; fail=$((fail+1)); fi
}

W=$(mktemp -d)
CASES="$W/cases.jsonl"
cat > "$CASES" <<'J'
{"id":"d1","class":"팬텀 심볼","lang":"tsx","defect":true,"diff":"--- a/x.tsx\n+++ b/x.tsx\n@@ -1 +1,2 @@\n+const c = `w${n}`;\n","expect":{"file":"x.tsx","line":1,"any_of":["정의"],"min_severity":"major"}}
{"id":"d2","class":"순서가 계약","lang":"go","defect":true,"diff":"--- a/s.go\n+++ b/s.go\n@@ -1 +1,2 @@\n+h := Chain(mux, Authorize, Audit)\n","expect":{"file":"s.go","line":1,"any_of":["순서"],"min_severity":"major"}}
{"id":"c1","class":"대조군","lang":"go","defect":false,"diff":"--- a/ok.go\n+++ b/ok.go\n@@ -1 +1,2 @@\n+// 근거가 적힌 정상 코드\n"}
{"id":"c2","class":"대조군","lang":"go","defect":false,"diff":"--- a/ok2.go\n+++ b/ok2.go\n@@ -1 +1,2 @@\n+// 정상\n"}
J

mkres() { mkdir -p "$1"; }
put() { printf '%s' "$2" > "$1"; }

# ── t1 완벽한 리뷰어 ────────────────────────────────────────────────────────
echo "=== t1 정답을 그대로 짚는 리뷰어"
R="$W/perfect"; mkres "$R"
put "$R/d1.json" '{"findings":[{"file":"x.tsx","line":1,"severity":"major","summary":"클래스 정의가 없다"}]}'
put "$R/d2.json" '{"findings":[{"file":"s.go","line":1,"severity":"major","summary":"미들웨어 순서가 뒤집혔다"}]}'
put "$R/c1.json" '{"findings":[]}'
put "$R/c2.json" '{"findings":[]}'
out=$(python3 "$SELF/_score.py" "$CASES" "$R" perfect 2>&1)
chk "재현율 100%"  "$out" '위치 재현율 2/2 = 100%' yes
chk "오탐 0%"      "$out" '오탐률 0/2 = 0%' yes

# ── t2 아무것도 보고하지 않는 리뷰어 ─────────────────────────────────────────
echo "=== t2 침묵하는 리뷰어 — 대조군은 만점, 결함은 0점이어야 한다"
R="$W/silent"; mkres "$R"
for i in d1 d2 c1 c2; do put "$R/$i.json" '{"findings":[]}'; done
out=$(python3 "$SELF/_score.py" "$CASES" "$R" silent 2>&1)
chk "결함 재현율 0%"                 "$out" '위치 재현율 0/2 = 0%' yes
chk "⭐ 그래도 오탐은 0% 다(같은 「보고 0」이 반대 뜻)" "$out" '오탐률 0/2 = 0%' yes

# ── t3 ⭐ 전부 결함이라고 답하는 리뷰어 ──────────────────────────────────────
echo "=== t3 ⭐ 「전부 결함」 리뷰어 — 재현율은 만점이지만 오탐이 100% 여야 한다"
R="$W/paranoid"; mkres "$R"
put "$R/d1.json" '{"findings":[{"file":"x.tsx","line":1,"severity":"blocker","summary":"정의가 없다"}]}'
put "$R/d2.json" '{"findings":[{"file":"s.go","line":1,"severity":"blocker","summary":"순서 문제"}]}'
put "$R/c1.json" '{"findings":[{"file":"ok.go","line":1,"severity":"blocker","summary":"위험해 보인다"}]}'
put "$R/c2.json" '{"findings":[{"file":"ok2.go","line":1,"severity":"major","summary":"의심스럽다"}]}'
out=$(python3 "$SELF/_score.py" "$CASES" "$R" paranoid 2>&1)
chk "재현율은 100% 다"                "$out" '위치 재현율 2/2 = 100%' yes
chk "⭐ 오탐률 100% 로 드러난다"       "$out" '오탐률 2/2 = 100%' yes

# ── t4 산출 없음 = 미측정(놓침이 아니다) ────────────────────────────────────
echo "=== t4 도달 실패 — 「놓침」과 구분해야 한다"
R="$W/nodata"; mkres "$R"
put "$R/d1.json" '{"findings":[{"file":"x.tsx","line":1,"severity":"major","summary":"정의가 없다"}]}'
out=$(python3 "$SELF/_score.py" "$CASES" "$R" nodata 2>&1)
chk "미측정을 따로 세어 알린다"        "$out" '미측정 3건' yes
chk "미측정은 재현율 분모에서 빠진다"   "$out" '위치 재현율 1/1 = 100%' yes

# ── t5 위치는 맞고 사유는 못 짚음 ───────────────────────────────────────────
echo "=== t5 옳은 줄을 엉뚱한 이유로 지적 — 「적중」으로 묻히면 안 된다"
R="$W/loconly"; mkres "$R"
put "$R/d1.json" '{"findings":[{"file":"x.tsx","line":1,"severity":"major","summary":"변수명이 짧다"}]}'
put "$R/d2.json" '{"findings":[{"file":"s.go","line":1,"severity":"major","summary":"순서가 뒤집혔다"}]}'
put "$R/c1.json" '{"findings":[]}'; put "$R/c2.json" '{"findings":[]}'
out=$(python3 "$SELF/_score.py" "$CASES" "$R" loconly 2>&1)
chk "「위치만」으로 따로 센다"          "$out" '위치만 ' yes
chk "사유까지 맞은 것은 1건"           "$out" '사유까지 1' yes

# ── t6 nit 은 대조군에서 오탐이 아니다 ──────────────────────────────────────
echo "=== t6 대조군에서 nit — 오탐으로 세면 리뷰어가 진짜 결함도 nit 으로 낮춘다"
R="$W/nit"; mkres "$R"
put "$R/d1.json" '{"findings":[]}'; put "$R/d2.json" '{"findings":[]}'
put "$R/c1.json" '{"findings":[{"file":"ok.go","line":1,"severity":"nit","summary":"주석 오타"}]}'
put "$R/c2.json" '{"findings":[]}'
out=$(python3 "$SELF/_score.py" "$CASES" "$R" nit 2>&1)
chk "nit 만이면 오탐이 아니다"          "$out" '오탐률 0/2 = 0%' yes

# ── t7 파일은 맞는데 줄이 멀다 ──────────────────────────────────────────────
echo "=== t7 같은 파일 먼 줄 — tolerance 밖이면 놓침"
R="$W/farline"; mkres "$R"
put "$R/d1.json" '{"findings":[{"file":"x.tsx","line":400,"severity":"major","summary":"정의가 없다"}]}'
put "$R/d2.json" '{"findings":[]}'; put "$R/c1.json" '{"findings":[]}'; put "$R/c2.json" '{"findings":[]}'
out=$(python3 "$SELF/_score.py" "$CASES" "$R" farline 2>&1)
chk "놓침으로 센다"                    "$out" '놓침 2' yes

# ── t8 ⭐ 사보타주 — 대조군을 빼면 「전부 결함」 리뷰어가 만점이 된다 ────────
echo "=== t8 ⭐ 사보타주 — 케이스에서 대조군을 빼면 무엇이 보이지 않게 되나"
ONLYD="$W/onlydefect.jsonl"; grep -v '"defect":false' "$CASES" > "$ONLYD"
out=$(python3 "$SELF/_score.py" "$ONLYD" "$W/paranoid" paranoid 2>&1)
chk "「전부 결함」 리뷰어가 재현율 만점을 받는다" "$out" '위치 재현율 2/2 = 100%' yes
chk "⭐ 그때 도구가 「근거가 될 수 없다」고 말한다" "$out" '대조군이 0건이다' yes
chk "오탐률이 아예 안 나온다(못 재는 것을 안 재는 것)" "$out" '오탐률' no

# ── t9 케이스 파일 검증 — 형식이 틀리면 아무것도 펼치지 않는다 ──────────────
echo "=== t9 케이스 검증 — 잘못된 케이스로 평가를 시작하지 않는다"
BAD="$W/bad.jsonl"
printf '%s\n' '{"id":"b1","class":"x","lang":"go","defect":true,"diff":"--- a/x\n+++ b/x\n@@ -1 +1 @@\n+a\n"}' > "$BAD"
out=$(python3 "$SELF/_prepare.py" "$BAD" "$W/badout" 2>&1)
chk "defect:true 인데 정답이 없으면 거부" "$out" 'expect.file 이 없다' yes
chk "그때 아무것도 펼치지 않는다"          "$out" '아무것도 펼치지 않았다' yes
BAD2="$W/bad2.jsonl"
printf '%s\n' '{"id":"b2","class":"대조군","lang":"go","defect":false,"diff":"--- a/x\n+++ b/x\n@@ -1 +1 @@\n+a\n","expect":{"file":"x"}}' > "$BAD2"
out=$(python3 "$SELF/_prepare.py" "$BAD2" "$W/badout" 2>&1)
chk "대조군에 정답이 있으면 거부"          "$out" '대조군인데 expect 가 있다' yes
DUP="$W/dup.jsonl"; cat "$CASES" "$CASES" > "$DUP"
out=$(python3 "$SELF/_prepare.py" "$DUP" "$W/badout" 2>&1)
chk "id 중복을 잡는다(라운드 간 비교가 깨진다)" "$out" 'id 중복' yes

# ── t10 ⭐ 정답이 프롬프트로 새지 않는다 ────────────────────────────────────
echo "=== t10 ⭐ 오픈북 방지 — 프롬프트에 정답이 없어야 한다"
LEAK="$W/leak.jsonl"
printf '%s\n' '{"id":"L1","class":"팬텀 심볼","lang":"tsx","defect":true,"why":"정답문자열이다ZZTOP","origin":"진행로그 2026-08-12","diff":"--- a/x.tsx\n+++ b/x.tsx\n@@ -1 +1,2 @@\n+const c = 1;\n","expect":{"file":"x.tsx","any_of":["비밀키워드YYTOP"]}}' > "$LEAK"
python3 "$SELF/_prepare.py" "$LEAK" "$W/leakout" >/dev/null 2>&1
blob=$(cat "$W/leakout"/*.prompt.txt)
chk "why(정답)가 새지 않는다"        "$blob" 'ZZTOP' no
chk "any_of(채점 키워드)가 새지 않는다" "$blob" 'YYTOP' no
chk "부류명도 새지 않는다"            "$blob" '팬텀' no
chk "diff 는 들어간다"               "$blob" 'const c = 1' yes
chk "⭐ 「결함이 없을 수도 있다」를 말한다(대조군이 성립하려면 필수)" "$blob" '결함이 없을 수도 있다' yes

rm -rf "$W"
echo
echo
echo "=== ⭐⭐ 배포되는 케이스 파일이 실제로 펼쳐지는가 (2026-09-03 리뷰가 잡은 blocker)"
# ⚠ 여기까지의 케이스는 전부 **인라인 임시 파일**이다 — 그래서 `cases/*.jsonl` 이 깨져도
#   이 스위트는 초록이었다. 실제로 대조군에 `expect` 를 달아 `_prepare.py` 가 파일 전체를
#   거부하는 상태가 게이트를 통과했다. 「초록은 돌았다가 아니라 실패하지 않았다」의 실례다.
for cf in "$SELF/cases"/*.jsonl; do
  [ -f "$cf" ] || continue
  od=$(mktemp -d)
  out=$(python3 "$SELF/_prepare.py" "$cf" "$od" 2>&1); rc=$?
  n=$(ls "$od"/*.txt 2>/dev/null | wc -l | tr -d ' ')
  if [ "$rc" -eq 0 ] && [ "${n:-0}" -gt 0 ]; then
    echo "  ok   배포 케이스 $(basename "$cf") — ${n}건 펼침"; pass=$((pass+1))
  else
    echo "  FAIL 배포 케이스 $(basename "$cf") 가 펼쳐지지 않는다 (rc=$rc)"; echo "$out" | tail -3; fail=$((fail+1))
  fi
  rm -rf "$od"
done

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
