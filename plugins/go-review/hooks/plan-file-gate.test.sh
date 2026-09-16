#!/usr/bin/env bash
# plan-file-gate.sh 대조군 테스트
# ⚠ 시각 비교가 있는 훅이라 mtime 을 명시적으로 세팅한다 — 「방금 만든 파일」에 기대면
#   테스트가 실행 속도에 따라 흔들린다(경계 흔들림 = 플레이키의 전형).
# ⚠ 절대경로를 박지 마라 — 플러그인으로 옮기면 **다른 레포의 스크립트**를 검사하고
#   통과한다(초록은 「돌았다」가 아니라 「실패하지 않았다」).
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
H="$SELF/plan-file-gate.sh"
D=$(mktemp -d)
pass=0; fail=0


# ⚠ 반복 실행 위생 — 세션당 차단 상한(8) 카운터가 $TMPDIR 에 남는다.
#   비우지 않으면 두 번째 실행부터 상한에 걸려 **차단 기대 케이스가 거짓 통과**한다
#   (2026-09-02 실측: claude-plan-gate-<세션> 이 8 이 되어 6건이 got=PASS 로 뒤집혔다).
rm -f "${TMPDIR:-/tmp}"/claude-plan-gate-* 2>/dev/null || true
# ⚠⚠ **진전 카운터도 함께 비운다**(2026-09-03, G11 을 넣으면서 직접 밟았다).
#   `claude-plan-progress-<세션>` 이 남으면 두 번째 실행부터 stall 이 이미 쌓여 있어
#   BLOCK 기대 케이스가 **approve 로 뒤집힌다** — 단독 실행 36/0, 연속 실행 21/15 였다.
#   위 카운터와 정확히 같은 부류이고, 그래서 같은 자리에서 같이 지운다.
rm -f "${TMPDIR:-/tmp}"/claude-plan-progress-* 2>/dev/null || true

# ⚠⚠ **상한 카운터를 초기화한다** (2026-08-24).
#
# 게이트는 무한루프 방지로 세션당 차단 횟수를 `$TMPDIR/claude-plan-gate-<session>` 에 세고
# 상한(기본 8)을 넘으면 조용해진다. 그 파일이 **실행 사이에 남아** 있으면 BLOCK 기대
# 케이스가 조용히 PASS 로 나온다 — 실측으로 그렇게 됐다: 같은 테스트가 `pass=16 fail=0`
# 과 `pass=9 fail=7` 을 번갈아 냈고, 원인을 게이트에서 찾다가 두 단계를 헤맸다.
#
# ⭐ 그리고 이것은 **테스트만의 문제가 아니다** — 실제 세션에서도 8회 차단 뒤에는 게이트가
#   조용해진다(그것이 상한의 의도다). 그 사실을 아래 21번 케이스가 명시적으로 잠근다.
#   상한이 없으면 게이트가 무한 루프를 만들고, 상한이 있으면 그 뒤로는 조용하다 —
#   둘 다 참이므로 **어느 쪽도 사고로 바뀌지 않게** 테스트가 지킨다.
rm -f "${TMPDIR:-/tmp}"/claude-plan-gate-s-* 2>/dev/null

# 고정 시각(2026-08-22T00:00:00Z = 1787356800). 사람 프롬프트 시각을 여기에 맞춘다.
T_OLD=1787356800   # 사용자 발화
T_NEW=1787360400   # 그보다 1시간 뒤

touch_at() { # $1=file $2=epoch  — BSD·GNU 양쪽
  # ⚠ `touch -t` 는 **로컬 시간**으로 해석한다 — UTC 문자열을 주면 시간대만큼 어긋난다
  #   (실측: KST 에서 9시간 밀려 BLOCK 기대 7건이 조용히 PASS 로 나왔다). 그래서 여기서만
  #   `-u` 를 빼고 로컬 시각으로 만든다. 훅이 읽는 mtime 자체는 epoch 이라 시간대와 무관하다.
  d=$(date -j -f %s "$2" +%Y%m%d%H%M.%S 2>/dev/null) \
    && touch -t "${d%.*}" "$1" 2>/dev/null && return 0
  touch -d "@$2" "$1" 2>/dev/null
}

