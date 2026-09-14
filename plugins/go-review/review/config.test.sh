#!/usr/bin/env bash
# config.test.sh — 리뷰 구성 해석의 대조군.
#
# ⭐ 이 스위트가 지키는 것 둘:
#   ① **프리셋이 실제로 다른 배치를 낸다** — 전부 같은 답이면 그 설정은 장식이다
#      (「어떤 신호로 판정하기 전에 그 신호가 반대 경우에 달라지는지 먼저 쳐 봐라」).
#   ② **위험한 구성에는 경고가 붙는다** — 병합자를 codex 로 두거나 자리가 1개일 때.
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
pass=0; fail=0
chk() { if printf '%s' "$2" | grep -q -- "$3"; then g=yes; else g=no; fi
  if [ "$g" = "$4" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1 → got=$g want=$4 ($3)"; fail=$((fail+1)); fi; }

W=$(mktemp -d)
cfg() { printf '%s' "$1" > "$W/c.json"; python3 "$SELF/_config.py" "$W/c.json" 2>&1; }

echo "=== ① 프리셋이 실제로 다른 배치를 낸다"
p1=$(cfg '{"preset":"P1"}')
chk "P1 — 계약·무편향이 claude"     "$p1" 'contract  claude' yes
chk "P1 — 교차 자리에 codex"        "$p1" 'cross     codex' yes
p2=$(cfg '{"preset":"P2"}')
chk "P2 — 계약이 codex"             "$p2" 'contract  codex' yes
chk "P2 — 교차 자리는 비운다"       "$p2" 'cross     —' yes
chk "⭐ P2 — 병합자도 codex(2026-09-02 결정)" "$p2" 'merger    codex' yes
chk "P1 — 병합자는 claude"           "$p1" 'merger    claude' yes
chk "⭐ P1 과 P2 가 다른 답을 낸다"  "$(printf '%s\n%s' "$p1" "$p2" | sort -u | wc -l)" '^ *[2-9]' yes
p3=$(cfg '{"preset":"P3"}')
chk "P3 — 계약 자리도 비운다"       "$p3" 'contract  —' yes

echo "=== ⭐ _dedup 에 넘길 이름이 배치를 따라간다"
chk "P1 → claude-contract,claude-blind,codex" "$p1" 'REVIEWERS=claude-contract,claude-blind,codex' yes
chk "P2 → codex-contract,codex-blind"         "$p2" 'REVIEWERS=codex-contract,codex-blind' yes

echo "=== ② 위험한 구성에는 경고가 붙는다"
chk "P2 는 「사슬이 전부 codex」 경고"  "$p2" '리뷰 사슬이 전부 \*\*codex\*\*' yes
chk "P1 은 그 경고가 없다(계열이 둘)"   "$p1" '리뷰 사슬이 전부' no
chk "⭐ P2 는 되돌릴 자리를 말한다"     "$p2" 'preset 을 \*\*P2c\*\*' yes
chk "⭐⭐ P2 는 사람 판정을 안전장치로 지목" "$p2" 'verdict.sh' yes
chk "P3 는 「교차검증이 성립하지 않는다」" "$p3" '교차검증이 성립하지 않는다' yes
chk "P2 는 자리가 둘이라 그 경고 없음"  "$p2" '교차검증이 성립하지 않는다' no
# ⭐ 반대 방향 — 리뷰어는 codex 인데 병합자만 claude(P2c)면 **다른** 경고가 붙는다
p2c=$(cfg '{"preset":"P2c"}')
chk "P2c — 병합자만 claude"             "$p2c" 'merger    claude' yes
chk "P2c 는 사슬 단일 경고가 없다"       "$p2c" '리뷰 사슬이 전부' no
chk "P2c 는 「병합 비용이 늘 수 있다」"   "$p2c" '병합 비용이 늘 수 있다' yes
chk "P2 는 그 경고가 없다(병합도 codex)"  "$p2"  '병합 비용이 늘 수 있다' no
# ⚠ 전 자리가 claude 면 자기 리뷰에 가까워진다 — 그 방향도 경고한다
al=$(cfg '{"preset":"custom","seats":{"contract":"claude","blind":"claude","cross":"none","merger":"claude"}}')
chk "전 자리 claude 면 자기 리뷰 경고"    "$al" '자기 리뷰에 가까워진다' yes
chk "P2 에는 그 경고가 없다"             "$p2" '자기 리뷰에 가까워진다' no

echo "=== ⚠ 모르는 값·깨진 파일은 조용히 틀리지 않는다"
bad=$(cfg '{"preset":"P9"}')
chk "모르는 preset → P1 로 진행하고 그렇게 말한다" "$bad" '모르는 preset' yes
printf '%s' '{ 깨진' > "$W/c.json"
brk=$(python3 "$SELF/_config.py" "$W/c.json" 2>&1)
chk "파싱 실패 → 기본으로 진행하고 알린다" "$brk" '파싱 실패' yes
mis=$(python3 "$SELF/_config.py" "$W/없는것.json" 2>&1)
chk "파일 부재 → 기본(P1)"                 "$mis" 'preset \*\*P1\*\*' yes

echo "=== 모델 노브가 출력에 반영된다"
mm=$(cfg '{"preset":"P2","models":{"codex":"gpt-5-codex"}}')
chk "codex 모델이 표시된다"  "$mm" '· 모델 gpt-5-codex' yes
chk "빈 값이면 표시하지 않는다" "$p2" '· 모델 ' no

echo "=== ⭐ 사보타주 — 프리셋 표를 하나로 만들면"
sed 's/"P2": {"contract": "codex",  "blind": "codex",  "cross": "none",  "merger": "codex"}/"P2": {"contract": "claude", "blind": "claude", "cross": "codex", "merger": "claude"}/' \
    "$SELF/_config.py" > "$W/sab.py"
sab=$(printf '%s' '{"preset":"P2"}' > "$W/c.json"; python3 "$W/sab.py" "$W/c.json" 2>&1)
if printf '%s' "$sab" | grep -q 'contract  codex'; then
  echo "  FAIL 사보타주가 발화하지 않았다 — 프리셋이 배치를 정하지 않는다는 뜻이다"; fail=$((fail+1))
else
  echo "  ok   ⭐ 사보타주하면 P2 가 P1 과 같아진다(프리셋이 실제로 배치를 정한다)"; pass=$((pass+1))
fi

echo "=== ⑤ 구성 파일을 **어디서** 읽는가 — 인자 > 프로젝트 > 플러그인 기본"
# ⭐ 플러그인으로 배포되면 정본이 둘이 될 수 있는 자리다. 우선순위가 주석이 아니라
#   실제 동작이라는 것을 여기서 증명한다(대조군 없는 보호는 근거가 아니다).
J=$(mktemp -d); mkdir -p "$J/.claude/review"
printf '%s' '{"preset":"P1"}' > "$J/.claude/review/config.json"   # 프로젝트는 P1

a=$(printf '%s' '{"preset":"P3"}' > "$W/c.json"; CLAUDE_PROJECT_DIR="$J" python3 "$SELF/_config.py" "$W/c.json" 2>&1)
chk "인자가 프로젝트를 이긴다(출처=인자)"        "$a" '구성 파일 — 인자' yes
chk "인자가 프로젝트를 이긴다(P3 이 적용됐다)"   "$a" 'contract  —' yes

b=$(CLAUDE_PROJECT_DIR="$J" python3 "$SELF/_config.py" 2>&1)
chk "인자가 없으면 프로젝트(출처=프로젝트)"      "$b" '구성 파일 — 프로젝트' yes
chk "⭐ 프로젝트의 P1 이 실제로 적용된다"        "$b" 'contract  claude' yes
chk "프로젝트가 있으면 복사 안내는 안 뜬다"      "$b" '복사해 고쳐라' no

E=$(mktemp -d)   # .claude/review/config.json 이 없는 프로젝트
c=$(CLAUDE_PROJECT_DIR="$E" python3 "$SELF/_config.py" 2>&1)
chk "프로젝트 파일이 없으면 플러그인 기본"       "$c" '구성 파일 — 플러그인 기본' yes
chk "⭐ 그때는 어디에 두라고 말해 준다"          "$c" '복사해 고쳐라' yes
chk "⭐⭐ 기본은 플러그인의 config.default.json" "$c" 'config.default.json' yes

# ⭐ 대조군 — 프로젝트 것과 기본이 **다른 답**을 내는가. 같으면 위 통과는 우연이다.
if [ "$(printf '%s' "$b" | grep -c 'contract  claude')" -ge 1 ] &&    [ "$(printf '%s' "$c" | grep -c 'contract  codex')" -ge 1 ]; then
  echo "  ok   ⭐ 프로젝트(P1)와 기본(P2)이 서로 다른 배치를 낸다 — 우선순위가 관측된다"; pass=$((pass+1))
else
  echo "  FAIL 두 출처가 같은 답이다 — 이 스위트는 우선순위를 재지 못한다"; fail=$((fail+1))
fi
rm -rf "$J" "$E"

# ══ codex 부재 폴백 (2026-09-07 · P6-3) ══════════════════════════════════════
#
# ⛔ 종전에는 「codex 가 없으면 P1 으로 내려라」가 **지시문 한 줄**(review-loop.md)이었다.
#   그것은 규율이고, 빠뜨리면 기본 preset(P2)의 전 자리가 codex 라 **리뷰가 0회**가 된다 —
#   fail-open 방향이라 스크립트로 옮겼다. 이 절이 그 이전이 실제로 막히는지 잰다.
K=$(mktemp -d); mkdir -p "$K/.claude/review"
printf '%s' '{"preset":"P2"}' > "$K/.claude/review/config.json"

d=$(CLAUDE_REVIEW_FORCE_NO_CODEX=1 CLAUDE_PROJECT_DIR="$K" python3 "$SELF/_config.py" 2>&1)
chk "codex 부재면 preset 을 P1 로 내린다"        "$d" 'preset \*\*P1\*\*' yes
chk "⭐ 왜 내렸는지 말한다(조용히 바꾸지 않는다)" "$d" 'codex 를 찾지 못해' yes
# ⚠ 「codex」라는 낱말은 안내 문구에도 나온다(「codex 를 찾지 못해」·「설치하라」) —
#   **자리 표의 행**만 봐야 한다. 첫 판이 그것을 안 좁혀서 붉었다(탐지기가 너무 넓었다).
chk "⭐⭐ 자리 표에 codex 가 **남지 않는다**"     "$d" '^  \(contract\|blind\|cross\) *codex' no
chk "교차 검증층이 없다는 사실을 적는다"          "$d" '교차 모델 검증층이 이 라운드에는' yes
chk "할 수 없는 일을 시키지 않는다"               "$d" '교차 자리에 codex 를 앉히는 것을 고려' no
chk "리뷰어 이름이 claude 로 나간다"              "$d" 'CLAUDE_REVIEW_REVIEWERS=claude-contract,claude-blind' yes

# ⭐ 대조군 — codex 가 있으면 **내리지 않는다**(항상 내리는 구현이면 P2 를 쓸 수 없다).
e=$(CLAUDE_PROJECT_DIR="$K" python3 "$SELF/_config.py" 2>&1)
if command -v codex >/dev/null 2>&1; then
  chk "⭐ 대조군 — codex 가 있으면 P2 가 그대로다" "$e" 'preset \*\*P2\*\*' yes
  chk "⭐ 대조군 — 그때는 강등 문구가 없다"        "$e" 'codex 를 찾지 못해' no
else
  echo "  skip ⭐ 대조군(codex 설치 환경에서만) — 이 기계에는 codex 가 없다"
fi
rm -rf "$K"

# ══ 모델 export (2026-09-09) ═════════════════════════════════════════════════
#
# ⭐ `models.codex` 에 적은 슬러그가 **호출까지 닿는지**를 잰다. 종전에는 자리 설명 뒤에
#   「· 모델 X」라고 산문으로만 붙었고, 실제로 `-m` 을 붙이는 것은 실행자의 규율이었다 —
#   빠뜨리면 config 에 적은 모델이 조용히 무시된다(「정본이 있는데 아무도 안 쓴다」 부류).
M=$(mktemp -d); mkdir -p "$M/.claude/review"
printf '%s' '{"preset":"P1","models":{"claude":"","codex":"gpt-5.6-sol"}}' > "$M/.claude/review/config.json"
# ⚠ 변수 이름에 주의 — `chk()` 는 판정을 전역 `g` 에 담는다. 출력 변수를 `g`·`b` 같은
#   짧은 이름으로 두면 **두 번째 검사부터 오염된 값을 읽는다**(첫 판이 실제로 그래서 붉었다).
mdl_set=$(CLAUDE_PROJECT_DIR="$M" python3 "$SELF/_config.py" 2>&1)
chk "codex 모델을 export 형태로 내보낸다"        "$mdl_set" 'CLAUDE_REVIEW_CODEX_MODEL=gpt-5.6-sol' yes
chk "⭐ 자리 표에도 그 모델이 보인다"             "$mdl_set" '모델 gpt-5.6-sol' yes
chk "claude 모델은 비었으므로 줄이 없다"          "$mdl_set" 'CLAUDE_REVIEW_CLAUDE_MODEL=' no

# ⭐ 대조군 — 비워 두면 **줄 자체가 없어야** 한다. 빈 export 를 내보내면 호출 블록의
#   `${VAR:+-m $VAR}` 가 의미를 잃고, 「기본을 쓴다」와 「빈 모델을 지정했다」가 섞인다.
printf '%s' '{"preset":"P1","models":{"claude":"","codex":""}}' > "$M/.claude/review/config.json"
mdl_empty=$(CLAUDE_PROJECT_DIR="$M" python3 "$SELF/_config.py" 2>&1)
chk "⭐ 대조군 — 비우면 codex 모델 줄이 없다"     "$mdl_empty" 'CLAUDE_REVIEW_CODEX_MODEL=' no
chk "⭐ 대조군 — 그때도 자리 배치는 그대로다"     "$mdl_empty" 'cross     codex' yes

# ⭐⭐ 대조군 — claude 쪽도 같은 규칙인가(한쪽만 구현하면 다음 사람이 헛짚는다).
printf '%s' '{"preset":"P1","models":{"claude":"opus","codex":""}}' > "$M/.claude/review/config.json"
mdl_claude=$(CLAUDE_PROJECT_DIR="$M" python3 "$SELF/_config.py" 2>&1)
chk "⭐⭐ claude 모델도 같은 방식으로 나간다"      "$mdl_claude" 'CLAUDE_REVIEW_CLAUDE_MODEL=opus' yes
rm -rf "$M"

# ⭐⭐⭐ 지시문 축 — 호출 블록이 그 변수를 **실제로 읽는가.** 여기가 비면 위 검사 전부가
#   「내보내기는 했는데 아무도 안 받는다」를 통과시킨다(이 레포가 반복해서 밟은 자리다).
RL="$SELF/../commands/review-loop.md"
if [ -f "$RL" ]; then
  # ⚠ 산문 속 설명(`${CLAUDE_REVIEW_CODEX_MODEL:+-m …}` 처럼 값을 생략한 인용)도 이 패턴에
  #   걸린다 — 첫 판이 그것을 세어 「호출 2곳인데 3곳이 넘긴다」는 모순을 냈다.
  #   실제로 인자를 만드는 것은 **변수를 치환하는 형태**뿐이므로 거기까지 좁힌다.
  n=$(grep -c 'CLAUDE_REVIEW_CODEX_MODEL:+-m \$CLAUDE_REVIEW_CODEX_MODEL' "$RL")
  if [ "$n" -ge 2 ]; then
    echo "  ok   ⭐⭐⭐ review-loop.md 의 codex 호출 $n 곳이 그 변수를 -m 으로 넘긴다"; pass=$((pass+1))
  else
    echo "  FAIL review-loop.md 에서 -m 을 넘기는 자리가 $n 곳이다(리뷰어·병합자 둘 다여야 한다)"; fail=$((fail+1))
  fi
  # ⭐ 대조군 — codex 를 부르는 자리 수와 맞는가. 호출이 늘었는데 -m 이 안 늘면 잡아야 한다.
  c1=$(grep -c 'codex-ro.sh' "$RL")
  if [ "$n" -eq "$c1" ]; then
    echo "  ok   ⭐ 대조군 — codex 호출 $c1 곳 전부가 모델 변수를 넘긴다"; pass=$((pass+1))
  else
    echo "  FAIL codex 호출 $c1 곳 중 $n 곳만 모델 변수를 넘긴다 — 빠진 자리가 있다"; fail=$((fail+1))
  fi
else
  echo "  skip 지시문 축(review-loop.md 를 찾지 못했다)"
fi

rm -rf "$W"
echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
