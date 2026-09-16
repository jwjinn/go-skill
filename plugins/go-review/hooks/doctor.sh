#!/usr/bin/env bash
# doctor.sh — ⭐ **체인이 살아 있는지 세션 시작에 증명한다.**
#
# 왜 있나(2026-09-03): 이 체인의 결함 넷이 전부 **실사용 중 우연히** 발견됐다 —
#   ① 낡음 판별이 마지막 발화를 봐서 게이트가 만든 턴에만 무장(3일 무장해제)
#   ② 훅이 ambient 경로를 믿어 워크트리의 계획을 못 보고 조용히 통과
#   ③ codex 읽기 전용이 플래그 하나에 얹혀 있었다(빼먹으면 리뷰어가 코드를 고친다)
#   ④ 정본이 둘인데 **양쪽 테스트가 다 초록**이라 갈라짐 자체를 아무도 못 봤다
# 넷의 공통점: **체인이 자기 생존을 증명하는 절차가 없었다.** 이 스크립트가 그 자리다.
#
# ⚠ 초록 한 줄로 끝내지 않는다 — **무엇을 몇 개 셌는지** 말한다. 「그 축을 아예 안 봤다」가
#   이 레포의 반복 함정이고, 개수가 없으면 그것을 구분할 수 없다.
#
# 사용:  bash <플러그인>/hooks/doctor.sh            # 사람이 읽는 형태
#        bash <플러그인>/hooks/doctor.sh --hook     # SessionStart 훅(JSON 한 줄)
# 종료코드: 0 전부 통과 · 1 경고 있음 · 2 ⛔ 결함 있음
set -u
SELF=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
HOOKJSON="$SELF/hooks.json"
MODE="${1:-}"