tr_with_user() { # $1=file $2=epoch — 사람 프롬프트 1건이 든 transcript(⭐ 계획을 **채택한** 세션의 모양)
  # ⚠ 2026-09-16 부터 게이트는 「이 세션이 계획을 채택했나」를 본다. 기본 픽스처는 채택한 세션이어야
  #   아래 BLOCK 기대들이 성립한다. 채택 흔적이 없는 모양은 tr_plain 이다(세션 스코프 절이 쓴다).
  ts=$(date -j -u -f %s "$2" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "@$2" +%Y-%m-%dT%H:%M:%S)
  printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${ts}.000Z\",\"message\":{\"content\":\"<command-name>/go-review:go</command-name> P0~P4\"}}" > "$1"
}
tr_plain() { # $1=file $2=epoch — 사람 프롬프트 1건, 그런데 go 호출도 계획 파일 쓰기도 없다(남의 계획을 보는 세션)
  ts=$(date -j -u -f %s "$2" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "@$2" +%Y-%m-%dT%H:%M:%S)
  printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${ts}.000Z\",\"message\":{\"content\":\"해줘\"}}" > "$1"
}

run() { # $1=label $2=plan $3=transcript $4=session $5=expect(BLOCK|PASS|WARN)
  out=$(CLAUDE_PLAN_FILE="$2" printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$4" "$3" \
        | CLAUDE_PLAN_FILE="$2" bash "$H")
  got=$(printf '%s' "$out" | jq -r 'if .decision then .decision elif .systemMessage then "WARN" else "PASS" end' 2>/dev/null)
  [ -z "$got" ] && got=PASS
  [ "$got" = "block" ] && got=BLOCK
  if [ "$got" = "$5" ]; then
    echo "  ok   $1  → $got"; pass=$((pass+1))
  else
    echo "  FAIL $1  → got=$got want=$5"; fail=$((fail+1))
  fi
}

TR="$D/tr.jsonl"; tr_with_user "$TR" "$T_OLD"

echo "=== 발화해야 하는 경우"
printf -- '- [x] 1단계\n- [ ] 2단계\n- [ ] 3단계\n' > "$D/p1.md"; touch_at "$D/p1.md" "$T_NEW"
run "미완료 2개 남음" "$D/p1.md" "$TR" s-b1 BLOCK

printf -- '- [~] 진행중\n' > "$D/p2.md"; touch_at "$D/p2.md" "$T_NEW"
run "[x] 가 아닌 표식은 미완료" "$D/p2.md" "$TR" s-b2 BLOCK

printf -- '* [ ] 별표 불릿\n  - [ ] 들여쓴 하위\n' > "$D/p3.md"; touch_at "$D/p3.md" "$T_NEW"
run "별표·들여쓰기도 센다" "$D/p3.md" "$TR" s-b3 BLOCK

echo "=== 조용해야 하는 경우(오탐 방지)"
printf -- '- [x] 1단계\n- [X] 2단계\n' > "$D/p4.md"; touch_at "$D/p4.md" "$T_NEW"
run "전부 완료(대문자 X 포함)" "$D/p4.md" "$TR" s-p1 PASS

run "계획 파일 자체가 없음" "$D/없는파일.md" "$TR" s-p2 PASS

printf -- '체크박스 없는 그냥 메모\n- 불릿이지만 상자 아님\n' > "$D/p5.md"; touch_at "$D/p5.md" "$T_NEW"
run "체크박스 0개 → 차단 말고 경고" "$D/p5.md" "$TR" s-p3 WARN

echo "=== 낡은 계획 판별 — **이 세션 시작 전의 파일인가**"
# ⭐ 두 방향이 다 필요하다. 하나만 있으면 「전부 통과」와 구분되지 않는다.
printf -- '- [ ] 남은 일\n' > "$D/p6.md"; touch_at "$D/p6.md" "$T_NEW"
run "계획이 세션 시작 뒤 → 차단 유지" "$D/p6.md" "$TR" s-s1 BLOCK

printf -- '- [ ] 남은 일\n' > "$D/p7.md"; touch_at "$D/p7.md" "$((T_OLD - 3600))"
run "계획이 세션 시작 전 → 통과(잔재)" "$D/p7.md" "$TR" s-s2 PASS

echo "=== ⭐⭐ 다중 턴 — 이 픽스처가 없어서 게이트가 무장해제돼 있었다 (2026-09-02)"
# ⚠ 기존 픽스처는 사람 발화가 **1건**뿐이라 head -1 과 tail -1 이 같았다. 그래서
#   「마지막 발화 ↔ 계획 mtime」의 결함이 테스트를 통과했다. 대화형 세션의 실제 모양은
#   사람 발화가 여러 건이고, 계획은 그 **사이**에 쓰인다.
tr_multi_user() { # $1=file $2=첫 발화 epoch $3=마지막 발화 epoch
  f1=$(date -j -u -f %s "$2" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "@$2" +%Y-%m-%dT%H:%M:%S)
  f2=$(date -j -u -f %s "$3" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "@$3" +%Y-%m-%dT%H:%M:%S)
  {
    printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${f1}.000Z\",\"message\":{\"content\":\"/go P0~P4\"}}"
    printf '%s\n' '{"type":"assistant","message":{"content":[]}}'
    printf '%s\n' "{\"type\":\"user\",\"toolUseResult\":{},\"timestamp\":\"${f2}.000Z\"}"
    printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${f2}.000Z\",\"message\":{\"content\":\"계속해줘\"}}"
  } > "$1"
}
# 첫 발화 T_OLD → 계획 T_NEW(=+1h) → 마지막 발화 T_OLD+2h
TRM="$D/tr-multi.jsonl"; tr_multi_user "$TRM" "$T_OLD" "$((T_OLD + 7200))"
printf -- '- [ ] P1\n- [ ] P2\n' > "$D/pm1.md"; touch_at "$D/pm1.md" "$T_NEW"
run "⭐ 계획이 첫 발화 뒤·마지막 발화 앞 → **차단**(실사용 모양)" "$D/pm1.md" "$TRM" s-m1 BLOCK

printf -- '- [ ] P1\n' > "$D/pm2.md"; touch_at "$D/pm2.md" "$((T_OLD - 86400))"
run "어제 잔재 파일 → 통과" "$D/pm2.md" "$TRM" s-m2 PASS

echo "=== ⭐ 사보타주 — tail -1(마지막 발화)로 되돌리면"
SAB="$D/gate-sab.sh"
sed -e 's/| head -1)/| tail -1)/' \
    -e 's/\[ "\$plan_at" -lt "\$first_at" \]/[ "$first_at" -gt "$plan_at" ]/' "$H" > "$SAB"
outs=$(CLAUDE_PLAN_FILE="$D/pm1.md" printf '{"session_id":"s-sab","transcript_path":"%s","stop_hook_active":false}' "$TRM" \
       | CLAUDE_PLAN_FILE="$D/pm1.md" bash "$SAB")
if printf '%s' "$outs" | grep -q '"block"'; then
  echo "  FAIL 사보타주가 발화하지 않았다 — 이 테스트는 무엇도 지키지 않는다"; fail=$((fail+1))
else
  echo "  ok   ⭐ 사보타주하면 통과한다(= 그것이 무장해제의 정체였다)"; pass=$((pass+1))
fi
rm -f "$SAB"

# 판별 불가 2종 → 차단 유지(모르는 것으로 게이트를 열지 않는다)
printf '%s\n' '{"type":"assistant","message":{"content":[]}}' > "$D/tr-nouser.jsonl"
printf -- '- [ ] 남은 일\n' > "$D/p8.md"; touch_at "$D/p8.md" "$T_NEW"
run "사람 프롬프트 없음 → 차단 유지" "$D/p8.md" "$D/tr-nouser.jsonl" s-s3 BLOCK
run "transcript 파일 부재 → 차단 유지" "$D/p8.md" "$D/없는것.jsonl" s-s4 BLOCK

echo "=== ⭐ 도구 결과는 「사용자 메시지」가 아니다(todo 축과 같은 함정)"
# 도구결과가 계획보다 **뒤** 시각인데도 그것으로 낡음 판정하면 게이트가 죽는다.
ts_new=$(date -j -u -f %s "$((T_NEW + 3600))" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "@$((T_NEW + 3600))" +%Y-%m-%dT%H:%M:%S)
ts_old=$(date -j -u -f %s "$T_OLD" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "@$T_OLD" +%Y-%m-%dT%H:%M:%S)
{ printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${ts_old}.000Z\",\"message\":{\"content\":\"/go 해줘\"}}"
  printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${ts_new}.000Z\",\"toolUseResult\":{\"stdout\":\"a\"},\"message\":{\"content\":[{\"type\":\"tool_result\"}]}}"
  printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${ts_new}.000Z\",\"isMeta\":true,\"message\":{\"content\":\"skill 주입\"}}"
} > "$D/tr-tool.jsonl"
printf -- '- [ ] 남은 일\n' > "$D/p9.md"; touch_at "$D/p9.md" "$T_NEW"
run "계획 뒤 도구결과·isMeta 만 → 차단 유지" "$D/p9.md" "$D/tr-tool.jsonl" s-t1 BLOCK

# ⭐ 반대 방향(2026-09-02 개정) — 사람 발화가 계획보다 **뒤**여도 이제는 차단이다.
#   ⚠ 이전 기준(「마지막 발화 뒤면 낡음」)을 잠근 테스트가 여기 있었고, **그 테스트가
#     결함을 정답으로 고정하고 있었다.** 대화형 세션은 사람 발화가 계획 뒤에 오는 것이
#     정상이므로 그것으로 낡음을 판정하면 게이트가 통째로 꺼진다.
#   이 케이스가 지키는 것: 도구 결과·isMeta 를 **첫** 발화 판별에서도 제외한다.
{ cat "$D/tr-tool.jsonl"
  printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${ts_new}.000Z\",\"message\":{\"content\":\"다른 걸 해줘\"}}"
} > "$D/tr-tool2.jsonl"
run "⭐ 도구결과 뒤 사람 발화 → **차단**(첫 발화가 기준이다)" "$D/p9.md" "$D/tr-tool2.jsonl" s-t2 BLOCK

# 첫 행이 도구 결과여도 그것을 「첫 사람 발화」로 세면 안 된다 → 계획이 그보다 앞이면 통과
{ printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${ts_old}.000Z\",\"toolUseResult\":{},\"message\":{\"content\":[]}}"
  printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${ts_new}.000Z\",\"message\":{\"content\":\"/go 해줘\"}}"
} > "$D/tr-tool3.jsonl"
printf -- '- [ ] 남은 일\n' > "$D/p9b.md"; touch_at "$D/p9b.md" "$T_OLD"
run "첫 행이 도구결과 → 그것은 첫 발화가 아니다(계획이 앞 → 통과)" "$D/p9b.md" "$D/tr-tool3.jsonl" s-t3 PASS

echo "=== 무한루프 상한"
CLAUDE_PLAN_GATE_MAX=2; export CLAUDE_PLAN_GATE_MAX
s=s-cap-$$
run "1회차" "$D/p1.md" "$TR" "$s" BLOCK
run "2회차" "$D/p1.md" "$TR" "$s" BLOCK
run "3회차(상한 도달 → 통과)" "$D/p1.md" "$TR" "$s" PASS
unset CLAUDE_PLAN_GATE_MAX

echo "=== 훅 고장은 통과(관측이 서비스를 죽이면 안 된다)"
out=$(printf '' | CLAUDE_PLAN_FILE="$D/p1.md" bash "$H"; echo "exit=$?")
case "$out" in *exit=0*) echo "  ok   빈 stdin → exit 0"; pass=$((pass+1)) ;;
                     *) echo "  FAIL 빈 stdin → $out"; fail=$((fail+1)) ;; esac

