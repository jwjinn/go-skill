#!/usr/bin/env bash
# tester.test.sh — 이 도구가 **무엇을 막는다고 주장하는지**를 대조군으로 증명한다.
#
# ⭐ 규약: 「이 검사가 X 를 막는다」는 그 보호를 지웠을 때 실제로 통과해야 참이다.
#   그래서 절반이 **위반을 일부러 만들어** 거부되는지 보는 검사다.
#
# 로컬 모델을 부르지 않는 검사(구조·거부 경로)는 mock claude 로 돌린다 — 네트워크 없이,
# 결정론적으로, 몇 초 만에. 모델을 실제로 부르는 검사는 `--live` 를 줘야 돈다.
#
# 사용: tester.test.sh [--live]
set -u

SELF="$(cd "$(dirname "$0")" && pwd)"
LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

PASS=0; FAIL=0; SKIP=0
T="${TMPDIR:-/tmp}/go-tester-test-$$"
MOCKBIN="$T/bin"
rm -rf "$T"; mkdir -p "$T" "$MOCKBIN"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  ⛔ %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  ⏭  %s\n' "$1"; }

# ── mock claude ──────────────────────────────────────────────────────────────
# ⚠ 진짜 claude 를 쓰면 이 스위트가 네트워크·모델 상태에 묶인다. 거부 경로를 재는 데는
#   모델이 필요 없다 — 필요한 것은 **자식이 무엇을 냈을 때 우리가 어떻게 판정하는가** 다.
make_mock() { # make_mock <자식이 낼 result 문자열> [부수효과 명령]
  cat > "$MOCKBIN/claude" <<MOCKEOF
#!/usr/bin/env bash
${2:-:}
python3 - "\$@" <<'PYEOF'
import json, sys
result = $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")
print(json.dumps({
    "subtype": "success", "num_turns": 3, "is_error": False,
    "usage": {"input_tokens": 100, "output_tokens": 20},
    "result": result,
}))
PYEOF
MOCKEOF
  chmod +x "$MOCKBIN/claude"
}

good_result() { # 스키마를 만족하는 정상 산출
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({
    "mode": "full", "commands": ["go test ./... -count=1"],
    "passed": 1, "failed": 0, "skipped": 0, "failures": [],
    "tests_written": [{"file": "x_test.go", "locks": "빈 입력에 0 을 돌려준다"}],
    "control_group": [{"test": "x", "mutation": "비교 뒤집기", "went_red": sys.argv[1] == "red"}],
    "files_changed": ["x_test.go"], "notes": "", "unavailable_reason": "",
}, ensure_ascii=False))
PY
}

# 계획 지문 — 옵트인은 계획 파일의 **내용 해시**에 묶인다(경로가 아니라).
#   픽스처도 그 규약을 지켜야 한다. 종전 픽스처는 지문이 없어서, 새 통제가 붙은 순간
#   11개 검사가 한꺼번에 rc 70 으로 떨어졌다 — 통제가 실제로 문다는 증거였다.
plan_fp() { # plan_fp <계획 파일>
  python3 -c 'import hashlib,io,sys
try:
    print(hashlib.sha256(io.open(sys.argv[1],"rb").read()).hexdigest()[:16])
except Exception:
    print("")' "$1"
}

write_optin() { # write_optin <레포> [계획 파일] — 지문까지 갖춘 유효한 옵트인
  local r="$1" pf="${2:-$1/.claude/plan-active.md}"
  [ -f "$pf" ] || printf '# 계획\n\n- [ ] 항목\n' > "$pf"
  printf '{"answer":"use","plan_file":"%s","plan_fingerprint":"%s","heartbeat_at":"2026-09-15T00:00:00"}\n' \
    "$pf" "$(plan_fp "$pf")" > "$r/.claude/tester/opt-in.json"
}

