#!/usr/bin/env bash
# measure.test.sh — 측정 도구가 **자기 목록이 낡아 조용히 비는 것**을 막는가.
#
# ⭐ 이 스위트가 생긴 이유(2026-09-02):
#   `_measure.py` 가 리뷰어 이름을 하드코딩("claude-contract","claude-blind","codex")했는데
#   기본 preset 이 P2 로 바뀌며 실제 자리가 codex-contract·codex-blind 가 됐다.
#   그러자 `stat()` 의 `if not sel: return` 이 **조용히** 빠져나가 리뷰어별·1인 기준선·절제·
#   비용 표가 전부 비었다 — 「누가 값을 했나」를 재는 도구가 아무 말도 안 했다.
#   병합자가 그 축을 coverage_gap 으로 짚어서 발견했고, 그때까지 어떤 테스트도 안 잡았다.
#
# ⚠ 그래서 이 스위트의 본체는 **빈 표를 실패로 만드는 것**이다. 값이 맞는지보다
#   「나오기는 하는가」가 먼저다("0 이 나오면 탐지기부터 의심하라"의 이 파일 판).
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
pass=0; fail=0
chk() { if printf '%s' "$2" | grep -q -- "$3"; then g=yes; else g=no; fi
  if [ "$g" = "$4" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1 → got=$g want=$4 ($3)"; fail=$((fail+1)); fi; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# ── 재료: P2 자리(codex-contract·codex-blind)로만 기록된 라운드 ────────────────
#    ⭐ 고치기 전이라면 이 입력에서 모든 리뷰어 표가 비었다.
cat > "$W/rounds.jsonl" <<'EOF'
{"round":"r1","date":"2026-09-01","must_fix":2,"consider":1,"rejected":3,"pre_existing":0,"must_fix_by":[["codex-contract"],["codex-contract","codex-blind"]],"tokens":{"codex-contract":50000,"codex-blind":40000,"review-merger":120000},"diff_lines":800}
{"round":"r2","date":"2026-09-02","must_fix":1,"consider":0,"rejected":2,"pre_existing":0,"must_fix_by":[["codex-blind"]],"tokens":{"codex-contract":30000,"codex-blind":35000,"review-merger":90000},"diff_lines":400}
EOF
cat > "$W/findings.jsonl" <<'EOF'
{"round":"r1","fid":"r1#must_fix-0","bucket":"must_fix","raised_by":["codex-contract"],"human":"accepted","sig":"a1"}
{"round":"r1","fid":"r1#must_fix-1","bucket":"must_fix","raised_by":["codex-contract","codex-blind"],"human":"rejected","sig":"a2"}
{"round":"r1","fid":"r1#consider-0","bucket":"consider","raised_by":["codex-blind"],"human":"deferred","sig":"a3"}
{"round":"r2","fid":"r2#must_fix-0","bucket":"must_fix","raised_by":["codex-blind"],"human":"accepted","sig":"a4"}
EOF
out=$(python3 "$SELF/_measure.py" "$W/rounds.jsonl" 2>&1)

echo "=== ⭐ ① P2 자리에서도 표가 채워진다 (이것이 고친 결함이다)"
chk "자리 줄에 cx-contract 가 뜬다"      "$out" 'cx-contract' yes
chk "자리 줄에 cx-blind 가 뜬다"         "$out" 'cx-blind' yes
chk "⭐ 리뷰어별 고유 기여가 비지 않는다"  "$out" 'codex-contract *고유' yes
chk "절제 조합표에 cx-contract 가 나온다"  "$out" '^  cx-contract  *[0-9]' yes
chk "⭐ 정밀도 절의 리뷰어별 행이 나온다"  "$out" 'cx-contract *올림' yes
chk "비용표에 codex-contract 행이 있다"   "$out" 'codex-contract  *50,000\|codex-contract  *80,000' yes
chk "옛 이름은 표에 나오지 않는다"        "$out" 'claude-contract' no

echo "=== ② 값이 맞는가 (표가 나오기만 하면 되는 게 아니다)"
chk "고유 기여: cx-contract 1건"  "$out" 'codex-contract *고유 1건' yes
chk "확증(겹침): cx-contract 1건" "$out" 'codex-contract *고유 1건 · 확증(겹침) 1건' yes
chk "고유 기여: cx-blind 1건"     "$out" 'codex-blind *고유 1건' yes
chk "표본 2라운드는 판단 금지"     "$out" '결론을 내리지 마라' yes

echo "=== ⛔ ②-b must_fix 0 인 라운드 — findings.jsonl 에만 자리 이름이 있다 (체인 실측)"
# ⚠ `rounds.jsonl` 의 must_fix_by 만 보면 **기각만 있는 라운드**에서 자리가 안 보인다.
#   2026-09-02 체인 검증에서 실제로 밟았다: findings.jsonl 에 codex-* 가 정확히 있는데
#   폴백이 떴다. 기각만 있는 라운드는 드물지 않다 — 오히려 병합자가 일을 한 라운드다.
Z=$(mktemp -d)
printf '%s\n' '{"round":"z1","date":"2026-09-02","must_fix":0,"consider":2,"rejected":5,"pre_existing":0,"must_fix_by":[],"tokens":{"codex-contract":41200}}' > "$Z/rounds.jsonl"
printf '%s\n' \
 '{"round":"z1","fid":"z1#consider-0","bucket":"consider","raised_by":["codex-contract"],"human":"accepted","sig":"z1"}' \
 '{"round":"z1","fid":"z1#consider-1","bucket":"consider","raised_by":["codex-blind"],"human":"accepted","sig":"z2"}' > "$Z/findings.jsonl"
zout=$(python3 "$SELF/_measure.py" "$Z/rounds.jsonl" 2>&1)
chk "⭐ 폴백하지 않는다(기본 목록 경고 없음)" "$zout" '기본 목록이다' no
chk "⭐ 자리를 findings 에서 집어낸다"        "$zout" '자리: cx-contract, cx-blind' yes
chk "옛 이름이 섞이지 않는다"                 "$zout" 'claude-blind' no
chk "정밀도 리뷰어별 행이 나온다"             "$zout" 'cx-contract *올림' yes
# ⚠ 라벨이 「셋 다」로 하드코딩돼 자리 둘인데 「셋」이라고 말했다 — 실제 구성을 말해야 한다
chk "⭐ 전원 라벨이 실제 자리 수를 말한다"     "$zout" '전원(2)' yes
chk "「셋 다」 하드코딩이 없다"                "$zout" '셋 다' no
rm -rf "$Z"

echo "=== ③ env 로 자리를 덧붙일 수 있다"
ev=$(CLAUDE_REVIEW_REVIEWERS=gemini-blind python3 "$SELF/_measure.py" "$W/rounds.jsonl" 2>&1)
chk "env 이름이 자리 목록에 들어온다" "$ev" 'gemini-blind' yes
chk "모르는 이름도 죽지 않는다(KeyError 없음)" "$ev" 'Traceback' no

echo "=== ④ 발견자 기록이 없으면 기본 목록이고 **그렇게 말한다**"
# ⚠ **별 디렉토리**에 둔다. 같은 $W 에 두면 ① 의 findings.jsonl 을 옆에서 읽어
#   자리를 찾아내고 폴백이 안 뜬다 — 실동작은 옳고 **픽스처가 누출된 것**이다.
#   (이 종류의 오염으로 이 세션에서 이미 한 번 잘못된 실패 판정을 냈다)
B=$(mktemp -d)
printf '%s\n' '{"round":"r0","date":"2026-08-01","must_fix":0,"consider":0,"rejected":0,"pre_existing":0}' > "$B/rounds.jsonl"
bare=$(python3 "$SELF/_measure.py" "$B/rounds.jsonl" 2>&1)
chk "기본 목록임을 밝힌다" "$bare" '기본 목록이다' yes
chk "정직 공백 — 죽지 않는다" "$bare" 'Traceback' no
# ⭐ 대조군 — 같은 디렉토리에 findings 를 놓으면 폴백이 사라진다(파생이 실제로 동작한다)
printf '%s\n' '{"round":"r0","fid":"r0#consider-0","bucket":"consider","raised_by":["codex-blind"],"human":null,"sig":"b1"}' > "$B/findings.jsonl"
withf=$(python3 "$SELF/_measure.py" "$B/rounds.jsonl" 2>&1)
chk "⭐ findings 가 있으면 폴백하지 않는다" "$withf" '기본 목록이다' no
rm -rf "$B"

echo "=== ⭐⭐ 사보타주 — 목록을 다시 하드코딩하면 표가 빈다"
# 고치기 전 상태를 그대로 재현한다: reviewers_of 가 옛 3종만 돌려주게 만든다.
sed 's/^    if not seen:/    return ("claude-contract", "claude-blind", "codex")\n    if not seen:/' \
    "$SELF/_measure.py" > "$W/sab.py"
sab=$(python3 "$W/sab.py" "$W/rounds.jsonl" 2>&1)
if printf '%s' "$sab" | grep -q 'codex-contract *고유'; then
  echo "  FAIL 사보타주가 발화하지 않았다 — 목록을 하드코딩해도 표가 채워진다는 뜻이다"
  fail=$((fail+1))
else
  echo "  ok   ⭐⭐ 하드코딩으로 되돌리면 리뷰어별 표가 실제로 빈다(결함 재현)"
  pass=$((pass+1))
fi
# ⚠ 대조군의 대조군 — 사보타주판이 **죽어서** 비는 것이 아님을 확인한다.
#   (죽어도 grep 은 실패하므로 위 검사만으로는 둘을 구분할 수 없다)
chk "사보타주판이 죽지 않고 돈다(빈 것이지 고장이 아니다)" "$sab" 'Traceback' no
chk "사보타주판도 라운드 수는 센다"                        "$sab" '라운드 2개' yes

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