echo
echo "=== 상한 카운터의 두 얼굴(2026-08-24)"
# 21) 상한에 도달하면 조용해진다 — **의도된 동작**이고, 그것을 모르면 「게이트가 죽었다」로 오진한다.
printf -- '- [ ] 미완료\n' > "$D/pcap.md"; touch_at "$D/pcap.md" "$T_NEW"
CAP_S="s-capgate-$$"
rm -f "${TMPDIR:-/tmp}/claude-plan-gate-$CAP_S" 2>/dev/null
n_block=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  o=$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$CAP_S" "$TR" \
      | CLAUDE_PLAN_FILE="$D/pcap.md" bash "$H")
  printf '%s' "$o" | grep -q '"decision"' && n_block=$((n_block+1))
done
if [ "$n_block" = 8 ]; then
  echo "  ok   상한 8회까지만 차단하고 그 뒤 조용(10회 중 8회)"; pass=$((pass+1))
else
  echo "  FAIL 상한 동작이 달라졌다 — 10회 중 차단 $n_block 회(기대 8)"; fail=$((fail+1))
fi
rm -f "${TMPDIR:-/tmp}/claude-plan-gate-$CAP_S" 2>/dev/null

echo "=== 남의 계획 진단(2026-09-02 — 한 세션에서 세 번 겪은 뒤 추가)"
# 같은 워킹트리에서 세션이 여럿이면 이 파일 하나를 공유한다. 그때 B 세션이 A 의 계획으로
# 차단되는데 메시지는 "완주해라" 라고만 말한다 — B 는 완주할 수 없다. 진단이 틀린 것이다.
# ⚠ 차단 자체는 **유지**해야 한다(소유자를 가릴 신호가 없어 풀면 진짜 주인의 게이트도 꺼진다).
#   그러니 이 케이스들이 지키는 것은 「차단 + 올바른 진단」이지 「통과」가 아니다.
# ⚠ CLAUDE_PROJECT_DIR 은 **계획 파일이 실제로 있는 곳**이어야 한다 — 가짜 경로를 주면
#   훅이 파일을 못 찾아 조용히 통과하고, 그러면 이 케이스들이 「차단 없음」으로 거짓 실패한다
#   (처음에 그렇게 썼다가 6건이 한꺼번에 깨졌다). 소유자 불일치는 **머리말 값**으로 만든다.
diag() { # $1=머리말 작업위치(빈 값이면 머리말 없음) $2=세션
  W=$(mktemp -d); mkdir -p "$W/.claude"
  if [ -n "$1" ]; then
    owner="$1"; [ "$owner" = "SELF" ] && owner="$W"
    printf '# 계획\n\n작업 위치: **%s**\n\n- [ ] 안 끝남\n' "$owner" > "$W/.claude/plan-active.md"
  else
    printf '# 계획\n\n- [ ] 안 끝남\n' > "$W/.claude/plan-active.md"
  fi
  touch_at "$W/.claude/plan-active.md" "$T_NEW"
  tr_with_user "$W/tr.jsonl" "$T_OLD"
  printf '{"session_id":"%s","transcript_path":"%s/tr.jsonl","stop_hook_active":false}' "$2" "$W" \
    | CLAUDE_PROJECT_DIR="$W" bash "$H"
  rm -rf "$W"; rm -f "${TMPDIR:-/tmp}/claude-plan-gate-$2"
}
chk() { # $1=label $2=출력 $3=grep패턴 $4=want(yes|no)
  if printf '%s' "$2" | grep -q "$3"; then got=yes; else got=no; fi
  if [ "$got" = "$4" ]; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1  → got=$got want=$4"; fail=$((fail+1)); fi
}