good_result_empty() { # 테스트를 썼는데 자기신고는 비운 산출
  python3 - <<'PY'
import json
print(json.dumps({
    "mode": "full", "commands": [], "passed": 1, "failed": 0, "skipped": 0, "failures": [],
    "tests_written": [], "control_group": [],
    "files_changed": [], "notes": "", "unavailable_reason": "",
}, ensure_ascii=False))
PY
}

new_repo() { # new_repo <경로> [enabled] — git 레포 + 구성 + 유효한 옵트인
  local r="$1" en="${2:-ask}"
  rm -rf "$r"; mkdir -p "$r/.claude/tester"
  git -C "$r" init -q
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name t
  echo "package p" > "$r/x.go"
  printf 'module p\n\ngo 1.22\n' > "$r/go.mod"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -q -m init
  printf '{"enabled":"%s","endpoint":"http://127.0.0.1:1/v1","model":"m"}\n' "$en" > "$r/.claude/tester/config.json"
  printf 'do something\n' > "$r/task.txt"
  write_optin "$r"
}

# probe 를 통과시키는 mock: proxy.sh·probe.sh 를 가짜로 덮는다.
stub_probe() { # stub_probe <available:true|false>
  cat > "$MOCKBIN/probe.sh" <<PEOF
#!/usr/bin/env bash
echo '{"available":$1,"reason":"stub","latency_ms":1,"model":"m","endpoint":"e"}'
PEOF
  cat > "$MOCKBIN/proxy.sh" <<'PEOF'
#!/usr/bin/env bash
case "${1:-status}" in status) exit 0 ;; *) exit 0 ;; esac
PEOF
  chmod +x "$MOCKBIN/probe.sh" "$MOCKBIN/proxy.sh"
}

