#!/usr/bin/env bash
# coder.sh — 구현 위임의 **유일한 입구**. 로컬 모델에 붙은 codex 프로세스에 넘긴다.
#
# 용법:
#   coder.sh --task <지시서 파일> --targets '<경로,경로>' --gate '<게이트 명령>' \
#            [--cwd <레포>] [--out <결과.json>] [--label <원장 이름>]
#
# ⭐ 형제인 go-tester 와 통제 철학은 같고 **대조군의 방향이 반대**다:
#     테스트 위임 — 「보호를 지우면 붉어지나」(rc 67 = 대조군 미관측)
#     구현 위임   — 「착수 전에 그 테스트가 실제로 붉었나」(rc 67 = 고칠 것이 없다)
#   고칠 것이 없는 상태에서 시작하면 「고쳤다」를 판정할 방법이 없다. 그것이 이 도구가
#   근거 없는 성공 주장을 막는 자리다.
#
# 종료 코드:
#   0   성공 — 대상 파일만 바뀌었고 게이트가 초록이다
#   64  사용법 오류
#   65  결과 JSON 이 없거나 스키마에 안 맞는다
#   66  대상 파일 **밖**을 고쳤다(자식이 새로 만든 것은 되돌린다)
#   67  착수 전 게이트가 **이미 초록**이다 — 고칠 것이 없으면 고쳤다고 판정할 수 없다
#   68  부모의 **계획 파일**을 건드렸다(복원한다). ⛔ 통제가 깨진 것이니 사람에게 말해라
#   69  완료 후 게이트가 **붉다**
#   70  설계된 **폴백** — 안 켜졌거나·codex 가 없거나·프로파일이 없거나·파일 수가 상한을 넘는다
#
# ⚠ rc 70 은 실패가 아니다. 그때는 세션이 직접 구현하고 그 사유를 종료 보고에 남긴다.
set -uo pipefail

SELF="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
TASK=""; TARGETS=""; GATE=""; CWD=""; OUT=""; LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --task)    TASK="${2:-}";    shift 2 ;;
    --targets) TARGETS="${2:-}"; shift 2 ;;
    --gate)    GATE="${2:-}";    shift 2 ;;
    --cwd)     CWD="${2:-}";     shift 2 ;;
    --out)     OUT="${2:-}";     shift 2 ;;
    --label)   LABEL="${2:-}";   shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "coder.sh: 모르는 인자 '$1'" >&2; exit 64 ;;
  esac
done

CWD="${CWD:-${CLAUDE_PROJECT_DIR:-$PWD}}"
OUT="${OUT:-${TMPDIR:-/tmp}/go-coder-out.$$.json}"
LABEL="${LABEL:-$(date +%Y%m%d-%H%M%S)}"

# ⚠ 모르는 인자를 조용히 무시하지 않듯, **빠진 인자도 조용히 넘기지 않는다.**
#   특히 --targets 가 비면 「아무 파일이나 고쳐도 된다」가 되어 통제 ①이 통째로 꺼진다.
[ -n "$TASK" ]    || { echo "coder.sh: --task <지시서 파일> 이 필요하다" >&2; exit 64; }
[ -f "$TASK" ]    || { echo "coder.sh: 지시서가 없다: $TASK" >&2; exit 64; }
[ -n "$TARGETS" ] || { echo "coder.sh: --targets 가 필요하다 — 비우면 쓰기 범위 통제가 꺼진다" >&2; exit 64; }
[ -n "$GATE" ]    || { echo "coder.sh: --gate 가 필요하다 — 게이트 없이는 착수 전/후를 가를 수 없다" >&2; exit 64; }