out=$(diag "/other/repo" s-f1)
chk "작업 위치 불일치 → 차단은 유지한다(풀면 진짜 주인도 꺼진다)" "$out" '"block"' yes
chk "불일치를 진단해 말한다"                                      "$out" '다른 세션의 것일 수 있다' yes
chk "해결법 3종을 제시한다"                                       "$out" 'worktree' yes
chk "지우지 말라고 명시한다"                                      "$out" '줄을 지우지도 마라' yes

out=$(diag "SELF" s-f2)
chk "작업 위치가 일치하면 진단하지 않는다(오탐 방지)" "$out" '다른 세션의 것일 수 있다' no
chk "그래도 차단은 한다"                              "$out" '"block"' yes

out=$(diag "" s-f3)
chk "작업 위치가 없으면 판별 불가 → 차단 유지"       "$out" '"block"' yes
chk "판별 불가일 때 없는 근거로 진단하지 않는다"     "$out" '다른 세션의 것일 수 있다' no

echo
echo "=== ⭐ G11 진전 없음 탐지 — 미완료가 안 줄면 붙잡지 않고 넘긴다(2026-09-03)"
# 「끝나지 않는 루프」의 정체는 오래 도는 것이 아니라 **진전 없이** 도는 것이다.
# 차단 횟수 상한(8)만 있으면 8번을 성과 없이 돌고 「상한으로 통과」한다 — 그건 완주가 아니다.
raw() { # $1=plan $2=session
  CLAUDE_PLAN_FILE="$1" printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$2" "$TR" \
    | CLAUDE_PLAN_FILE="$1" bash "$H"
}
printf '# t\n\n작업 위치: %s\n\n## P0\n- [x] 하나 끝\n- [ ] 둘 아직\n' "${CLAUDE_PROJECT_DIR:-}" > "$D/pstall1.md"
touch_at "$D/pstall1.md" "$T_NEW"
rm -f "${TMPDIR:-/tmp}"/claude-plan-gate-s-st* "${TMPDIR:-/tmp}"/claude-plan-progress-s-st* 2>/dev/null

