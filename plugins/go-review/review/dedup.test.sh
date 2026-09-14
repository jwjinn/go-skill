#!/usr/bin/env bash
# dedup.test.sh — 결정론적 중복 제거의 대조군.
#
# ⭐ 이 스위트가 지키는 것 둘:
#   ① **서로 다른 결함을 합치지 않는다** — 합치면 그중 하나가 조용히 사라진다(중복보다 나쁘다)
#   ② **같은 결함을 어휘가 다르다고 나누지 않는다** — 다른 어휘로 말하는 것이
#      다른 모델을 쓰는 이유다. 라운드 1 실측이 이것을 잡았다(g2/g15·g6/g18).
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
pass=0; fail=0
chk() { if printf '%s' "$2" | grep -q -- "$3"; then g=yes; else g=no; fi
  if [ "$g" = "$4" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1 → got=$g want=$4 ($3)"; fail=$((fail+1)); fi; }

W=$(mktemp -d)
mk() { printf '%s' "$2" > "$W/$1.json"; }
run() { python3 "$SELF/_dedup.py" "$W" "$W/out.json" 2>&1; }

echo "=== 같은 줄 · 다른 리뷰어 · 다른 어휘 → 합친다"
mk claude-contract '{"findings":[{"file":"a.md","line":104,"severity":"major","summary":"경계문이 diff 읽기와 정면 충돌한다"}]}'
mk claude-blind    '{"findings":[]}'
mk codex           '{"findings":[{"file":"a.md","line":104,"severity":"major","summary":"읽으라고 주는 파일이 읽지 말라는 곳에 있다"}]}'
out=$(run)
chk "어휘가 안 겹쳐도 같은 줄이면 합친다" "$out" '원 발견 2 → 후보 1' yes
chk "합의로 잡힌다"                      "$out" '단독 0 · 합의 1' yes

echo "=== ⭐ 사보타주 — 같은 줄 규칙을 지우면"
sab=$(python3 - "$SELF/_dedup.py" "$W" <<'P'
import io,sys
s=io.open(sys.argv[1],encoding="utf-8").read()
s=s.replace('if d != 0 and jaccard','if jaccard')
open("/tmp/_dd_sab.py","w").write(s)
P
python3 /tmp/_dd_sab.py "$W" "$W/sab.json" 2>&1)
chk "사보타주하면 같은 결함이 둘로 갈린다(대조군 발화)" "$sab" '원 발견 2 → 후보 2' yes
rm -f /tmp/_dd_sab.py

echo "=== ⚠ 서로 다른 결함은 합치지 않는다"
mk claude-contract '{"findings":[{"file":"h.sh","line":67,"severity":"major","summary":"세션 스코프 분기가 도달 불가능하다"}]}'
mk claude-blind    '{"findings":[{"file":"h.sh","line":77,"severity":"major","summary":"GNU 폴백이 실행되지 않는다"}]}'
mk codex           '{"findings":[]}'
out=$(run)
chk "줄이 10 떨어지면 안 합친다"        "$out" '원 발견 2 → 후보 2' yes
chk "그래도 「같을 수 있다」고 알린다"    "$out" '같을 수 있으나 합치지 않은 짝' yes

echo "=== ⚠ 같은 리뷰어의 두 발견은 합치지 않는다"
mk claude-contract '{"findings":[]}'
mk claude-blind    '{"findings":[{"file":"g.sh","line":171,"severity":"major","summary":"경고 축이 존재만 본다"},{"file":"g.sh","line":174,"severity":"major","summary":"경고 축이 존재만 본다"}]}'
mk codex           '{"findings":[]}'
out=$(run)
chk "줄이 3 안이고 어휘가 같아도 같은 리뷰어면 따로" "$out" '원 발견 2 → 후보 2' yes

echo "=== ⭐ 확인 대상 선정 — 단독은 항상, 합의는 blocker 만"
mk claude-contract '{"findings":[{"file":"x.go","line":10,"severity":"minor","summary":"합의된 사소한 것"},{"file":"y.go","line":20,"severity":"blocker","summary":"합의된 치명"}]}'
mk claude-blind    '{"findings":[{"file":"x.go","line":10,"severity":"minor","summary":"합의된 사소한 것"},{"file":"y.go","line":20,"severity":"blocker","summary":"합의된 치명"},{"file":"z.go","line":30,"severity":"minor","summary":"혼자 본 것"}]}'
mk codex           '{"findings":[]}'
out=$(run)
chk "3그룹"                              "$out" '후보 3' yes
chk "확인 필요는 2 (단독1 + 합의blocker1)" "$out" '확인 필요 2/3' yes
j=$(python3 -c "
import json,io
d=json.load(io.open('$W/out.json',encoding='utf-8'))
for c in d['candidates']: print(c['file'],c['needs_verify'],c['verify_reason'])
")
chk "합의된 minor 는 건너뛴다"            "$j" 'x.go False' yes
chk "⭐ 합의여도 blocker 는 확인한다"      "$j" 'y.go True blocker' yes
chk "단독은 사유가 「단독 발견」"          "$j" 'z.go True 단독 발견' yes

echo "=== ⭐ 자리 구성을 바꿔도 집계에 들어온다 (codex 두 자리 = P2 프리셋)"
rm -f "$W"/claude-*.json "$W"/codex.json
mk codex-contract '{"findings":[{"file":"p.go","line":7,"severity":"major","summary":"계약 자리에서 찾은 것"}]}'
mk codex-blind    '{"findings":[{"file":"p.go","line":7,"severity":"major","summary":"무편향 자리에서 찾은 것"}]}'
out=$(run)
chk "codex 두 자리가 둘 다 읽힌다"        "$out" '원 발견 2' yes
chk "같은 줄이라 합의로 묶인다"           "$out" '단독 0 · 합의 1' yes

echo "=== ⚠⚠ 목록에 없는 이름은 조용히 무시된다 — env 로 덧붙일 수 있어야 한다"
rm -f "$W"/codex-*.json
mk gemini-blind '{"findings":[{"file":"q.go","line":3,"severity":"major","summary":"모르는 리뷰어"}]}'
out=$(run)
chk "목록에 없으면 안 잡힌다(이 상수가 탐지기다)" "$out" '리뷰어 산출이 없다' yes
out=$(CLAUDE_REVIEW_REVIEWERS=gemini-blind run)
chk "env 로 덧붙이면 잡힌다"                      "$out" '원 발견 1' yes
rm -f "$W"/gemini-blind.json
mk claude-contract '{"findings":[]}'
mk claude-blind    '{"findings":[]}'
mk codex           '{"findings":[]}'

echo "=== ⚠ 도달 실패(.err 는 있고 .json 은 없다)만 알린다"
mk claude-contract '{"findings":[{"file":"x.go","line":10,"severity":"major","summary":"뭔가"}]}'
rm -f "$W/codex.json"; : > "$W/codex.err"     # 시도했으나 산출 없음
out=$(run)
chk "도달 실패를 이름으로 알린다"          "$out" '도달 실패 codex' yes
chk "⭐ 설정하지 않은 자리는 세지 않는다(codex-blind 등)" "$out" 'codex-blind' no
chk "몇 자리가 산출을 냈는지 말한다"        "$out" '자리 [0-9]*개가 산출을 냈다' yes

echo "=== ⚠⚠ 자리가 하나면 교차검증이 성립하지 않는다고 말한다"
rm -f "$W"/claude-blind.json "$W"/codex.err
out=$(run)
chk "교차검증 불가를 알린다"                "$out" '교차검증이 성립하지 않는다' yes

# ─────────────────────────────────────────────────────────────────────────────
echo "=== ⛔ line 0 은 「모른다」다 — 가짜 합의를 만들지 않는가 (2026-09-02 실측 결함)"
# ⭐ 왜 이 절이 생겼나: `isinstance(0, int)` 이 참이라 줄을 **모르는** 발견 둘이 `d == 0`
#    (같은 줄)으로 읽혀 「같은 줄이면 어휘 겹침을 요구하지 않는다」 규칙에 걸렸다.
#    → 전혀 무관한 발견이 한 그룹이 되고 `raised_by` 가 둘이 되어 **합의로 보인다.**
#    non-blocker 면 needs_verify:false 라 **병합자가 코드를 열지 않는다** — 유실보다 나쁘다.
# ⚠ ③④(반대 방향)가 이 절의 핵이다. 없으면 「아무것도 병합하지 않는」 구현이 ①②를 통과한다.
# ⚠ run() 은 $W/out.json 에 쓴다 — candidates.json 이 아니다(엉뚱한 산출물을 읽으면
#   「그룹 0」이 나오고 그것이 결함처럼 보인다).
ngroups() { python3 -c "
import io,json,sys
print(len(json.load(io.open(sys.argv[1],encoding='utf-8'))['candidates']))" "$1"; }
two() { printf '%s' "{\"findings\":[{\"file\":\"a/b.go\",\"line\":$1,\"severity\":\"$2\",\"summary\":\"$3\"}]}"; }
cs() { rm -f "$W"/*.json "$W"/*.err
  mk claude-contract "$(two "$1" major "$2")"; mk claude-blind "$(two "$1" minor "$3")"
  run >/dev/null 2>&1; ngroups "$W/out.json"; }

g=$(cs 0 "쿼터 계산이 음수를 허용한다" "로그 문구에 오타가 있다")
chk "① 줄 모름(0) + 무관한 어휘 → 별개 2그룹" "$g" '^2$' yes
g=$(cs null "쿼터 계산이 음수를 허용한다" "로그 문구에 오타가 있다")
chk "② 줄 모름(null) → 별개 2그룹(회귀 없음)" "$g" '^2$' yes
g=$(cs 42 "쿼터 계산이 음수를 허용한다" "로그 문구에 오타가 있다")
chk "⭐③ 진짜 같은 줄(42)은 어휘 안 겹쳐도 1그룹(규칙 보존)" "$g" '^1$' yes
g=$(cs 0 "쿼터 계산이 음수를 허용한다" "쿼터 계산이 음수를 허용해서 위험하다")
chk "⭐④ 줄 모름인데 어휘가 겹치면 1그룹" "$g" '^1$' yes

echo "=== ⭐⭐ 사보타주 — dline 이 0 을 다시 줄로 읽으면"
sed 's/    return isinstance(x, int) and not isinstance(x, bool) and x > 0/    return isinstance(x, int)/' \
    "$SELF/_dedup.py" > "$W/sab_dedup.py"
rm -f "$W"/*.json "$W"/*.err
mk claude-contract "$(two 0 major "쿼터 계산이 음수를 허용한다")"
mk claude-blind    "$(two 0 minor "로그 문구에 오타가 있다")"
python3 "$W/sab_dedup.py" "$W" "$W/out-sab.json" >/dev/null 2>&1
sg=$(ngroups "$W/out-sab.json")
if [ "$sg" = "1" ]; then
  echo "  ok   ⭐⭐ 되돌리면 무관한 발견 둘이 1그룹이 된다(결함 재현)"; pass=$((pass+1))
else
  echo "  FAIL 사보타주가 발화하지 않았다(그룹 $sg) — 이 검사가 무엇도 지키지 않는다는 뜻이다"
  fail=$((fail+1))
fi

rm -rf "$W"
echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