# ── 결과 JSON 을 내고 끝내는 공통 경로 ────────────────────────────────────────
emit() { # emit <rc> <사유> [요약]
  python3 - "$OUT" "$1" "$2" "${3:-}" <<'PY' 2>/dev/null || true
import io, json, sys
out, rc, why, summary = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
json.dump({"rc": rc, "reason": why, "summary": summary},
          io.open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  # ⭐⭐ **실패했으면 자식 로그를 남긴다.** 첫 실물 실행(2026-09-16)에서 rc 69 가 났는데
  #   `trap rm -rf "$SNAP"` 이 로그를 먼저 지워 **원인을 볼 수 없었다.** 「자식이 아무것도
  #   안 고쳤다」까지는 알았지만 왜인지는 알 방법이 없었다 — 도구가 자기 실패를 진단 불가로
  #   만든 자리다. 프롬프트도 함께 남긴다(무엇을 줬는지가 원인의 절반이다).
  if [ -n "${SNAP:-}" ] && [ -d "${SNAP:-}" ]; then
    for _f in child.log prompt.md child.json; do
      [ -f "$SNAP/$_f" ] && cp "$SNAP/$_f" "${OUT%.json}.$_f" 2>/dev/null || true
    done
    printf '   ↳ 자식 로그: %s.child.log · 프롬프트: %s.prompt.md\n' "${OUT%.json}" "${OUT%.json}" >&2
  fi
  printf '%s\n' "$2" >&2
}

ledger() { # ledger <rc> <사유> <착수전게이트rc> <완료후게이트rc> <왕복> <소요초> <파일수>
  [ -n "${CODER_LEDGER:-}" ] || return 0
  lp="$CWD/$CODER_LEDGER"
  mkdir -p "$(dirname -- "$lp")" 2>/dev/null || return 0
  python3 - "$lp" "$LABEL" "${CODER_PROFILE:-}" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$TARGETS" "$GATE" <<'PY' 2>/dev/null || true
import io, json, sys, datetime
(lp, label, profile, rc, why, g_before, g_after, rounds, secs, nfiles, targets, gate) = sys.argv[1:13]
row = {
    "at": datetime.datetime.now().isoformat(timespec="seconds"),
    "label": label, "profile": profile,
    "rc": int(rc), "reason": why,
    # ⭐ 착수 전/후 게이트를 **둘 다** 남긴다. 앞이 붉고 뒤가 초록인 것이 이 위임의 증거이고,
    #   앞이 초록이었으면 그 호출은 애초에 판정 불가였다(rc 67).
    "gate_rc_before": int(g_before), "gate_rc_after": int(g_after),
    # ⭐⭐ 아래 셋이 「성능이 좋은지」를 나중에 재는 유일한 근거다. 같은 항목을 세션 모델로
    #   돌린 것과 대조하려면 이 값들이 있어야 한다(보고서 「다음 실행에서 고칠 점」과 같은 방향).
    "rounds": int(rounds), "elapsed_sec": int(secs), "files": int(nfiles),
    "targets": targets, "gate": gate,
}
with io.open(lp, "a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
}

# ── ① 구성 — 켤 수 있나 ───────────────────────────────────────────────────────
CFG="$(CLAUDE_PROJECT_DIR="$CWD" python3 "$SELF/_config.py" 2>/dev/null)" || CFG=""
eval "$(printf '%s\n' "$CFG" | grep -E '^CODER_[A-Z_]+=')" 2>/dev/null || true
if [ "${CODER_ENABLED:-0}" != "1" ]; then
  emit 70 "fallback: ${CODER_REASON:-구성을 읽지 못했다}"
  ledger 70 "${CODER_REASON:-no_config}" -1 -1 0 0 0
  exit 70
fi

# ── ② 대상 파일 — 목록을 검증한다 ────────────────────────────────────────────
# ⚠ 목록은 **계획 항목이 선언한 것**이고 자식이 정하지 않는다. 자식이 정하면 그 범위는
#   승인된 범위가 아니다.
OLDIFS="$IFS"; IFS=','; set -- $TARGETS; IFS="$OLDIFS"
NFILES=$#
TLIST=""
for t in "$@"; do
  t="$(printf '%s' "$t" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$t" ] || continue
  case "$t" in
    # ⚠ 백틱을 큰따옴표 안에 그대로 쓰면 **명령 치환**으로 평가된다(2026-09-16 리뷰).
    #   그러면 `..` 가 실행돼 stderr 에 command not found 가 섞이고 사유 문구에서 그 조각이 사라진다.
    /*|*..*) emit 64 "대상 경로는 레포 상대경로여야 한다(절대경로·'..' 금지): $t"; exit 64 ;;
  esac
  TLIST="$TLIST$t
"
done
NFILES=$(printf '%s' "$TLIST" | grep -c . 2>/dev/null || printf '0')
[ "$NFILES" -gt 0 ] || { emit 64 "--targets 를 해석하지 못했다: $TARGETS"; exit 64; }
if [ "$NFILES" -gt "${CODER_MAX_FILES:-2}" ]; then
  # ⭐ 실패가 아니라 **측정된 범위 밖**이다. 이 위임의 근거가 된 벤치마크는 파일 한두 개만 쟀다.
  emit 70 "fallback: 대상 파일 $NFILES 개 > 상한 ${CODER_MAX_FILES:-2} — 여러 파일에 걸친 변경은 측정되지 않았다"
  ledger 70 "over_max_files($NFILES)" -1 -1 0 0 "$NFILES"
  exit 70
fi

# ── ③ 착수 전 게이트 — **붉어야 한다** ───────────────────────────────────────
# ⭐⭐ 이것이 go-tester 의 rc 67(대조군 미관측)에 대응하는 자리다.
#   고칠 것이 없는 상태에서 시작하면 「고쳤다」를 판정할 방법이 없다. 그러면 자식이
#   아무것도 안 해도 「게이트 초록」이 나오고 그것이 성공으로 기록된다.
# ⚠ `bash -c` 로 통째 실행한다 — `timeout N <복합 명령>` 은 timeout 이 **첫 낱말에만**
#   붙어서, macOS 처럼 `/usr/bin/cd` 가 실제로 있는 환경에서는 `timeout 600 cd web` 이
#   조용히 rc 0 을 내고 뒤 명령이 엉뚱한 자리에서 돈다(go-tester 가 실측으로 밟은 함정).
# ⚠ `timeout` 이 없는 환경이 있다(BSD 기본 · coreutils 미설치 맥). 없으면 **상한 없이 돈다** —
#   그것이 조용히 실패하는 것보다 낫다. 대신 그 사실을 stderr 로 한 번 말한다.
TMO=""
if command -v timeout >/dev/null 2>&1; then TMO=timeout
elif command -v gtimeout >/dev/null 2>&1; then TMO=gtimeout
else echo "⚠ timeout 이 없다 — 상한 없이 돈다(coreutils 를 설치하면 걸린다)" >&2; fi

run_gate() {
  if [ -n "$TMO" ]; then
    ( cd "$CWD" && "$TMO" "${CODER_GATE_TIMEOUT:-600}" bash -c "$GATE" ) >/dev/null 2>&1
  else
    ( cd "$CWD" && bash -c "$GATE" ) >/dev/null 2>&1
  fi
  printf '%s' $?
}
G_BEFORE="$(run_gate)"
if [ "$G_BEFORE" = "0" ]; then
  emit 67 "착수 전 게이트가 이미 초록이다(rc 0) — 고칠 것이 없으면 「고쳤다」를 판정할 수 없다. 테스트를 먼저 쓰고 그것이 붉은 것을 확인한 뒤에 불러라."
  ledger 67 "gate_already_green" "$G_BEFORE" -1 0 0 "$NFILES"
  exit 67
fi

# ── ④ 스냅샷 — 자식이 무엇을 건드렸는지 뒤에 가른다 ──────────────────────────
# ⚠ **착수 전 미커밋 목록을 기록한다.** 그것과 겹치는 파일은 자식이 고쳤는지 원래 그랬는지
#   가릴 수 없으므로 **되돌리지 않고 알리기만** 한다 — 부모의 작업을 지우는 것이 더 나쁘다.
SNAP="$(mktemp -d)"; trap 'rm -rf "$SNAP"' EXIT
git -C "$CWD" -c core.quotePath=false status --porcelain -uall 2>/dev/null \
  | sed -e 's/^...//' > "$SNAP/before.txt" || : > "$SNAP/before.txt"
# ⭐⭐ **해시도 함께 뜬다**(2026-09-16 리뷰 must_fix). 위 주석이 「되돌리지 않고 **알리기만**
#   한다」고 선언했는데 **알리는 코드가 없었다** — 착수 전부터 더럽던 파일을 자식이 고쳐도
#   차집합에 안 나와 rc 0 으로 통과했고, README 의 rc 0 정의(「대상 파일만 바뀌었다」)가
#   거짓이 됐다. 되돌리지 않는 판단은 그대로 두고 **알림만** 구현한다.
: > "$SNAP/before.hash"
while IFS= read -r _bf; do
  [ -n "$_bf" ] && [ -f "$CWD/$_bf" ] || continue
  printf '%s %s\n' "$(git -C "$CWD" hash-object "$_bf" 2>/dev/null || printf 'x')" "$_bf" >> "$SNAP/before.hash"
done < "$SNAP/before.txt"

# 계획 파일은 따로 백업한다(rc 68 복원용)
PLAN_F="${CLAUDE_PLAN_FILE:-${CODER_PLAN_FILE:-}}"
if [ -n "$PLAN_F" ] && [ -f "$PLAN_F" ]; then cp "$PLAN_F" "$SNAP/plan.bak" 2>/dev/null || true; fi

# ── ⑤ 자식 호출 ──────────────────────────────────────────────────────────────
# ⭐ codex 경로인 이유: 이 위임의 근거가 된 벤치마크(2026-09-16 · 실행 68회)가 그 경로에서
#   측정됐다. `model_catalog_json` 주입 효과(350행 파일 수정이 3회 중 1회 → 3회 전부)는
#   codex 고유 설정이라 다른 경로에서 재현되지 않는다.
PROMPT_F="$SNAP/prompt.md"
{
  cat "$TASK"
  printf '\n\n---\n\n## 규약 — 이 자리에서 반드시 지켜라\n\n'
  printf '### 네가 고칠 수 있는 파일 (이것만)\n\n'
  printf '%s' "$TLIST" | sed -e 's/^/- /'
  printf '\n⛔ 이 목록 밖의 파일을 고치면 그 산출은 **거부되고 되돌려진다.** 밖에서 문제를\n'
  printf '   발견하면 고치지 말고 `notes` 에 적어라.\n\n'
  printf '### 게이트\n\n```\n%s\n```\n\n' "$GATE"
  printf '지금 이 게이트는 **붉다**(rc %s). 그것이 네가 고칠 것이 있다는 증거다.\n' "$G_BEFORE"
  printf '고친 뒤 직접 돌려서 초록이 되는 것을 확인해라 — 부모도 다시 돌려 판정한다.\n\n'
  printf '### 하지 마라\n\n'
  printf -- '- ⛔ 테스트를 고쳐서 통과시키지 마라. 게이트가 요구하는 동작을 구현해라.\n'
  printf -- '- ⛔ `git` 명령을 쓰지 마라(커밋·stash·reset 전부). 부모가 한다.\n'
  printf -- '- ⛔ 계획 파일(`.claude/plan*`)을 건드리지 마라.\n'
  printf -- '- ⛔ 새 파일을 만들지 마라. 위 목록의 파일만 고친다.\n\n'
  printf '### ⛔⛔ 순서 — 이것을 어기면 아무것도 안 한 것이 된다\n\n'
  printf '1. **먼저 파일을 읽고 고쳐라.** 도구를 써라(파일 읽기·쓰기·명령 실행).\n'
  printf '2. 게이트를 직접 돌려 초록이 되는 것을 확인해라.\n'
  printf '3. **그 다음에야** 마지막 메시지로 아래 JSON 한 덩이를 내라.\n\n'
  printf '⚠ 실측(2026-09-16): 첫 시험에서 자식이 도구를 **한 번도 쓰지 않고** 곧바로 JSON 을 내고\n'
  printf '   끝냈다(토큰 2,830 · 한 턴). `files_changed` 에 파일 이름이 적혀 있었지만 그 파일은\n'
  printf '   바뀌지 않았고, `notes` 는 「고칠 파일이 있는지 먼저 확인 중」이었다. **JSON 을 내는 것이\n'
  printf '   일을 끝낸 것이 아니다.** 부모는 게이트를 직접 돌려 판정하므로 그런 산출은 거부된다.\n\n'
  printf '```json\n{"summary":"무엇을 고쳤나","files_changed":["경로"],"gate_ran":true,'
  printf '"rounds":게이트를 돌리고 고치기를 반복한 횟수,"notes":"막힌 것·확신 없는 것"}\n```\n\n'
  printf '`notes` 를 「없음」으로 채우지 마라 — 막힌 것·확신 없는 것이 있으면 적고, 정말 없으면 그렇게 적어라.\n'
} > "$PROMPT_F"

T0=$(date +%s)
CHILD_OUT="$SNAP/child.json"
# ⚠ `--skip-git-repo-check` 를 주지 않는다 — 레포 안에서 돌아야 하고, 아니면 그 자체가 신호다.
# ⚠⚠ `-s workspace-write` 가 있어야 파일을 고칠 수 있다. 기본은 `read-only` 라 그것 없이는
#    자식이 분석만 하고 끝낸다 — 그리고 그 실패는 **조용하다**(결과 JSON 은 그럴듯하고
#    게이트만 여전히 붉다). go-tester 의 벤치마크에서 같은 부류를 겪었다: 패치 도구가 없어
#    「파일을 직접 수정할 수 없으므로」라며 고친 코드를 본문에 출력하고 끝낸 실행이 있었다.
# ⛔ 쓰기 범위를 **경로별로 제한하는 수단이 codex 에 없다.** workspace-write 는 워크스페이스
#    전체를 연다. 그래서 우리 통제 ①은 사전 차단이 아니라 **사후 거부**(rc 66)이고, 그것이
#    스냅샷을 앞뒤로 뜨는 이유다.
# ⛔⛔ **`--output-schema` 를 주지 않는다** (2026-09-16 실물 실측 2/2).
#   주면 작은 모델이 「구조화 출력을 내는 것」을 과업으로 읽고 **도구를 한 번도 쓰지 않은 채**
#   스키마를 채워 끝낸다. 첫 두 실행이 그랬다 — 토큰 2,830 · 한 턴 · 파일 무변경인데
#   `files_changed:["slug.py"]` 와 `gate_ran:false` 를 냈다.
#   ⭐ go-tester 가 **반대 방향으로** 같은 뿌리를 밟았다(다중 턴 뒤 구조화 출력으로 전환하지
#   못해 다 해 놓고 rc 65 로 버려졌다). 뿌리는 하나다: 구조화 출력 강제와 도구 사용이 충돌한다.
#   ⇒ 여기서는 **판정이 자식의 JSON 에 의존하지 않으므로**(게이트와 git 으로 부모가 직접 잰다)
#   스키마를 포기하는 쪽이 옳다. JSON 은 원장용 부가 정보이고, 못 읽으면 「모른다」로 남긴다.
( cd "$CWD" && ${TMO:+$TMO ${CODER_TIMEOUT:-900}} \
    "$CODER_CODEX" -p "$CODER_PROFILE" exec \
      -s workspace-write \
      --output-last-message "$CHILD_OUT" \
      - < "$PROMPT_F" ) >"$SNAP/child.log" 2>&1
CHILD_RC=$?
T1=$(date +%s); ELAPSED=$((T1 - T0))

# ── ⑥ 계획 파일이 자식이 도는 동안 바뀌었나 (rc 68) ──────────────────────────
# ⛔⛔ 이 경로가 잡으려는 위협은 실재한다 — 부모의 Stop 훅이 자식에 걸리면 자식이 미완료
#   체크박스를 지워 빠져나간다(go-tester 에서 재현 1/1). 다만 그 재현은 `--setting-sources ""`
#   를 **뺐을 때**였고, 지금은 넣고 있어 그 경로가 막혀 있다.
#
# ⛔⛔ 그래서 **되돌리지 않는다**(2026-09-17 사용자 결정). 이 검사는 「바뀌었다」만 알 뿐
#   자식과 부모를 가르지 못하는데, 자식은 계획 경로가 임시로 덮여 있고 훅도 막혀 있어
#   고칠 동기가 구조적으로 없다. 실측에서도 발화 건은 전부 부모였다(코디네이터가 계획을
#   진행하며 체크박스를 닫는 정상 동작이 겹쳤다). 되돌리면 그 작업이 지워진다.
#   ⇒ 알리되 파일은 그대로 두고, 시작 시점 사본을 계획 파일 **옆에** 남긴다
#     ($SNAP 은 종료 시 지워지므로 거기 두면 되찾을 수 없다).
if [ -n "$PLAN_F" ] && [ -f "$SNAP/plan.bak" ]; then
  if ! cmp -s "$PLAN_F" "$SNAP/plan.bak" 2>/dev/null; then
    KEPT="$PLAN_F.pre-${LABEL:-coder}"
    cp "$SNAP/plan.bak" "$KEPT" 2>/dev/null || KEPT="(사본을 남기지 못했다)"
    emit 68 "자식이 도는 동안 계획 파일이 바뀌었다: $PLAN_F — ⭐ **되돌리지 않았다**(지금 내용이 그대로 있다) · 시작 시점 사본: $KEPT · 자식·부모 어느 쪽이 고쳤는지는 가르지 못하니 부모를 먼저 의심하라"
    ledger 68 "plan_file_touched" "$G_BEFORE" -1 -1 "$ELAPSED" "$NFILES"
    exit 68
  fi
fi

# ── ⑦ 대상 파일 밖을 고쳤나 (rc 66) ──────────────────────────────────────────
git -C "$CWD" -c core.quotePath=false status --porcelain -uall 2>/dev/null \
  | sed -e 's/^...//' > "$SNAP/after.txt" || : > "$SNAP/after.txt"
# 자식이 **새로 더럽힌** 파일 = after − before
grep -Fxv -f "$SNAP/before.txt" "$SNAP/after.txt" 2>/dev/null | grep . > "$SNAP/new.txt" || : > "$SNAP/new.txt"
: > "$SNAP/viol.txt"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! printf '%s' "$TLIST" | grep -Fxq "$f"; then printf '%s\n' "$f" >> "$SNAP/viol.txt"; fi
done < "$SNAP/new.txt"
# ⭐ 착수 전부터 미커밋이던 파일 중 **내용이 바뀐 것**을 알린다(되돌리지는 않는다).
#   ⚠ 이것은 거부가 아니다 — 자식이 고쳤는지 부모가 작업 중이던 것인지 가릴 수 없기 때문이다.
#   그래도 **침묵하지는 않는다**: 모르는 채로 rc 0 을 받으면 사람이 그대로 커밋한다.
TOUCHED_PRE=""
while IFS=' ' read -r _h _f; do
  [ -n "$_f" ] || continue
  printf '%s' "$TLIST" | grep -Fxq "$_f" && continue          # 대상 파일이면 바뀌는 것이 정상이다
  _now=$(git -C "$CWD" hash-object "$_f" 2>/dev/null || printf 'y')
  [ "$_now" = "$_h" ] || TOUCHED_PRE="$TOUCHED_PRE $_f"
done < "$SNAP/before.hash"
if [ -n "$TOUCHED_PRE" ]; then
  printf '⚠ 착수 전부터 미커밋이던 파일이 바뀌었다(되돌리지 않았다):%s\n' "$TOUCHED_PRE" >&2
  printf '   자식이 고쳤는지 네 작업이 이어진 것인지 가릴 수 없다 — **커밋 전에 직접 봐라.**\n' >&2
fi

if [ -s "$SNAP/viol.txt" ]; then
  # ⚠ **자식이 새로 더럽힌 것만** 되돌린다. 착수 전부터 미커밋이던 파일은 건드리지 않는다 —
  #   자식이 고쳤는지 부모가 작업 중이던 것인지 가릴 수 없고, 부모 작업을 지우는 것이 더 나쁘다.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$CWD" checkout -- "$f" 2>/dev/null || rm -f "$CWD/$f" 2>/dev/null || true
  done < "$SNAP/viol.txt"
  emit 66 "대상 파일 밖을 고쳤다(되돌렸다): $(tr '\n' ' ' < "$SNAP/viol.txt")"
  ledger 66 "wrote_outside_targets" "$G_BEFORE" -1 -1 "$ELAPSED" "$NFILES"
  exit 66
fi

# ── ⑧ 자식의 마지막 메시지 — **부가 정보다. 판정에 쓰지 않는다** ─────────────
# ⭐ 판정은 ⑦(git)과 ⑨(게이트)가 한다. 여기서 읽는 것은 원장에 남길 `rounds` 하나이고,
#   못 읽으면 **-1(모른다)** 로 남긴다 — 「정직 공백」이다. 지어내지 않는다.
# ⚠ 자식이 아무 출력도 없으면 그것은 codex 자체가 실패한 것이므로 rc 65 로 끝낸다.
if [ ! -s "$CHILD_OUT" ]; then
  emit 65 "자식이 아무 출력도 내지 않았다(codex rc=$CHILD_RC)"
  ledger 65 "no_child_output(codex_rc=$CHILD_RC)" "$G_BEFORE" -1 -1 "$ELAPSED" "$NFILES"
  exit 65
fi
# ⚠⚠ **판정을 `||` 뒤에서 읽지 마라.** 첫 판은 `python3 … || printf '0'` 이었는데, 그러면
#   파이썬이 rc 1 로 끝나도 `printf '0'` 이 돌아 값이 채워지고 **위반이 조용히 통과했다**
#   (대조군 ⑨가 잡았다). 지금은 rc 를 따로 받아 -1 로 갈음한다.
ROUNDS=$(python3 - "$CHILD_OUT" <<'PY' 2>/dev/null
import io, json, re, sys
raw = io.open(sys.argv[1], encoding="utf-8", errors="replace").read()
# 자유 형식 출력에서 마지막 JSON 덩이를 최선 노력으로 찾는다(코드펜스 안에 있을 수 있다).
for m in reversed(list(re.finditer(r"\{.*?\}", raw, re.S))):
    try:
        d = json.loads(m.group(0))
    except Exception:
        continue
    if "rounds" in d:
        print(int(d.get("rounds") or 0))
        raise SystemExit(0)
raise SystemExit(1)
PY
); PARSE_RC=$?
if [ "$PARSE_RC" != "0" ] || [ -z "$ROUNDS" ]; then ROUNDS=-1; fi

# ── ⑨ 완료 후 게이트 — **부모가 직접 돌린다** (rc 69) ────────────────────────
# ⚠ 자식의 `gate_ran` 은 자기 신고다. 판정은 여기서 한다.
G_AFTER="$(run_gate)"
if [ "$G_AFTER" != "0" ]; then
  emit 69 "완료 후 게이트가 붉다(rc $G_AFTER) — 자식의 산출은 그대로 두었다. 네가 이어서 고치거나 되돌려라."
  ledger 69 "gate_still_red" "$G_BEFORE" "$G_AFTER" "$ROUNDS" "$ELAPSED" "$NFILES"
  exit 69
fi

cp "$CHILD_OUT" "$OUT" 2>/dev/null || true
ledger 0 "ok" "$G_BEFORE" "$G_AFTER" "$ROUNDS" "$ELAPSED" "$NFILES"
printf '✅ go-coder: 게이트 %s → 0 · 왕복 %s · %s초 · 파일 %s개 · 결과 %s\n' \
  "$G_BEFORE" "$ROUNDS" "$ELAPSED" "$NFILES" "$OUT"
exit 0