# ⚠ 1회차는 비교 대상이 없다(직전 미완료 수를 모른다) — 비교는 2회차부터다.
#    따라서 「3회 연속 안 줄었다」는 4회차에 성립한다. 이 오프셋을 테스트가 잠근다.
o1=$(raw "$D/p1.md" s-st1); o2=$(raw "$D/p1.md" s-st1); o3=$(raw "$D/p1.md" s-st1); o4=$(raw "$D/p1.md" s-st1)
chk "1회차: 차단한다"                          "$o1" '"block"' yes
chk "3회차: 아직 차단한다(비교는 2회차부터)"   "$o3" '"block"' yes
chk "⭐ 4회차: 진전 없음을 지목한다"           "$o4" '진전 없음' yes
chk "⭐ 4회차: 차단을 푼다(붙잡으면 루프만 길어진다)" "$o4" '"approve"' yes
chk "「계속하겠습니다」로 넘기지 말라고 지시"  "$o4" '계속하겠습니다' yes

# ⭐ 사보타주 — 진전이 있으면(미완료가 줄면) stall 이 리셋돼 **계속 차단**해야 한다.
#    이게 실패하면 위 탐지는 「항상 3회면 통과」라는 뜻이고 탐지기가 아니다.
rm -f "${TMPDIR:-/tmp}"/claude-plan-gate-s-st2* "${TMPDIR:-/tmp}"/claude-plan-progress-s-st2* 2>/dev/null
raw "$D/p1.md" s-st2 >/dev/null; raw "$D/p1.md" s-st2 >/dev/null
raw "$D/p1.md" s-st2 >/dev/null
o5=$(raw "$D/pstall1.md" s-st2)
chk "⭐ 진전이 있으면 진전 없음이라 하지 않는다" "$o5" '진전 없음' no
chk "진전 후에도 미완료가 남았으면 차단한다"     "$o5" '"block"' yes

