#!/usr/bin/env bash
# verdict.test.sh — 발견 단위 기록 + 사람 판정 + 정밀도 계산의 대조군.
#
# ⭐ 이 스위트가 지키는 것은 「값이 계산된다」가 아니라 **「못 잴 때 계산하지 않는다」** 다.
#   정밀도는 사람 라벨 없이는 존재할 수 없는 값이라, 라벨이 없는데 숫자가 나오면
#   그 숫자는 어딘가에서 지어낸 것이다.
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
pass=0; fail=0

chk() { # $1=label $2=출력 $3=패턴 $4=yes|no
  if printf '%s' "$2" | grep -q -- "$3"; then got=yes; else got=no; fi
  if [ "$got" = "$4" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1  → got=$got want=$4  (패턴: $3)"; fail=$((fail+1)); fi
}

# ── 픽스처 ──────────────────────────────────────────────────────────────────
mk() { # $1=워크디렉토리
  mkdir -p "$1/round" "$1/hist"
  cat > "$1/round/merged.json" <<'J'
{"scope_verdict":"complete",
 "must_fix":[
   {"severity":"must_fix","file":"a.go","line":10,"summary":"진짜 결함","reviewers":["claude-blind"],"verdict":"CONFIRMED"},
   {"severity":"must_fix","file":"b.go","line":20,"summary":"둘이 본 것","reviewers":["claude-blind","codex"],"verdict":"CONFIRMED"}],
 "consider":[
   {"severity":"consider","file":"c.go","line":5,"summary":"취향일 수 있다","reviewers":["claude-contract"],"verdict":"PLAUSIBLE"},
   {"severity":"consider","file":"d.go","line":7,"summary":"병합자가 스스로 올린 것","verdict":"CONFIRMED"}],
 "rejected":[{"summary":"기각된 것","raised_by":["codex"],"reject_reason":"근거 없음"}]}
J
}
rec() { CLAUDE_PROJECT_DIR="$1" python3 "$SELF/_record.py" "$1/round" "$1/hist" "$2" "2026-09-02" "테스트" "" ""; }
ver() { python3 "$SELF/_verdict.py" "$1/hist/findings.jsonl" "${@:2}"; }
mea() { python3 "$SELF/_measure.py" "$1/hist/rounds.jsonl"; }

echo "=== 발견 단위 기록"
W=$(mktemp -d); mk "$W"
out=$(rec "$W" R1 2>&1)
chk "발견 5건이 펼쳐진다(must_fix2+consider2+rejected1)" "$out" '이 라운드 5건' yes
chk "미판정을 세어 알린다(판정 대상은 must_fix+consider 4건)" "$out" '미판정 4건' yes
n=$(grep -c '"human": *null' "$W/hist/findings.jsonl")
chk "기록 시점에 human 은 전부 null 이다(모델이 채우지 않는다)" "$n" '^5$' yes
chk "프롬프트 버전이 붙는다" "$(cat "$W/hist/findings.jsonl")" '"prompt_version"' yes

# ⭐⭐ 이관이 조용히 깨뜨리는 자리 — 지시문 파일을 **프로젝트 루트**에서 찾던 옛 코드를
#     플러그인에 그대로 두면 전부 "부재"가 되고 이 축은 아무것도 구분하지 못한다.
#     그래서 「몇 개를 찾았나」를 테스트에 박는다(탐지기 생존 증명).
pf=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).readline())['prompt_files'])" \
      "$W/hist/findings.jsonl" 2>/dev/null)
chk "⭐ 지시문 5개를 실제로 찾았다(0/6 이면 탐지기가 죽은 것)" "$pf" '^5/6$' yes
mkdir -p "$W/.claude"; printf '규칙\n' > "$W/.claude/review-rules.md"
v_no=$(python3 -c "import sys; sys.path.insert(0,sys.argv[1]); import _findings as F; print(F.prompt_version('/nonexistent')[0])" "$SELF")
v_yes=$(python3 -c "import sys; sys.path.insert(0,sys.argv[1]); import _findings as F; print(F.prompt_version(sys.argv[2])[0])" "$SELF" "$W")
if [ -n "$v_no" ] && [ "$v_no" != "$v_yes" ]; then
  echo "  ok   ⭐ 프로젝트 리뷰 규칙이 버전에 반영된다(있고/없고가 다른 해시)"; pass=$((pass+1))
else
  echo "  FAIL 프로젝트 규칙을 넣어도 프롬프트 버전이 같다 — 규칙 변경이 관측되지 않는다"; fail=$((fail+1))
fi

echo "=== ⛔ 사람 판정이 없으면 정밀도를 계산하지 않는다"
out=$(mea "$W" 2>&1)
chk "계산하지 않았다고 말한다"       "$out" '계산하지 않았다' yes
chk "숫자를 지어내지 않는다(정밀도 %)" "$out" '정밀도 [0-9]' no