# tester.sh 를 mock 스크립트가 보이는 자리에 복사해서 돌린다.
run_with_mocks() { # run_with_mocks <레포> [추가 인자...]
  local r="$1"; shift
  local sandbox="$T/plugin"
  rm -rf "$sandbox"; mkdir -p "$sandbox"
  cp "$SELF"/*.sh "$SELF"/*.py "$SELF"/*.json "$SELF"/*.md "$sandbox/" 2>/dev/null
  cp "$MOCKBIN/probe.sh" "$MOCKBIN/proxy.sh" "$sandbox/" 2>/dev/null
  PATH="$MOCKBIN:$PATH" CLAUDE_PROJECT_DIR="$r" \
    bash "$sandbox/tester.sh" --cwd "$r" --task "$r/task.txt" --out "$T/out.json" "$@" >"$T/stdout" 2>"$T/stderr"
  echo $?
}

reason_of() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("unavailable_reason",""))
except Exception: print("")' "$T/out.json" 2>/dev/null; }

echo "=== tester.test.sh — 대조군 스위트"
echo
echo "── A. 폴백(기본은 안 쓴다) ──────────────────────────────────────────"

stub_probe true

R="$T/r-a1"; new_repo "$R" ask; rm -f "$R/.claude/tester/opt-in.json"
rc=$(run_with_mocks "$R")
[ "$rc" = "70" ] && ok "A1 옵트인 없음 → rc 70" || no "A1 옵트인 없음 → rc 70" "실제 rc=$rc"

R="$T/r-a2"; new_repo "$R" off
rc=$(run_with_mocks "$R")
[ "$rc" = "70" ] && ok "A2 enabled=off → rc 70" || no "A2 enabled=off → rc 70" "실제 rc=$rc"

R="$T/r-a3"; new_repo "$R" ask
printf '{"answer":"use","plan_file":"/elsewhere/plan-active.md","plan_fingerprint":"deadbeefdeadbeef"}\n' > "$R/.claude/tester/opt-in.json"
rc=$(run_with_mocks "$R")
[ "$rc" = "70" ] && ok "A3 다른 계획의 옵트인 → rc 70" || no "A3 다른 계획의 옵트인 → rc 70" "실제 rc=$rc"

# 새 축 — 지문이 **없거나 낡으면** 거부한다(리뷰 g1). 경로만으로는 앞 계획의 잔재와
# 구분되지 않아서, 옵트인이 조용히 다음 계획으로 이어지던 자리다.
R="$T/r-a5"; new_repo "$R" ask
printf '{"answer":"use","plan_file":"%s/.claude/plan-active.md"}\n' "$R" > "$R/.claude/tester/opt-in.json"
rc=$(run_with_mocks "$R")
[ "$rc" = "70" ] && ok "A5 지문 없는 옵트인 → rc 70" || no "A5 지문 없는 옵트인 → rc 70" "실제 rc=$rc"
r5=$(reason_of)
case "$r5" in *optin_without_fingerprint*) ok "A5b 사유가 지문 부재를 지목한다" ;; *) no "A5b 사유가 지문 부재를 지목한다" "사유=$r5" ;; esac

R="$T/r-a6"; new_repo "$R" ask
printf '# 계획\n\n- [x] 항목을 닫았다\n' > "$R/.claude/plan-active.md"
rc=$(run_with_mocks "$R")
[ "$rc" = "70" ] && ok "A6 계획이 바뀌면 옵트인이 무효다 → rc 70" || no "A6 계획이 바뀌면 무효" "실제 rc=$rc"
r6=$(reason_of)
case "$r6" in *optin_stale*) ok "A6b 사유가 계획 변경을 지목한다" ;; *) no "A6b 사유가 계획 변경을 지목한다" "사유=$r6" ;; esac

R="$T/r-a7"; new_repo "$R" ask
rc=$(run_with_mocks "$R")
[ "$rc" != "70" ] && ok "A7 대조군 — 지문이 맞으면 통과한다(A5·A6 이 지문을 실제로 본다는 증거)" || no "A7 지문이 맞아도 rc 70" "실제 rc=$rc"

R="$T/r-a4"; new_repo "$R" ask
stub_probe false
rc=$(run_with_mocks "$R")
[ "$rc" = "70" ] && ok "A4 heartbeat 불가 → rc 70" || no "A4 heartbeat 불가 → rc 70" "실제 rc=$rc"
r4=$(reason_of)
case "$r4" in *heartbeat_failed*) ok "A4b 사유가 heartbeat 를 지목한다" ;; *) no "A4b 사유가 heartbeat 를 지목한다" "사유=$r4" ;; esac
stub_probe true

echo
echo "── B. 산출 거부 ────────────────────────────────────────────────────"

R="$T/r-b1"; new_repo "$R"; make_mock "이건 JSON 이 아니다"
rc=$(run_with_mocks "$R")
[ "$rc" = "65" ] && ok "B1 JSON 아닌 산출 → rc 65" || no "B1 JSON 아닌 산출 → rc 65" "실제 rc=$rc"

R="$T/r-b2"; new_repo "$R"; make_mock '{"mode":"full","passed":1}'
rc=$(run_with_mocks "$R")
[ "$rc" = "65" ] && ok "B2 필수 필드 누락 → rc 65" || no "B2 필수 필드 누락 → rc 65" "실제 rc=$rc"

R="$T/r-b3"; new_repo "$R"
make_mock "$(good_result notred)" 'echo "package p" > "$PWD/x_test.go"'
rc=$(run_with_mocks "$R" --mode full)
[ "$rc" = "67" ] && ok "B3 대조군 미발화 → rc 67" || no "B3 대조군 미발화 → rc 67" "실제 rc=$rc"

# 대조군 판정이 **관측 기준**인지 잰다(리뷰 g7) — 자기신고를 비워도 파일이 바뀌면 걸려야 한다.
R="$T/r-b3b"; new_repo "$R"
make_mock "$(good_result_empty)" 'echo "package p" > "$PWD/y_test.go"'
rc=$(run_with_mocks "$R" --mode full)
[ "$rc" = "67" ] && ok "B3b tests_written 을 비워 보고해도 잡힌다(관측 기준)" || no "B3b 자기신고 우회가 뚫린다" "실제 rc=$rc"

R="$T/r-b3c"; new_repo "$R"
make_mock "$(good_result notred)" 'echo "package p" > "$PWD/z_test.go"'
rc=$(run_with_mocks "$R" --mode write)
[ "$rc" = "67" ] && ok "B3c write 모드도 대조군을 요구한다" || no "B3c write 모드 우회가 뚫린다" "실제 rc=$rc"

R="$T/r-b1u"; new_repo "$R"
make_mock 'Failed to authenticate. API Error: 403 litellm.APIError: OpenAIException - {"error":"요청이 보안 정책(jailbreak/prompt-injection)에 의해 차단되었습니다.","by":"fabrix-guard"}'
rc=$(run_with_mocks "$R")
[ "$rc" = "70" ] && ok "B1u ⭐ 업스트림 거부(403 가드) → rc 70 (65 가 아니다)" || no "B1u 업스트림 거부 → rc 70" "실제 rc=$rc"
r1u=$(reason_of)
case "$r1u" in *upstream_rejected*) ok "B1u-b 사유가 업스트림을 지목한다(지시서 탓으로 읽히지 않는다)" ;; *) no "B1u-b 사유가 업스트림을 지목한다" "사유=$r1u" ;; esac

R="$T/r-b1v"; new_repo "$R"; make_mock '이건 그냥 JSON 이 아닌 산문이다'
rc=$(run_with_mocks "$R")
[ "$rc" = "65" ] && ok "B1v ⭐ 대조군 — 업스트림 신호가 **없는** 형식 오류는 그대로 rc 65" || no "B1v 형식 오류는 rc 65" "실제 rc=$rc"

R="$T/r-b4"; new_repo "$R"; make_mock "$(good_result red)" 'echo "// 소스를 고쳤다" >> "$PWD/x.go"'
rc=$(run_with_mocks "$R" --mode full)
[ "$rc" = "66" ] && ok "B4 소스 파일 수정 → rc 66" || no "B4 소스 파일 수정 → rc 66" "실제 rc=$rc"

R="$T/r-b5"; new_repo "$R"; make_mock "$(good_result red)" 'echo "package p" > "$PWD/y_test.go"'
rc=$(run_with_mocks "$R" --mode full)
[ "$rc" = "0" ] && ok "B5 테스트 파일만 수정 → rc 0 (대조군: B4 가 거부되는 것과 대비)" || no "B5 테스트 파일만 수정 → rc 0" "실제 rc=$rc"

echo
echo "── C. 부모 계획 파일 보호 ──────────────────────────────────────────"

R="$T/r-c1"; new_repo "$R"
printf '# 계획\n\n- [ ] 미완료 항목\n' > "$R/.claude/plan-active.md"
write_optin "$R"        # 계획을 바꿨으니 지문도 다시 (규약대로)
before=$(shasum -a 256 "$R/.claude/plan-active.md" | cut -d' ' -f1)
make_mock "$(good_result red)" 'printf "# 비었다\n" > "$PWD/.claude/plan-active.md"'
rc=$(run_with_mocks "$R" --mode full)
after=$(shasum -a 256 "$R/.claude/plan-active.md" | cut -d' ' -f1)
[ "$rc" = "68" ] && ok "C1 자식이 계획 파일을 고치면 → rc 68" || no "C1 자식이 계획 파일을 고치면 → rc 68" "실제 rc=$rc"
[ "$before" = "$after" ] && ok "C1b 계획 파일이 원본으로 복원된다" || no "C1b 계획 파일이 원본으로 복원된다"

# ⭐ 복원은 **덮어쓰기**다 — 되돌리기 전 내용을 남기지 않으면 가드가 지키려던 것을 가드가 삼킨다.
#   2026-09-15 실사용에서 이 경로가 발화했는데 원인이 자식이 아니라 **부모**였다(부모 세션이
#   자식이 도는 동안 계획을 파킹했다). 그때 `.at-exit` 가 없으면 부모의 변경이 사본 없이 사라진다.
guard_dir=$(reason_of "$T/out.json" | sed -n 's/.*보존: \([^ ·]*\).*/\1/p')
if [ -n "$guard_dir" ] && [ -f "$guard_dir/plan.at-exit" ] && grep -q '비었다' "$guard_dir/plan.at-exit" 2>/dev/null; then
  ok "C1c ⭐ 복원 전 내용을 .at-exit 로 보존한다(부모 변경을 삼키지 않는다)"
else
  no "C1c ⭐ 복원 전 내용을 .at-exit 로 보존한다" "guard_dir=$guard_dir"
fi
[ -n "$guard_dir" ] && grep -q '가르지 못한다' "$T/out.json" 2>/dev/null \
  && ok "C1d ⭐ 사유가 자식 탓으로 단정하지 않는다(부모일 수도 있다고 말한다)" \
  || no "C1d ⭐ 사유가 자식 탓으로 단정하지 않는다"

R="$T/r-c2"; new_repo "$R"
printf '# 계획\n\n- [ ] 미완료 항목\n' > "$R/.claude/plan-active.md"
write_optin "$R"
make_mock "$(good_result red)"
rc=$(run_with_mocks "$R" --mode full)
[ "$rc" = "0" ] && ok "C2 계획 파일을 안 고치면 통과 (C1 의 대조군)" || no "C2 계획 파일을 안 고치면 통과" "실제 rc=$rc"

echo
echo "── D. 쓰기 범위 검사가 **살아 있는가** ─────────────────────────────"

R="$T/r-d1"; mkdir -p "$T/r-d1/.claude/tester"
printf '{"enabled":"ask","endpoint":"http://127.0.0.1:1/v1","model":"m"}\n' > "$R/.claude/tester/config.json"
printf 'task\n' > "$R/task.txt"; echo "package p" > "$R/x.go"
write_optin "$R"
make_mock "$(good_result red)" 'echo "// 고쳤다" >> "$PWD/x.go"'
rc=$(run_with_mocks "$R" --mode full)
[ "$rc" = "66" ] && ok "D1 git 아닌 디렉토리에서도 소스 수정을 잡는다" || no "D1 git 아닌 디렉토리에서도 소스 수정을 잡는다" "실제 rc=$rc (fail-open 이면 0 이 나온다)"

echo
echo "── E. 세마포어 ─────────────────────────────────────────────────────"
. "$SELF/_sem.sh"
SEM_DIR="$T/sem"
if sem_acquire 1 2; then
  s1="$SEM_SLOT"
  ( SEM_DIR="$T/sem"; . "$SELF/_sem.sh"; SEM_DIR="$T/sem"; sem_acquire 1 2 ) && second=0 || second=1
  [ "$second" = "1" ] && ok "E1 상한 1 에서 두 번째 획득이 대기 후 실패한다" || no "E1 상한 1 에서 두 번째 획득이 대기 후 실패한다"
  SEM_SLOT="$s1"; sem_release
  sem_acquire 1 2 && { ok "E2 반납 후 다시 획득된다"; sem_release; } || no "E2 반납 후 다시 획득된다"
else
  no "E1/E2 세마포어 첫 획득 실패"
fi

echo
echo "── F. 키가 코드에 없는가 ───────────────────────────────────────────"
# ⚠ 접두사 패턴(`fbx_…`)으로 세지 마라 — 키를 **다루는** 코드가 그 접두사를 정상적으로 쓴다.
#   실측: fabrix 레포에 33건이 있었고 전부 키 파싱 로직과 테스트 픽스처였다(실제 키는 0건).
#   접두사를 세면 그 레포에서 이 검사는 영영 붉고, 붉은 검사는 곧 꺼진다.
#   ⇒ **실제 키 값**이 어딘가에 적혔는지만 본다. 값은 키 파일에서 읽어 비교하고 출력하지 않는다.
ENVF="$HOME/.config/go-skill/tester.env"
if [ -f "$ENVF" ]; then
  realkey=$(grep -m1 '^GO_TESTER_API_KEY=' "$ENVF" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' \r\n')
  if [ -n "$realkey" ]; then
    roots="/Users/woojin/개발/go-skill"
    [ -n "${CLAUDE_PROJECT_DIR:-}" ] && roots="$roots $CLAUDE_PROJECT_DIR"
    leak=0
    for r in $roots; do
      n=$(grep -rlF "$realkey" "$r" 2>/dev/null | grep -v '/\.git/' | wc -l | tr -d ' ')
      leak=$((leak + n))
    done
    [ "$leak" = "0" ] && ok "F1 ⭐ **실제 키 값**이 레포에 0건(접두사가 아니라 값으로 센다)" \
                      || no "F1 실제 키 값이 레포에 있다" "$leak 개 파일"
  else
    skip "F1 키 파일에 GO_TESTER_API_KEY 가 없어 값 대조를 못 했다(미검사이지 통과가 아니다)"
  fi
else
  skip "F1 키 파일이 없어 값 대조를 못 했다(미검사이지 통과가 아니다)"
fi
# 대조군 — 검사기가 살아 있는가: 임시 파일에 키를 넣으면 잡혀야 한다.
if [ -f "$ENVF" ] && [ -n "${realkey:-}" ]; then
  probe_dir="$T/leakprobe"; mkdir -p "$probe_dir"
  printf 'key=%s\n' "$realkey" > "$probe_dir/leak.txt"
  n=$(grep -rlF "$realkey" "$probe_dir" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "1" ] && ok "F2 ⭐ 대조군 — 키를 일부러 심으면 탐지기가 잡는다" || no "F2 대조군 — 심은 키를 못 잡는다"
  rm -rf "$probe_dir"
fi

echo
echo "── G. 대조군 스크립트 ──────────────────────────────────────────────"
R="$T/r-g1"; new_repo "$R"
cat > "$R/calc.go" <<'EOF'
package p

func Add(a, b int) int { return a + b }
EOF
cat > "$R/calc_test.go" <<'EOF'
package p

import "testing"

func TestAdd(t *testing.T) {
	if Add(2, 3) != 5 {
		t.Fatal("Add(2,3) != 5")
	}
}
EOF
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m calc
out=$(bash "$SELF/controlgroup.sh" --repo "$R" --file calc.go --sed 's/a + b/a - b/' --gate 'go test ./... -count=1' 2>/dev/null)
red=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("went_red"))' 2>/dev/null)
[ "$red" = "True" ] && ok "G1 보호를 깨면 대조군이 발화한다" || no "G1 보호를 깨면 대조군이 발화한다" "산출=$out"