echo
echo "=== ⭐ R1 리뷰 반영 — 결정 절 제외 · 계획 교체 · 미완료 증가"
printf '# t\n\n작업 위치: %s\n\n## 결정 필요(승인 전)\n- [ ] Q1 목업 선택\n- [ ] Q2 머지 주체\n\n## P0\n- [x] P0-1 끝\n' "${CLAUDE_PROJECT_DIR:-}" > "$D/pdec.md"
touch_at "$D/pdec.md" "$T_NEW"
o=$(raw "$D/pdec.md" s-dec)
chk "⭐⭐ 결정 절 체크박스만 열려 있으면 **차단하지 않는다**" "$o" '"block"' no

# 계획 교체 — 앞 계획의 stall 이 새 계획을 즉시 풀면 안 된다
rm -f "${TMPDIR:-/tmp}"/claude-plan-gate-s-sw* "${TMPDIR:-/tmp}"/claude-plan-progress-s-sw* 2>/dev/null
raw "$D/p1.md" s-sw >/dev/null; raw "$D/p1.md" s-sw >/dev/null; raw "$D/p1.md" s-sw >/dev/null
printf '# t2\n\n작업 위치: %s\n\n## P0\n- [ ] 1\n- [ ] 2\n- [ ] 3\n' "${CLAUDE_PROJECT_DIR:-}" > "$D/pnew.md"
touch_at "$D/pnew.md" "$T_NEW"
o=$(raw "$D/pnew.md" s-sw)
chk "⭐ 계획이 바뀌면 stall 을 버린다(즉시 풀리지 않는다)" "$o" '"block"' yes
chk "그때 진전 없음이라 하지 않는다"                      "$o" '진전 없음' no