ok=0; warn=0; bad=0
LINES=""
say() { LINES="${LINES}$1
"; }
pass() { ok=$((ok+1)); say "  ✅ $1"; }
warns(){ warn=$((warn+1)); say "  ⚠  $1"; }
fails(){ bad=$((bad+1)); say "  ⛔ $1"; }

# ── ① 훅이 **정확히 한 번** 등록됐나 (2중 등록 탐지) ────────────────────────
# 정본이 둘이면 게이트가 두 번 돌고 에이전트 이름이 충돌한다. 그리고 그 상태는 조용하다.
names="go-precheck goal-echo plan-file-gate review-gate todo-completion-gate"
dupes=""; missing=""
for n in $names; do
  inplug=0; inproj=0
  grep -q "$n" "$HOOKJSON" 2>/dev/null && inplug=1
  if [ -f "$ROOT/.claude/settings.json" ]; then
    grep -q "hooks/$n" "$ROOT/.claude/settings.json" 2>/dev/null && inproj=1
  fi
  total=$((inplug + inproj))
  [ "$total" -ge 2 ] && dupes="$dupes $n"
  [ "$total" -eq 0 ] && missing="$missing $n"
done
if [ -n "$dupes" ]; then
  fails "훅 2중 등록:${dupes} — 플러그인과 프로젝트 settings.json 양쪽에 있다. 게이트가 두 번 돈다"
elif [ -n "$missing" ]; then
  fails "훅 미등록:${missing} — 그 축은 **아예 무장되지 않았다**"
else
  # ⚠ **범위를 밝힌다** — 마켓플레이스 설치본·사용자 레벨 settings.json 은 보지 않는다.
  #   「2중 0」이라 단언하면 그 경로의 2중 등록을 매 세션 「없음」으로 확인해 주는 셈이 된다.
  pass "훅 등록 5/5 · 이 범위(플러그인 hooks.json + 프로젝트 settings.json)에서 각각 1회"
fi

# ── ② 로컬 사본이 없나 (드리프트 탐지) ──────────────────────────────────────
# 프로젝트에 플러그인과 **같은 이름**의 파일이 있으면 어느 것이 도는지 결정적이지 않고,
# 고침이 한쪽에만 붙는다. 실제로 그렇게 됐다(2026-09-03).
copies=""
for d in commands agents hooks review; do
  [ -d "$ROOT/.claude/$d" ] || continue
  for f in "$ROOT/.claude/$d"/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    [ -f "$SELF/../$d/$b" ] && copies="$copies $d/$b"
  done
done
# ⭐ **형제 플러그인의 훅도 본다**(2026-09-16). go-fanout 의 게이트가 프로젝트로 복사돼 정본이
#   둘이 된 적이 있다 — 그 사본은 워커 워크트리로 그대로 퍼지고, 고칠 때 한쪽만 고치면 다음
#   레포가 낡은 것을 받는다. 이름이 go-review 것이 아니라서 위 대조에 걸리지 않았다.
#   ⚠ 설치돼 있을 때만 대조한다(미설치를 결함으로 말하지 않는다 — go-fanout 은 선택이다).
. "$SELF/_plugins.sh" 2>/dev/null || true
if command -v sibling_plugin >/dev/null 2>&1 && [ -d "$ROOT/.claude/hooks" ]; then
  _gf=$(sibling_plugin go-fanout hooks/hooks.json 2>/dev/null || printf '')
  if [ -n "$_gf" ]; then
    for f in "$ROOT/.claude/hooks"/*; do
      [ -f "$f" ] || continue
      b=$(basename "$f")
      [ -f "$_gf/hooks/$b" ] && copies="$copies hooks/$b(go-fanout)"
    done
  fi
fi
if [ -n "$copies" ]; then
  fails "플러그인과 같은 이름의 로컬 사본:${copies} — 정본이 둘이다. 지우고 플러그인만 남겨라"
else
  pass "로컬 사본 0개(commands·agents·hooks·review 대조)"
fi

# ── ③ codex 가 있나 ─────────────────────────────────────────────────────────
# 기본 preset P2 는 **전 자리가 codex** 다 — 없으면 「강등」이 아니라 리뷰가 **아예 없다**.
if command -v codex >/dev/null 2>&1; then
  pass "codex $(codex --version 2>/dev/null | head -1 | tr -d '\n')"
else
  warns "codex 없음 — preset P2 는 전 자리가 codex 다. 리뷰가 아예 없게 된다(P1 으로 내려라)"
fi

# ── ④ 어느 리뷰 구성이 도나 ─────────────────────────────────────────────────
cfg=$(python3 "$SELF/../review/_config.py" 2>/dev/null | grep -E '^(구성|preset|읽은)' | head -2)
pre=$(python3 "$SELF/../review/_config.py" 2>/dev/null | grep -oE 'CLAUDE_REVIEW_REVIEWERS=[^ ]*' | head -1)
if [ -n "$pre" ]; then
  pass "리뷰 구성: ${pre#CLAUDE_REVIEW_REVIEWERS=}"
else
  warns "리뷰 구성을 읽지 못했다 — _config.py 를 직접 돌려 확인해라"
fi

# ── ⑤ 계획 파일의 소유자가 이 워크트리인가 ──────────────────────────────────
. "$SELF/_planpath.sh" 2>/dev/null || true
plan="${CLAUDE_PLAN_FILE:-$ROOT/.claude/plan-active.md}"
if [ ! -f "$plan" ]; then
  pass "활성 계획 없음(완주 게이트는 계획이 생기면 무장된다)"
else
  left=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[[^xX]\]' "$plan" 2>/dev/null || printf '0')
  case "$left" in ''|*[!0-9]*) left=0 ;; esac
  owner=''
  command -v plan_owner_of >/dev/null 2>&1 && owner=$(plan_owner_of "$plan")
  if [ -n "$owner" ] && [ "$owner" != "$ROOT" ]; then
    fails "활성 계획의 작업 위치가 다르다($owner ≠ $ROOT) — 남의 계획일 수 있고, 그 상태에서는 이 세션의 완주 게이트가 남의 것을 본다"
  else
    pass "활성 계획 소유자 일치 · 미완료 ${left}개"
  fi
fi

# ── ⑥ 미해결 리뷰가 남아 있나 ───────────────────────────────────────────────
rev="${CLAUDE_REVIEW_FILE:-$ROOT/.claude/review-active.md}"
if [ -f "$rev" ]; then
  rleft=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[[^xX]\]' "$rev" 2>/dev/null || printf '0')
  case "$rleft" in ''|*[!0-9]*) rleft=0 ;; esac
  if [ "$rleft" -gt 0 ]; then
    warns "미해결 리뷰 지적 ${rleft}건이 남아 있다($rev) — 이번 세션이 그것부터 닫아야 할 수 있다"
  else
    pass "리뷰 반영 파일 있음 · 미해결 0(닫고 지워도 된다)"
  fi
else
  pass "미해결 리뷰 없음"
fi

# ── ⑦ 게이트 테스트가 최근에 통과했나 ───────────────────────────────────────
# ⚠ 여기서 테스트를 **돌리지 않는다** — 세션 시작마다 전 스위트를 돌리면 사람이 훅을 끈다.
#   대신 스탬프를 본다. 스탬프는 `doctor.sh --stamp` 또는 테스트를 돌린 쪽이 남긴다.
# ⚠ 스탬프는 **자기신고**다 — 여기서 테스트를 돌리지 않으므로 「통과했다」가 아니라
#   「누군가 통과했다고 표시했다」가 참이다. 레포별로 나눈다(전역 하나면 다른 레포에서 찍은
#   것이 여기서 통과로 읽힌다 — 2026-09-03 리뷰가 지목).
suites=$(ls "$SELF"/*.test.sh "$SELF/../review"/*.test.sh "$SELF/../review/eval"/*.test.sh "$SELF/../scripts"/*.test.sh 2>/dev/null | wc -l | tr -d ' ')
case "${suites:-x}" in ''|*[!0-9]*) suites='?' ;; esac
repokey=$(printf '%s' "$ROOT" | cksum 2>/dev/null | cut -d' ' -f1)
stamp="${TMPDIR:-/tmp}/claude-go-suites-ok-${repokey:-x}"
if [ "$MODE" = "--stamp" ]; then date +%s > "$stamp" 2>/dev/null; fi
if [ -f "$stamp" ]; then
  st=$(cat "$stamp" 2>/dev/null); now=$(date +%s 2>/dev/null || printf '0')
  case "${st:-x}" in ''|*[!0-9]*) st=0 ;; esac
  age=$(( (now - st) / 3600 ))
  if [ "$age" -le 24 ]; then pass "게이트 ${suites}스위트 — **통과했다는 표시**가 ${age}시간 전(자기신고이지 이 도구의 확인이 아니다)"
  else warns "게이트 통과 표시가 ${age}시간 전이다 — ${suites}스위트를 오늘 한 번 돌려라"; fi
else
  warns "게이트 통과 표시 없음 — ${suites}스위트를 한 번 돌리고 \`doctor.sh --stamp\` 로 표시해라"
fi

# ── ⑧ 이 체인을 무엇으로 부르나 ─────────────────────────────────────────────
# ⭐ 관찰 O-1(2026-09-03): 문서는 전부 `/go` 라고 안내하는데 실제로는 없었다 —
#   이관으로 로컬 명령이 사라지고 플러그인 **스킬**로 로드되면 이름이 달라진다.
#   사용자가 안내대로 쳤는데 아무 일도 일어나지 않았다. 그래서 이름을 여기서 말한다.
if [ -f "$ROOT/.claude/commands/go.md" ]; then
  pass "호출: /go (이 프로젝트의 로컬 명령)"
elif [ -d "$SELF/../commands" ]; then
  pass "호출: go-review:go · go-review:plan · go-review:review-loop (플러그인 스킬 — \`/go\` 는 없다)"
else
  fails "이 체인을 부를 방법을 찾지 못했다 — commands 디렉토리가 어디에도 없다"
fi

# ── ⑨ 외부 도구가 다 있나 ───────────────────────────────────────────────────
#
# ⭐⭐ **「설치했다」와 「돌아간다」는 다르다.** 이 체인은 jq·python3·git 위에 서 있고,
#   그중 jq 가 없으면 위 ①에서 「등록 5/5」로 확인한 그 훅들이 **붙어 있는 채로 아무것도
#   보지 않는다**(재현 기록은 `_deps.sh` 머리말). 등록 확인만으로는 그 상태를 구분할 수 없다.
# ⚠ 여기서는 **있는지만** 본다. codex 가 실제로 도는지는 `scripts/deps-check.sh --deep` 이다 —
#   느린 검사를 세션 시작에 넣으면 사람이 훅을 끈다.
. "$SELF/_deps.sh" 2>/dev/null || true
if command -v deps_missing >/dev/null 2>&1; then
  req_all=$(deps_required_list)
  req_n=$(printf '%s' "$req_all" | wc -w | tr -d ' ')
  miss_req=$(deps_missing "$req_all")
  if [ -n "$miss_req" ]; then
    miss_n=$(printf '%s' "$miss_req" | wc -w | tr -d ' ')
    fails "필수 도구 부재 ${miss_n}개:${miss_req} — 그 축은 붙어 있는 채로 아무것도 보지 않는다(bash scripts/deps-check.sh)"
  else
    pass "필수 도구 ${req_n}/${req_n}($(printf '%s' "$req_all" | tr ' ' '·'))"
  fi
  miss_opt=''
  command -v codex >/dev/null 2>&1 || miss_opt="$miss_opt codex"
  [ -n "$(deps_timeout_cmd)" ] || miss_opt="$miss_opt timeout"
  # ⚠ codex 부재는 위 ③ 이 이미 말한다 — 여기서는 timeout 만 덧붙인다(같은 말을 두 번 하지 않는다).
  case "$miss_opt" in
    *timeout*) warns "timeout·gtimeout 이 없다 — codex 호출에 시간 상한이 걸리지 않는다(brew install coreutils)" ;;
  esac
else
  warns "_deps.sh 를 읽지 못했다 — 의존성 축을 **재지 못했다**(미검사이지 통과가 아니다)"
fi

# ── 출력 ────────────────────────────────────────────────────────────────────
total=$((ok + warn + bad))
head="[go 체인 진단] ${total}검사 · 통과 ${ok} · 경고 ${warn} · 결함 ${bad}"
if [ "$MODE" = "--hook" ]; then
  [ "$bad" -eq 0 ] && [ "$warn" -eq 0 ] && exit 0    # 전부 통과면 조용히(소음이면 사람이 끈다)
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$head" "$LINES" <<'PY' 2>/dev/null
import json,sys
print(json.dumps({"systemMessage": sys.argv[1] + "\n" + sys.argv[2]}, ensure_ascii=False))
PY
  elif command -v deps_json_escape >/dev/null 2>&1; then
    # ⚠⚠ python3 가 없을 때가 **가장 말해야 할 때**인데, 종전에는 그 조건에서 출력이 0바이트였다
    #   (알리는 코드가 알려야 할 도구를 요구했다). jq 도 python3 도 없이 JSON 을 만든다.
    printf '{"systemMessage":"%s"}\n' "$(deps_json_escape "$head
$LINES")"
  fi
  exit 0
fi
printf '%s\n%s' "$head" "$LINES"
[ "$bad" -gt 0 ] && exit 2
[ "$warn" -gt 0 ] && exit 1
exit 0