out=$(bash "$SELF/controlgroup.sh" --repo "$R" --file calc.go --sed 's/^\/\/ nothing$/\/\/ nothing/' --gate 'go test ./... -count=1' 2>/dev/null)
red=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("went_red"))' 2>/dev/null)
[ "$red" = "False" ] && ok "G2 변이가 0 이면 발화하지 않는다(거짓 양성 방지)" || no "G2 변이가 0 이면 발화하지 않는다" "산출=$out"

wt=$(git -C "$R" worktree list | wc -l | tr -d ' ')
[ "$wt" = "1" ] && ok "G3 대조군 뒤 임시 워크트리 잔존 0" || no "G3 대조군 뒤 임시 워크트리 잔존 0" "워크트리 $wt 개"

# ⭐⭐ G4 — **다중 모듈 + 복합 게이트**. G1~G3 이 못 보던 자리다(2026-09-15 실측으로 드러났다).
#   G1 의 픽스처는 루트에 go.mod 가 있고 게이트가 낱말 하나짜리라, 종전 코드의
#   `eval "timeout $TMO $GATE"` 버그가 드러나지 않았다. 게이트가 `cd sub && ...` 이면
#   `timeout` 이 **첫 낱말 `cd` 에만** 붙고, macOS 에는 `/usr/bin/cd` 가 실제로 있어서
#   그 호출이 조용히 rc 0 을 낸 뒤 뒤 명령이 **워크트리 루트**에서 돈다 ⇒ 늘 거짓 음성.
#   이 레포군의 게이트는 전부 `cd backend && ...`·`cd web && ...` 라 그 조건이 상시였다.
R="$T/r-g4"; rm -rf "$R"; mkdir -p "$R/sub"
git -C "$R" init -q; git -C "$R" config user.email t@example.com; git -C "$R" config user.name t
printf 'module p\n\ngo 1.22\n' > "$R/sub/go.mod"
cat > "$R/sub/calc.go" <<'EOF'
package p