# 미완료가 **늘어난** 것은 진전 없음이 아니다(작업 중 하위 항목 발견)
rm -f "${TMPDIR:-/tmp}"/claude-plan-gate-s-gr* "${TMPDIR:-/tmp}"/claude-plan-progress-s-gr* 2>/dev/null
printf '# t\n\n작업 위치: %s\n\n## P0\n- [ ] 1\n' "${CLAUDE_PROJECT_DIR:-}" > "$D/pgrow.md"
touch_at "$D/pgrow.md" "$T_NEW"
raw "$D/pgrow.md" s-gr >/dev/null
printf '# t\n\n작업 위치: %s\n\n## P0\n- [ ] 1\n- [ ] 2\n- [ ] 3\n' "${CLAUDE_PROJECT_DIR:-}" > "$D/pgrow.md"
touch_at "$D/pgrow.md" "$T_NEW"
raw "$D/pgrow.md" s-gr >/dev/null; raw "$D/pgrow.md" s-gr >/dev/null
o=$(raw "$D/pgrow.md" s-gr)
chk "⭐ 미완료가 늘어난 뒤에는 카운터가 리셋돼 계속 차단한다" "$o" '"block"' yes

echo
echo "=== ⭐⭐ 세션 스코프 — 이 세션이 **채택한** 계획만 막는다 (2026-09-16)"
# 같은 워크트리에서 세션 A 가 계획을 진행하는 동안 세션 B 가 별건을 하면, B 는 계획 파일을
# 쓰지도 go-review:go 를 부르지도 않았다. 그 B 를 A 의 미완료로 막는 것이 이 절이 잡는 오탐이다.
# ⚠ 「채택」의 근거는 transcript 의 행위 흔적이다 — 사람 프롬프트의 go 호출 · Skill 도구 ·
#   계획 파일을 **쓴** 도구(Write/Edit · Bash 재지향). 읽기는 채택이 아니다.
rm -f "${TMPDIR:-/tmp}"/claude-plan-foreign-s-sc* 2>/dev/null
TRP="$D/tr-plain.jsonl"; tr_plain "$TRP" "$T_OLD"
# ⚠ 채택 흔적 ③(파일 쓰기)은 **파일 이름**으로 맞춘다 — 그래서 이 절의 계획은 실제 이름 plan-active.md 여야 한다.
mkdir -p "$D/sc"; PSC="$D/sc/plan-active.md"
printf -- '- [ ] 남의 일\n- [ ] 남의 일 2\n' > "$PSC"; touch_at "$PSC" "$T_NEW"
run "채택 흔적 없음(사람 발화만) → 차단하지 않고 알린다" "$PSC" "$TRP" s-sc1 WARN
run "같은 세션 2회차 → 조용(알림은 세션당 한 번)"          "$PSC" "$TRP" s-sc1 PASS
o=$(CLAUDE_PLAN_FILE="$PSC" printf '{"session_id":"s-sc1b","transcript_path":"%s","stop_hook_active":false}' "$TRP" \
    | CLAUDE_PLAN_FILE="$PSC" bash "$H")
chk "알림이 「이 세션의 것이 아니다」를 말한다"      "$o" '이 세션의 것이 아니다' yes
chk "알림이 채택 경로(go-review:go)를 안내한다"      "$o" 'go-review:go' yes
chk "알림은 차단이 아니다"                           "$o" '"block"' no

