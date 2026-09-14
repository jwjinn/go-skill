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

new_repo() { # new_repo <경로> [enabled] — git 레포 + 구성 + 옵트인
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
  printf '{"answer":"use","plan_file":"%s/.claude/plan-active.md"}\n' "$r" > "$r/.claude/tester/opt-in.json"
  printf 'do something\n' > "$r/task.txt"
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
printf '{"answer":"use","plan_file":"/elsewhere/plan-active.md"}\n' > "$R/.claude/tester/opt-in.json"
rc=$(run_with_mocks "$R")
[ "$rc" = "70" ] && ok "A3 다른 계획의 옵트인 → rc 70" || no "A3 다른 계획의 옵트인 → rc 70" "실제 rc=$rc"

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

R="$T/r-b3"; new_repo "$R"; make_mock "$(good_result notred)"
rc=$(run_with_mocks "$R" --mode full)
[ "$rc" = "67" ] && ok "B3 대조군 미발화 → rc 67" || no "B3 대조군 미발화 → rc 67" "실제 rc=$rc"

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
before=$(shasum -a 256 "$R/.claude/plan-active.md" | cut -d' ' -f1)
make_mock "$(good_result red)" 'printf "# 비었다\n" > "$PWD/.claude/plan-active.md"'
rc=$(run_with_mocks "$R" --mode full)
after=$(shasum -a 256 "$R/.claude/plan-active.md" | cut -d' ' -f1)
[ "$rc" = "68" ] && ok "C1 자식이 계획 파일을 고치면 → rc 68" || no "C1 자식이 계획 파일을 고치면 → rc 68" "실제 rc=$rc"
[ "$before" = "$after" ] && ok "C1b 계획 파일이 원본으로 복원된다" || no "C1b 계획 파일이 원본으로 복원된다"

R="$T/r-c2"; new_repo "$R"
printf '# 계획\n\n- [ ] 미완료 항목\n' > "$R/.claude/plan-active.md"
make_mock "$(good_result red)"
rc=$(run_with_mocks "$R" --mode full)
[ "$rc" = "0" ] && ok "C2 계획 파일을 안 고치면 통과 (C1 의 대조군)" || no "C2 계획 파일을 안 고치면 통과" "실제 rc=$rc"

echo
echo "── D. 쓰기 범위 검사가 **살아 있는가** ─────────────────────────────"

R="$T/r-d1"; mkdir -p "$T/r-d1/.claude/tester"
printf '{"enabled":"ask","endpoint":"http://127.0.0.1:1/v1","model":"m"}\n' > "$R/.claude/tester/config.json"
printf '{"answer":"use","plan_file":"%s/.claude/plan-active.md"}\n' "$R" > "$R/.claude/tester/opt-in.json"
printf 'task\n' > "$R/task.txt"; echo "package p" > "$R/x.go"
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
leak=$(grep -rn 'fbx_[A-Za-z0-9]' /Users/woojin/개발/go-skill 2>/dev/null | grep -v '\.git/' | wc -l | tr -d ' ')
[ "$leak" = "0" ] && ok "F1 go-skill 에 API 키 문자열 0건" || no "F1 go-skill 에 API 키 문자열 0건" "$leak 건 발견"

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