func Add(a, b int) int { return a + b }
EOF
cat > "$R/sub/calc_test.go" <<'EOF'
package p

import "testing"

func TestAdd(t *testing.T) {
	if Add(2, 3) != 5 {
		t.Fatal("Add(2,3) != 5")
	}
}
EOF
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m sub
out=$(bash "$SELF/controlgroup.sh" --repo "$R" --file sub/calc.go --sed 's/a + b/a - b/' --gate 'cd sub && go test ./... -count=1' 2>/dev/null)
red=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("went_red"))' 2>/dev/null)
clean=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("gate_rc_clean"))' 2>/dev/null)
[ "$red" = "True" ] && ok "G4 ⭐⭐ 복합 게이트(cd sub && ...) + 하위 모듈에서도 발화한다" \
  || no "G4 ⭐⭐ 복합 게이트 + 하위 모듈에서도 발화한다" "산출=$out"
[ "$clean" = "0" ] && ok "G4b 깨끗한 상태의 게이트가 실제로 통과한다(0 이 아니면 대조군이 성립조차 못 한다)" \
  || no "G4b 깨끗한 상태의 게이트가 실제로 통과한다" "gate_rc_clean=$clean"

# ⭐ G5 — 게이트가 **원본 레포의 절대경로**를 품으면 거부한다.
#   그런 게이트는 워크트리 안에서 실행해도 `cd /절대/경로` 로 밖으로 되돌아가 원본을 잰다.
#   변이는 사본에만 있으므로 늘 초록이 나오고, 읽는 사람은 「테스트가 안 잠근다」로 읽는다.
out=$(bash "$SELF/controlgroup.sh" --repo "$R" --file sub/calc.go --sed 's/a + b/a - b/' --gate "cd $R/sub && go test ./... -count=1" 2>/dev/null)
rc=$?
red=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("went_red"))' 2>/dev/null)
printf '%s' "$out" | grep -q '절대경로' && [ "$red" = "False" ] \
  && ok "G5 ⭐ 절대경로 게이트를 거부한다(거짓 음성을 원천에서 막는다)" \
  || no "G5 ⭐ 절대경로 게이트를 거부한다" "산출=$out"

wt=$(git -C "$R" worktree list | wc -l | tr -d ' ')
[ "$wt" = "1" ] && ok "G6 G4·G5 뒤에도 워크트리 잔존 0" || no "G6 G4·G5 뒤에도 워크트리 잔존 0" "워크트리 $wt 개"

echo
echo "── H. 실모델(--live 일 때만) ───────────────────────────────────────"
if [ "$LIVE" = "1" ]; then
  echo "  (live 검사는 P3 실사용에서 돈다 — 여기서는 구성만 확인한다)"
  bash "$SELF/probe.sh" --for-plan >/dev/null 2>&1 && ok "H1 heartbeat 통과" || skip "H1 heartbeat 불가(환경)"
else
  skip "H1 실모델 검사(--live 로 실행하면 돈다)"
fi

echo
TOTAL=$((PASS + FAIL + SKIP))
printf '[tester 대조군] %d검사 · 통과 %d · 실패 %d · 건너뜀 %d\n' "$TOTAL" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
