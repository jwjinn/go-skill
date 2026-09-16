#!/usr/bin/env bash
# review-gate.sh 대조군. 실행: bash <플러그인>/hooks/review-gate.test.sh
#
# ⭐ 이 파일의 목적은 "훅이 돈다"가 아니라 **"훅이 무엇을 잡고 무엇을 안 잡는가"**를 고정하는 것이다.
#   차단하는 검사에서 오탐 비용은 미탐보다 즉각적이므로(2026-08-03 credentials.go 가 배포를
#   세운 그 교훈), 「조용해야 하는 경우」를 「차단해야 하는 경우」만큼 촘촘히 단언한다.
#
# ⚠ 시각은 **epoch 으로 직접** 지정한다. `touch -t` 는 로컬 시간 해석이라 UTC 문자열을 주면
#   KST 에서 9시간이 밀리고, 그러면 BLOCK 기대가 조용히 PASS 로 통과한다(실제로 겪은 함정).
set -u

HOOK="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/review-gate.sh"
pass=0; fail=0

# ⚠ 반복 실행 위생 — 세션당 차단 상한(8) 카운터가 $TMPDIR 에 남는다.
#   비우지 않으면 두 번째 실행부터 상한에 걸려 **차단 기대 케이스가 거짓 통과**한다
#   (2026-09-02 실측: claude-review-gate-<세션> 이 8 이 되어 6건이 got=PASS 로 뒤집혔다).
rm -f "${TMPDIR:-/tmp}"/claude-review-gate-* 2>/dev/null || true