echo "=== 판정 기록"
out=$(ver "$W" R1 mf1=a mf2=a c1=r c2=d 2>&1)
chk "4건 기록"                     "$out" '판정 4건 기록' yes
chk "남은 미판정 0"                 "$out" '남은 미판정 0건' yes
out=$(mea "$W" 2>&1)
chk "라벨이 생기면 정밀도가 나온다"   "$out" '정밀도' yes
chk "deferred 는 오탐이 아니다(4건 중 오탐 1 → 75%%)" "$out" '정밀도 75%' yes
chk "1인 기준선 표가 나온다"         "$out" '1인 기준선' yes
chk "⭐발견자 미기록은 기준선에서 뺀다" "$out" '발견자 미기록 1건' yes

echo "=== ⭐ 사보타주 — 미기록 항목을 분모에 남기면"
# 보호를 지우면 「셋 다」가 아무도 못 잡은 것까지 잡은 것으로 세어 세 명 구성이 유리해진다
sab=$(python3 - "$SELF/_measure.py" <<'P'
import io,sys,re
s=io.open(sys.argv[1],encoding="utf-8").read()
s=s.replace('attributed = [r for r in real if r.get("raised_by")]','attributed = list(real)')
open("/tmp/_m_sab.py","w").write(s)
P
python3 /tmp/_m_sab.py "$W/hist/rounds.jsonl" 2>&1)
chk "사보타주하면 제외 문구가 사라진다(대조군 발화)" "$sab" '발견자 미기록' no
rm -f /tmp/_m_sab.py

echo "=== 잘못된 인자는 아무것도 쓰지 않는다"
before=$(md5 -q "$W/hist/findings.jsonl" 2>/dev/null || md5sum "$W/hist/findings.jsonl" | cut -d' ' -f1)
out=$(ver "$W" R1 mf9=a 2>&1)
after=$(md5 -q "$W/hist/findings.jsonl" 2>/dev/null || md5sum "$W/hist/findings.jsonl" | cut -d' ' -f1)
chk "없는 발견을 지목하면 거부"       "$out" '그런 발견이 없다' yes
chk "그때 파일은 안 바뀐다(부분 적용 금지)" "$before" "^$after\$" yes
out=$(ver "$W" R1 mf1=maybe 2>&1)
chk "판정 어휘가 아니면 거부"         "$out" 'a·r·d 중 하나' yes

echo "=== 재기록은 사람 판정을 보존한다"
out=$(rec "$W" R1 2>&1)
chk "판정 4건 보존"                  "$out" '사람 판정 4건 보존' yes
chk "보존됐으면 미판정 경고가 없다"    "$out" '미판정' no

echo "=== ⭐ 내용이 바뀌면 옛 판정을 지운다(다른 발견에 붙은 라벨이 된다)"
python3 - "$W" <<'P'
import io,json,sys
p=sys.argv[1]+"/round/merged.json"
d=json.load(io.open(p,encoding="utf-8"))
d["must_fix"][0]["summary"]="완전히 다른 결함"   # 같은 자리, 다른 내용
io.open(p,"w",encoding="utf-8").write(json.dumps(d,ensure_ascii=False))
P
out=$(rec "$W" R1 2>&1)
chk "바뀐 1건의 판정을 지웠다고 말한다" "$out" '판정을 \*\*지웠다\*\*' yes
chk "안 바뀐 3건은 보존"              "$out" '사람 판정 3건 보존' yes
rm -rf "$W"

echo "=== ⭐ G10 판정 출처 — user/auto 를 구분해 기록한다(2026-09-03)"
jb() { python3 - "$1/hist/findings.jsonl" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1],encoding='utf-8') if l.strip()]
r=[x for x in rows if x.get("human")]
print(((r[0].get("judged_by") or "(없음)")+"/"+(r[0].get("human") or "")) if r else "(판정없음)")
PY
}
W=$(mktemp -d); mk "$W"; rec "$W" R1 >/dev/null 2>&1
out=$(ver "$W" R1 mf1=a 2>&1)
chk "플래그 없음 → 사람 판정이라 말한다"        "$out" '사람 판정' yes
chk "사람 판정에는 자기채점 경고가 없다"        "$out" '자기 채점' no
chk "플래그 없음 → judged_by=user"              "$(jb "$W")" '^user/accepted$' yes
rm -rf "$W"

W=$(mktemp -d); mk "$W"; rec "$W" R1 >/dev/null 2>&1
out=$(ver "$W" R1 --auto "mf1=r:codex 가 판정" 2>&1)
chk "--auto 는 r(오탐)을 **동의 없이** 기록한다" "$(jb "$W")" '^auto/rejected$' yes
chk "자동 판정임을 출력이 말한다"                "$out" '자동' yes
chk "⭐ 자기 채점임을 경고한다(숫자 세탁 방지)"  "$out" '자기 채점' yes
rm -rf "$W"

# 사보타주: judged_by 기록을 지우면 두 출처가 구분되지 않는다 → 위 대조군이 죽는다
W=$(mktemp -d); mk "$W"; rec "$W" R1 >/dev/null 2>&1
ver "$W" R1 --auto mf1=a >/dev/null 2>&1
chk "자동 판정이 user 로 위장되지 않는다"        "$(jb "$W")" '^user/' no
rm -rf "$W"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