# 채택 흔적 다섯 — 어느 하나면 막는다
mk_tr() { # $1=file $2=사람 프롬프트 내용 $3=(선택) assistant tool_use JSON 한 줄
  ts=$(date -j -u -f %s "$T_OLD" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d "@$T_OLD" +%Y-%m-%dT%H:%M:%S)
  { printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"${ts}.000Z\",\"message\":{\"content\":\"$2\"}}"
    [ -n "${3:-}" ] && printf '%s\n' "$3"
  } > "$1"
}
mk_tr "$D/tr-c1.jsonl" "<command-name>/go-review:go</command-name>"
run "① 사람 프롬프트의 /go-review:go(래핑) → 차단" "$PSC" "$D/tr-c1.jsonl" s-sc2 BLOCK
mk_tr "$D/tr-c2.jsonl" "/go 전부"
run "① 원문 /go → 차단" "$PSC" "$D/tr-c2.jsonl" s-sc3 BLOCK
mk_tr "$D/tr-c3.jsonl" "해줘" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"go-review:go","args":"전부"}}]}}'
run "② Skill 도구로 go-review:go → 차단" "$PSC" "$D/tr-c3.jsonl" s-sc4 BLOCK
mk_tr "$D/tr-c4.jsonl" "해줘" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/w/.claude/plan-active.md","old_string":"[ ]","new_string":"[x]"}}]}}'
run "③ 계획 파일을 Edit → 차단" "$PSC" "$D/tr-c4.jsonl" s-sc5 BLOCK
# ⛔ Bash 재지향은 채택으로 **보지 않는다**(2026-09-16 오후). 첫 판은 이 케이스를 BLOCK 으로 잠갔는데,
#   그 판별이 명령 문자열을 보는 탓에 게이트를 테스트하던 세션이 자기 픽스처 문자열로 「채택」이 되어
#   남의 계획 35개에 세 번 막혔다(Write/Edit 0 · go 0). 아래 대조군 둘이 그 오탐을 잠근다.
mk_tr "$D/tr-c5.jsonl" "해줘" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat > .claude/plan-active.md <<EOF\n- [ ] a\nEOF"}}]}}'
run "③-x Bash 재지향은 채택이 아니다 → 알림(차단 아님)" "$PSC" "$D/tr-c5.jsonl" s-sc6 WARN
mk_tr "$D/tr-c6.jsonl" "해줘" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"printf %s\\n {\"input\":{\"command\":\"cat > .claude/plan-active.md <<EOF\"}} > $D/fixture.jsonl"}}]}}'
run "③-y ⭐ 픽스처 문자열 안의 재지향(게이트를 테스트하는 세션) → 채택 아님" "$PSC" "$D/tr-c6.jsonl" s-sc7 WARN

# 채택이 **아닌** 것 — 이것이 없으면 위 다섯은 「아무 도구 호출이나 있으면 막는다」와 구분되지 않는다
rm -f "${TMPDIR:-/tmp}"/claude-plan-foreign-s-sn* 2>/dev/null
mk_tr "$D/tr-n1.jsonl" "해줘" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"head -20 .claude/plan-active.md; grep -c x .claude/plan-active.md 2>/dev/null"}}]}}'
run "대조군: 계획 파일을 **읽기만** → 채택 아님(알림)" "$PSC" "$D/tr-n1.jsonl" s-sn1 WARN
mk_tr "$D/tr-n2.jsonl" "해줘" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/w/docs/other.md","content":"x"}}]}}'
run "대조군: 다른 파일을 씀 → 채택 아님(알림)" "$PSC" "$D/tr-n2.jsonl" s-sn2 WARN
mk_tr "$D/tr-n3.jsonl" "<command-name>/go-review:plan</command-name>"
run "대조군: /go-review:plan 은 채택이 아니다(초안 단계)" "$PSC" "$D/tr-n3.jsonl" s-sn3 WARN
mk_tr "$D/tr-n4.jsonl" "/goal 뭐지"
run "대조군: /goal 은 /go 가 아니다" "$PSC" "$D/tr-n4.jsonl" s-sn4 WARN

# 판별 불가는 차단 유지 — 위 「사람 프롬프트 없음」「transcript 부재」 두 케이스가 이미 잠근다.
# 채택한 세션의 나머지 동작(상한·진전 없음·남의 계획 진단)은 위 절들이 tr_with_user 로 그대로 잠근다.

# ⭐ 사보타주 — 채택 판별을 빼면(항상 채택으로 보면) 남의 계획도 막는다. 그것이 종전 결함이다.
SAB2="$D/gate-sab2.sh"
sed -e 's/\[ "\$claim_rc" -eq 1 \]/false/' "$H" > "$SAB2"
o=$(CLAUDE_PLAN_FILE="$PSC" printf '{"session_id":"s-sab2","transcript_path":"%s","stop_hook_active":false}' "$TRP" \
    | CLAUDE_PLAN_FILE="$PSC" bash "$SAB2")
chk "⭐ 사보타주(채택 판별 제거)하면 남의 계획을 막는다 — 이 절이 그것을 지킨다" "$o" '"block"' yes
rm -f "$SAB2" "${TMPDIR:-/tmp}"/claude-plan-gate-s-sab2 "${TMPDIR:-/tmp}"/claude-plan-progress-s-sab2
rm -f "${TMPDIR:-/tmp}"/claude-plan-foreign-s-s* "${TMPDIR:-/tmp}"/claude-plan-gate-s-sc* "${TMPDIR:-/tmp}"/claude-plan-progress-s-sc* 2>/dev/null

echo "pass=$pass fail=$fail"
rm -rf "$D"
[ "$fail" -eq 0 ]