ok(){ printf '  ok   %s  → %s\n' "$1" "$2"; pass=$((pass+1)); }
ng(){ printf '  NG   %s  (기대 %s · 실제 %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); }

# 판정: BLOCK | WARN | PASS
verdict(){
  if   printf '%s' "$1" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then printf 'BLOCK'
  elif printf '%s' "$1" | grep -q '"systemMessage"'; then printf 'WARN'
  else printf 'PASS'; fi
}
expect(){ # $1=이름 $2=기대 $3=실제출력
  v=$(verdict "$3"); [ "$v" = "$2" ] && ok "$1" "$v" || ng "$1" "$2" "$v"
}

# ── 픽스처 ───────────────────────────────────────────────────────────────────
NOW=$(date +%s)
setup(){ # $1=세션id → $T 를 만든다
  T=$(mktemp -d); mkdir -p "$T/.claude/review/runs"
  SESS="$1"
  ( cd "$T" && git init -q . && git config user.email t@t && git config user.name t ) 2>/dev/null
  # 사람 프롬프트 1건(오래 전) — 낡음 판별의 기준선
  py "$T/tr.jsonl" "$((NOW - 3600))"
}
py(){ # $1=transcript 경로 $2=사람 프롬프트 epoch
  python3 - "$1" "$2" <<'EOF'
import sys, json, datetime
path, ts = sys.argv[1], int(sys.argv[2])
iso = datetime.datetime.utcfromtimestamp(ts).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(path, 'w') as f:
    # ⭐ 기본 픽스처는 리뷰를 **채택한** 세션이다(go 호출이 있다 · 2026-09-16 세션 스코프).
    f.write(json.dumps({"type": "user", "timestamp": iso,
                        "message": {"content": "<command-name>/go-review:go</command-name>"}}) + "\n")
EOF
}
pyplain(){ # $1=transcript 경로 $2=epoch — 사람 발화는 있는데 go 호출도 파일 쓰기도 없다(남의 리뷰를 보는 세션)
  python3 - "$1" "$2" <<'EOF'
import sys, json, datetime
path, ts = sys.argv[1], int(sys.argv[2])
iso = datetime.datetime.utcfromtimestamp(ts).strftime('%Y-%m-%dT%H:%M:%SZ')
with open(path, 'w') as f:
    f.write(json.dumps({"type": "user", "timestamp": iso, "message": {"content": "해줘"}}) + "\n")
EOF
}
setmtime(){ python3 -c "import os,sys; os.utime(sys.argv[1],(int(sys.argv[2]),int(sys.argv[2])))" "$1" "$2"; }
run(){ printf '{"session_id":"%s","transcript_path":"%s/tr.jsonl"}' "$SESS" "$T" \
       | CLAUDE_PROJECT_DIR="$T" bash "$HOOK" 2>/dev/null; }
# ⚠ 카운터는 **세션마다** 파일이 하나다. `SESS` 를 덮어쓴 뒤 cleanup 을 부르면 앞 세션의
#   카운터가 남고, 8회 실행 뒤 그 세션의 BLOCK 기대가 조용히 PASS 로 뒤집혀 **테스트가
#   스스로 깨진다**(코드는 멀쩡한데 빨개지고, 원인 신호가 없다). 실측으로 잔재를 확인했다.
#   그래서 지울 세션을 인자로 더 받는다.
cleanup(){ rm -rf "$T"; for _s in "$SESS" "$@"; do rm -f "${TMPDIR:-/tmp}/claude-review-gate-$_s"; done; }

echo "=== ① 차단 축 — 확정된 결함이 미해결"

setup s1; printf '# r\n- [ ] [blocker] a.go:1 — 터진다\n- [x] 고침\n' > "$T/.claude/review-active.md"
setmtime "$T/.claude/review-active.md" "$NOW"
expect "미해결 1개 남음" BLOCK "$(run)"; cleanup

setup s2; printf '# r\n- [~] 진행중\n' > "$T/.claude/review-active.md"
setmtime "$T/.claude/review-active.md" "$NOW"
expect "[x] 아닌 표식은 미완료" BLOCK "$(run)"; cleanup

setup s3; printf '# r\n- [ ] 미해결\n' > "$T/.claude/review-active.md"
setmtime "$T/.claude/review-active.md" "$NOW"; rm -f "$T/tr.jsonl"
expect "transcript 부재 → 판별불가는 차단 유지" BLOCK "$(run)"; cleanup

setup s4; printf '# r\n- [ ] 미해결\n' > "$T/.claude/review-active.md"
setmtime "$T/.claude/review-active.md" "$NOW"
# 도구 결과만 있는 transcript — 사람 발화가 아니다(2026-08-22 무장해제 사고의 그 조건)
printf '{"type":"user","timestamp":"2099-01-01T00:00:00Z","toolUseResult":{"x":1}}\n' > "$T/tr.jsonl"
expect "도구결과는 사람 발화가 아니다 → 차단 유지" BLOCK "$(run)"; cleanup

echo "=== ② 조용해야 하는 경우(오탐 방지)"

setup s5; printf '# r\n- [x] 고침\n- [X] 고침\n' > "$T/.claude/review-active.md"
setmtime "$T/.claude/review-active.md" "$NOW"
expect "전부 완료(대문자 X 포함)" PASS "$(run)"; cleanup

setup s6   # 리뷰 파일도 계획 파일도 없다
expect "리뷰·계획 파일 둘 다 없음" PASS "$(run)"; cleanup

setup s7; printf '# r\n리뷰가 깨끗했다\n' > "$T/.claude/review-active.md"
setmtime "$T/.claude/review-active.md" "$NOW"
expect "체크박스 0개 → 차단 말고 경고" WARN "$(run)"; cleanup

setup s8; printf '# r\n- [ ] 미해결\n' > "$T/.claude/review-active.md"
setmtime "$T/.claude/review-active.md" "$((NOW - 7200))"   # 사람 발화(-3600)보다 과거
expect "사용자가 리뷰 이후 말함 → 낡음" PASS "$(run)"; cleanup

echo "=== ③ 무한루프 상한(하네스 상한 8과 같은 값)"
setup s9; printf '# r\n- [ ] 미해결\n' > "$T/.claude/review-active.md"
setmtime "$T/.claude/review-active.md" "$NOW"
blocked=0
for i in $(seq 1 10); do [ "$(verdict "$(run)")" = "BLOCK" ] && blocked=$((blocked+1)); done
[ "$blocked" -eq 8 ] && ok "10회 중 8회만 차단" "BLOCK×8" || ng "상한 8회" "8" "$blocked"
cleanup

echo "=== ④ 경고 축 — 승인된 구현인데 리뷰를 안 돌렸나"

setup s10; printf 'x\n' > "$T/a.go"   # 코드 변경은 있으나 계획이 없다
expect "계획 파일 없음 → 조용(승인된 구현이 아니다)" PASS "$(run)"; cleanup

setup s11; printf '# p\n- [ ] 할일\n' > "$T/.claude/plan-active.md"; printf 'x\n' > "$T/README.md"
expect "문서만 변경 → 조용" PASS "$(run)"; cleanup

setup s12; printf '# p\n- [ ] 할일\n' > "$T/.claude/plan-active.md"; printf 'x\n' > "$T/a.go"
expect "계획+코드변경+리뷰없음 → 경고" WARN "$(run)"; cleanup

setup s13; printf '# p\n- [ ] 할일\n' > "$T/.claude/plan-active.md"; printf 'x\n' > "$T/a.go"
mkdir -p "$T/.claude/review/runs/R1"; printf '{}' > "$T/.claude/review/runs/R1/merged.json"
setmtime "$T/.claude/review/runs/R1/merged.json" "$NOW"     # 사람 발화(-3600) 이후
expect "이번 요청에 리뷰가 돌았다 → 조용" PASS "$(run)"; cleanup

setup s14; printf '# p\n- [ ] 할일\n' > "$T/.claude/plan-active.md"; printf 'x\n' > "$T/a.go"
mkdir -p "$T/.claude/review/runs/R0"; printf '{}' > "$T/.claude/review/runs/R0/merged.json"
setmtime "$T/.claude/review/runs/R0/merged.json" "$((NOW - 7200))"   # 지난 요청의 리뷰다
expect "지난 요청의 리뷰는 안 쳐준다 → 경고" WARN "$(run)"; cleanup

# ⭐ 「살아 있다」의 정의 — goal-echo.sh 와 같은 기준(미완료 1개 이상)이어야 한다.
setup s14b; printf '# p\n- [x] 다 끝남\n' > "$T/.claude/plan-active.md"; printf 'x\n' > "$T/a.go"
expect "계획이 전부 [x] 면 조용(파일이 남아 있어도)" PASS "$(run)"; cleanup

# ⭐ 미추적 **디렉토리** 안의 코드 — 기본 -unormal 이면 한 줄로 접혀 0 이 된다.
#   가장 리뷰가 필요한 순간(새 슬라이스 통째)에 탐지기가 침묵하던 자리다.
setup s14c; printf '# p\n- [ ] 할일\n' > "$T/.claude/plan-active.md"
mkdir -p "$T/backend/internal/foo"; printf 'package foo\n' > "$T/backend/internal/foo/a.go"
expect "새 디렉토리 안의 .go 도 코드 변경으로 센다" WARN "$(run)"; cleanup

echo "=== ⑤ 경로 재지정(CLAUDE_REVIEW_FILE) — 한 트리에서 세션을 나누는 유일한 수단"
# ⚠ 폴백 파일을 **미해결로 둔 채** 시험한다. 전부 [x] 로 두면 override 가 무시돼도 PASS 라
#   「격리된다」를 증명하지 못한다 — 격리가 없어도 통과하는 대조군은 대조군이 아니다.
setup s15; printf '# 공용\n- [ ] 남의 미해결\n' > "$T/.claude/review-active.md"
setmtime "$T/.claude/review-active.md" "$NOW"
expect "override 없으면 공용 파일을 본다" BLOCK "$(run)"; cleanup

setup s16; printf '# 공용\n- [ ] 남의 미해결\n' > "$T/.claude/review-active.md"
printf '# 내 것\n- [x] 다 고침\n' > "$T/mine.md"
setmtime "$T/.claude/review-active.md" "$NOW"; setmtime "$T/mine.md" "$NOW"
out=$(printf '{"session_id":"%s","transcript_path":"%s/tr.jsonl"}' "$SESS" "$T" \
      | CLAUDE_PROJECT_DIR="$T" CLAUDE_REVIEW_FILE="$T/mine.md" bash "$HOOK" 2>/dev/null)
expect "override 를 주면 남의 미해결에 안 걸린다" PASS "$out"; cleanup

echo "=== ⑥ 훅 고장은 통과(관측이 서비스를 죽이면 안 된다)"
out=$(printf '' | bash "$HOOK" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "빈 stdin → exit 0·무출력" "PASS" || ng "빈 stdin" "PASS" "rc=$rc"
out=$(printf 'not json' | bash "$HOOK" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "깨진 stdin → exit 0" "PASS" || ng "깨진 stdin" "exit 0" "rc=$rc"

echo "=== ⑧ ⭐⭐ 세션 스코프 — 이 세션이 채택한 리뷰·계획만 본다 (2026-09-16)"
setup s20; printf '# r\n- [ ] 남의 미해결\n' > "$T/.claude/review-active.md"; setmtime "$T/.claude/review-active.md" "$NOW"
pyplain "$T/tr.jsonl" "$((NOW - 3600))"
expect "채택 흔적 없음 → 남의 리뷰는 막지 않는다" PASS "$(run)"; cleanup

setup s21; printf '# r\n- [ ] 미해결\n' > "$T/.claude/review-active.md"; setmtime "$T/.claude/review-active.md" "$NOW"
python3 -c 'import json,sys;print(json.dumps({"type":"user","timestamp":"2000-01-01T00:00:00Z","message":{"content":"<command-name>/go-review:review-loop</command-name>"}}))' > "$T/tr.jsonl"
expect "/go-review:review-loop 을 부른 세션 → 차단" BLOCK "$(run)"; cleanup

setup s22; printf '# r\n- [ ] 미해결\n' > "$T/.claude/review-active.md"; setmtime "$T/.claude/review-active.md" "$NOW"
{ python3 -c 'import json;print(json.dumps({"type":"user","timestamp":"2000-01-01T00:00:00Z","message":{"content":"해줘"}}))'
  python3 -c 'import json;print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/w/.claude/review-active.md","content":"- [ ] x"}}]}}))'
} > "$T/tr.jsonl"
expect "리뷰 파일을 쓴 세션 → 차단" BLOCK "$(run)"; cleanup

setup s23; printf '# p\n- [ ] 남의 할일\n' > "$T/.claude/plan-active.md"; printf 'x\n' > "$T/a.go"
pyplain "$T/tr.jsonl" "$((NOW - 3600))"
expect "경고 축도 스코프다 — 남의 계획 + 내 코드 변경 → 조용" PASS "$(run)"; cleanup

# ⭐ 사보타주 — 채택 판별을 빼면 s20 이 막힌다(= 종전 결함). 이것이 없으면 위 PASS 가 「게이트를 통째로 뺀 것」과 구분되지 않는다.
SAB="$(mktemp)"; sed -e 's/\[ "\$r_claim" -ne 1 \]/true/' "$HOOK" > "$SAB"
setup s24; printf '# r\n- [ ] 남의 미해결\n' > "$T/.claude/review-active.md"; setmtime "$T/.claude/review-active.md" "$NOW"
pyplain "$T/tr.jsonl" "$((NOW - 3600))"
o=$(printf '{"session_id":"%s","transcript_path":"%s/tr.jsonl"}' "$SESS" "$T" | CLAUDE_PROJECT_DIR="$T" bash "$SAB" 2>/dev/null)
expect "⭐ 사보타주(채택 판별 제거) → 남의 리뷰를 막는다" BLOCK "$o"; cleanup; rm -f "$SAB"

echo "=== ⑦ 사보타주 — 탐지기가 정말 그 조건을 보는가"
# 미해결 줄을 [x] 로 바꾸면 통과해야 한다. 안 그러면 이 테스트는 다른 이유로 BLOCK 을 보고 있다.
setup s17; printf '# r\n- [ ] 미해결\n' > "$T/.claude/review-active.md"; setmtime "$T/.claude/review-active.md" "$NOW"
b1=$(verdict "$(run)"); cleanup
setup s18; printf '# r\n- [x] 미해결\n' > "$T/.claude/review-active.md"; setmtime "$T/.claude/review-active.md" "$NOW"
b2=$(verdict "$(run)"); cleanup
[ "$b1" = "BLOCK" ] && [ "$b2" = "PASS" ] \
  && ok "체크 하나로 판정이 뒤집힌다(탐지기 생존)" "BLOCK→PASS" \
  || ng "사보타주" "BLOCK→PASS" "$b1→$b2"

printf '\npass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
