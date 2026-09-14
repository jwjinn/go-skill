#!/usr/bin/env bash
# Stop 훅 — 계획 파일(.claude/plan-active.md)에 미완료 체크박스가 남은 채로 턴을 끝내려 하면 거부한다.
#
# 왜 두 번째 축이 필요한가(2026-08-22):
#   todo-completion-gate.sh 는 transcript 의 **TodoWrite 호출**을 본다. 그런데 그 도구가
#   **하네스 빌드에 아예 없는 세션**이 실제로 나왔다(도구 목록·지연로드·ToolSearch 전부 부재).
#   그때 훅은 "계획을 안 세운 턴" 으로 보고 조용히 통과한다 — 12단계 계획을 승인받고 1단계만
#   해도 잡히지 않는다. 즉 완주 집행이 규율(불변식 10)로 되돌아간다.
#   이 축은 **도구가 아니라 파일**을 보므로 그 조건에서도 작동한다.
#
# 두 축은 독립이고 충돌하지 않는다 — TodoWrite 가 돌아오면 둘 다 각자 판단한다.
# 설계 원칙 3종은 그대로 이식했다: 낡은 계획 판별 · 세션당 상한 · 훅 고장은 통과.
#
# 계획 파일 규약:
#   · 경로   : $CLAUDE_PROJECT_DIR/.claude/plan-active.md (CLAUDE_PLAN_FILE 로 덮어쓸 수 있다)
#   · 형식   : 마크다운 체크박스 `- [ ]` / `- [x]`
#   · 미완료 : `[x]`·`[X]` 가 **아닌** 모든 상태(`[ ]`·`[~]`·`[>]` …) — TodoWrite 의
#              "status != completed" 와 같은 규칙이다(진행중도 미완료다)
#   · 끝나면 : 전부 `[x]` 로 닫거나 파일을 지운다. 범위 밖 항목은 **체크하지 말고 지우고**
#              왜 뺐는지 사용자에게 말한다(불변식 10).
#   ⚠ 워크트리마다 CLAUDE_PROJECT_DIR 가 다르므로 파일도 자연히 분리된다. 같은 디렉토리에서
#     세션 둘이 동시에 쓰면 서로의 계획을 덮어쓴다 — 그때는 CLAUDE_PLAN_FILE 로 나눠라.
#
# stdin : Stop 훅 JSON(session_id·transcript_path·stop_hook_active)
# stdout: {"decision":"block","reason":…} 또는 {"systemMessage":…} 또는 없음(통과)
# 항상 exit 0 — 훅 자체 오류로 정상 종료를 막지 않는다(관측이 서비스를 죽이면 안 된다).

#
# ⛔ **브랜치 게이팅을 여기에 복사하지 마라** (2026-08-24).
#   `notion-sync-gate`·`arch-report-gate` 는 **공유 표면**(Notion 현황판·as-is 보고서)에
#   올리는 일을 재촉하므로 main 에서만 말한다. 이 훅은 다르다 — **지금 해야 하는 일**을
#   말한다(라이브를 바꿨으면 지금 선언해야 하고, 계획 완주는 브랜치 문제가 아니다).
#   피처 브랜치에서 조용해지면 그 순간 이 게이트의 존재 이유가 사라진다.
set -u

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

# ⛔ **jq 가 없으면 이 축은 아무것도 보지 않는다** — 아래의 모든 판정이 jq 를 거친다.
#   종전에는 `… | jq … || exit 0` 로 떨어져 **출력 0바이트 · rc=0** 이었다(조용한 fail-open).
#   막지는 않되(도구 부재는 사람이 고칠 일이다) **침묵하지는 않는다**. 근거는 `_deps.sh` 머리말.
if ! command -v jq >/dev/null 2>&1; then
  . "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_deps.sh" 2>/dev/null || exit 0
  deps_jq_missing_notice "계획 완주 게이트(파일 축 — .claude/plan-active.md)"
  exit 0
fi

session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null) || exit 0
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null) || exit 0

# 계획 파일 경로. CLAUDE_PROJECT_DIR 이 없으면 **cwd** 에서 찾는다.
# ⚠ 스크립트 위치에서 역산하지 마라 — 플러그인으로 배포되면 그것은 코드 디렉토리다.
#
# ⚠ **세션별 계획 파일을 여기에 다시 넣지 마라**(2026-09-02 에 넣었다가 되돌렸다).
#   동기는 실재했다 — 같은 워킹트리에서 세션 둘이 이 파일 하나를 두고 다툰다(실측: 다른
#   세션의 미완료 계획이 살아 있어 새 세션이 자기 계획을 쓸 자리가 없었다).
#   그런데 `.claude/plans/<session_id>.md` 분기는 **성립하지 않았다**: 모델이 자기
#   `session_id` 를 알 방법이 레포 어디에도 없다(그 값은 훅의 stdin 에만 있다). 그래서
#   **읽기만 하고 아무도 쓰지 않는 분기**가 됐고, 주석은 "남의 계획에 안 붙잡힌다" 고
#   단정하는데 실제로는 공용 파일로 폴백해 그대로 붙잡혔다 — 없느니만 못한 상태였다.
#   원 레포의 규칙 그대로다: **부재가 통제다. 반쯤 지어 놓고 막았다고 적지 마라.**
#   같은 문제의 정답은 이미 있다 — **워크트리로 디렉토리를 나눠라**(CLAUDE_PROJECT_DIR 가
#   달라지므로 계획 파일도 자연히 분리된다). 한 트리를 고집해야 하면 `CLAUDE_PLAN_FILE` 로
#   나눠라. `/go` 가 착수 전에 이 충돌을 감지해 사용자에게 말한다.
if [ -n "${CLAUDE_PLAN_FILE:-}" ]; then
  plan="$CLAUDE_PLAN_FILE"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  plan="$CLAUDE_PROJECT_DIR/.claude/plan-active.md"
else
  # ⚠ 플러그인으로 배포되면 `dirname $0/..` 는 **플러그인 디렉토리**(코드)를 가리킨다.
  #   상태(계획·리뷰 파일)는 언제나 **프로젝트**의 .claude/ 에 있어야 하므로 cwd 로 폴백한다.
  plan="${PWD}/.claude/plan-active.md"
fi
[ -f "$plan" ] || exit 0   # 계획 파일이 없는 턴 → 관여하지 않는다

# ── 체크박스 파싱 ────────────────────────────────────────────────────────────
# `- [ ] 할 일` / `* [x] 한 일` / 들여쓴 하위 항목도 센다.
# ⚠⚠ **결정 절(`## 결정 필요(승인 전)`)의 체크박스는 세지 않는다**(2026-09-03 리뷰가 지목).
#   그것을 「해야 할 단계」로 세면 이 훅이 「다음 항목을 진행하고 [x] 로 닫아라」라고 지시하는데,
#   그 항목은 사용자에게 **물어야 할 결정**이다 — 모델이 대신 정하고 닫게 된다. 게다가 같은 턴에
#   goal-echo 는 「먼저 닫아라(물어라)」를 내므로 **두 훅이 정반대 지시**를 하게 된다.
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_planpath.sh" 2>/dev/null || true
if command -v plan_boxes_excluding_decisions >/dev/null 2>&1; then
  boxes=$(plan_boxes_excluding_decisions "$plan" all)
  done_n=$(plan_boxes_excluding_decisions "$plan" done)
else
  boxes=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[.\]' "$plan" 2>/dev/null || printf '0')
  done_n=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[[xX]\]' "$plan" 2>/dev/null || printf '0')
fi
case "$boxes"  in ''|*[!0-9]*) boxes=0 ;; esac
case "$done_n" in ''|*[!0-9]*) done_n=0 ;; esac

# ⭐ 탐지기 자체 검증 — 파일은 있는데 체크박스가 **0개**면 판정할 수 없다.
#   원 레포의 규칙("0 이 나오면 탐지기부터 의심하라")대로 조용히 넘기지 않고 말한다.
#   ⚠ 그렇다고 차단하지도 않는다: 거부하는 검사에서 오탐 비용은 미탐 비용보다 즉각적이다
#   (2026-08-03 credentials.go 가 배포를 세운 그 교훈). 「못 쟀다」를 알리는 것까지가 이 축의 몫.
if [ "$boxes" -eq 0 ]; then
  jq -n --arg p "$plan" \
    '{systemMessage: ("⚠ 계획 파일에 체크박스가 0개다(" + $p + ") — 완주 게이트가 이 파일을 판정하지 못한다. `- [ ] 항목` 형식으로 적어라(계획이 끝났으면 파일을 지워라).")}' 2>/dev/null
  exit 0
fi

left=$((boxes - done_n))
[ "$left" -gt 0 ] || exit 0   # 전부 닫혔다

# ── 낡은 계획 판별 — **이 세션이 시작되기 전의 계획인가** ─────────────────────
# ⚠⚠⚠ 2026-09-02 개정. 이전 기준은 「마지막 사람 발화 ↔ 파일 mtime」이었고 **그것이 게이트를
#   구조적으로 무력화했다.** 대화형 세션에서 사용자는 작업 내내 말하므로 `마지막 발화 > 계획
#   mtime` 이 거의 항상 참이다 — 즉 **계획을 만든 그 턴에만 무장되고 이후 모든 턴에서 통과**했다.
#   실측(다른 세션 자가평가): 26개 미완료를 남기고 턴을 여러 번 끝냈는데 차단 카운터가 **0**.
#   2026-08-22 에 todo 축이 같은 부류로 3일간 무장해제됐던 것의 재발이다.
#
# ⭐ 고친 기준: **세션의 첫 사람 발화**와 비교한다.
#   · 계획이 그 뒤에 쓰였다(plan_at ≥ first_at) → **이 세션의 계획이다 → 무장**
#   · 계획이 그 앞이다(plan_at < first_at)     → 세션 시작 전 파일 → 잔재로 보고 통과
#   이것이 원래 목적(「지난주 잔재가 새 세션을 붙잡지 않게」)을 그대로 달성하면서
#   같은 세션의 대화 왕복에는 영향받지 않는다.
#
# ⚠ 받아들인 대가: 사용자가 계획을 버리고 다른 일을 시키면 그 계획이 계속 차단한다.
#   **그것이 옳은 방향이다** — 버린 계획은 지워야 하고 차단 메시지가 그것을 지시한다.
#   그리고 원 레포가 이미 적어 둔 원칙이 그쪽을 가리킨다: 「모르는 것을 근거로 게이트를
#   열면 게이트가 통째로 무력화된다」(2026-08-19). 실제로 그 반대를 골랐다가 그렇게 됐다.
#   세션당 상한 8회가 그 오탐의 상한이다.
#
# ⚠⚠ "사용자 메시지" 는 **사람이 쓴 것만**이다 — 도구 결과도 `type:"user"` 로 기록되고
#   실측상 user 행의 92.9% 가 그것이다(2026-08-22).
# ⚠⚠⚠ 둘 중 하나라도 못 구하면 차단을 유지한다 — 모르는 것을 근거로 게이트를 열지 않는다.
epoch_of() {  # ISO8601(UTC) → epoch. BSD·GNU date 양쪽을 시도한다.
  b="${1%%.*}"; b="${b%Z}"
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$b" +%s 2>/dev/null && return 0
  date -u -d "$b" +%s 2>/dev/null && return 0
  return 1
}
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

plan_at=$(mtime_of "$plan")
first_ts=''
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # ⭐ `head -1` 이다 — 세션의 **첫** 사람 발화. `tail -1`(마지막)이 그 결함의 원인이었다.
  first_ts=$(jq -r 'select(.type=="user" and (has("toolUseResult")|not) and (.isMeta != true))
                    | .timestamp // empty' "$transcript" 2>/dev/null | head -1)
fi
first_at=''
[ -n "$first_ts" ] && first_at=$(epoch_of "$first_ts")
case "${plan_at:-x}" in ''|*[!0-9]*) plan_at='' ;; esac
case "${first_at:-x}" in ''|*[!0-9]*) first_at='' ;; esac
if [ -n "$plan_at" ] && [ -n "$first_at" ] && [ "$plan_at" -lt "$first_at" ] 2>/dev/null; then
  exit 0   # 이 세션이 시작되기 전에 쓰인 파일이다 → 잔재로 본다
fi

# ── 무한루프 방지 ①: 세션당 차단 횟수 상한 ──────────────────────────────────
max=${CLAUDE_PLAN_GATE_MAX:-8}
cnt_file="${TMPDIR:-/tmp}/claude-plan-gate-${session}"
cnt=$(cat "$cnt_file" 2>/dev/null || printf '0')
case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
[ "$cnt" -lt "$max" ] || exit 0
printf '%s' "$((cnt + 1))" > "$cnt_file" 2>/dev/null

# ── 무한루프 방지 ②: ⭐ **진전 없음 탐지**(2026-09-03, 사용자 우려) ──────────
# 「끝나지 않는 루프」의 정체는 **오래 도는 것이 아니라 진전 없이 도는 것**이다. 횟수 상한만
# 있으면 8번을 아무 성과 없이 돌고도 「상한에 걸려 통과」로 끝난다 — 그건 완주가 아니다.
# 그래서 **차단할 때마다 미완료 수를 기억**하고, 줄지 않으면 세어 둔다.
# 연속 STALL 회 동안 하나도 안 닫히면 **차단을 풀고 그 사실을 말한다** — 붙잡아 두는 것이
# 오히려 루프를 길게 만들기 때문이다. 판단을 사람에게 넘기는 것이 그 자리의 정답이다.
stall_max=${CLAUDE_PLAN_GATE_STALL:-3}
case "$stall_max" in ''|*[!0-9]*) stall_max=3 ;; esac
pg_file="${TMPDIR:-/tmp}/claude-plan-progress-${session}"
prev_left=$(cut -d' ' -f1 "$pg_file" 2>/dev/null || printf '')
stall=$(cut -d' ' -f2 "$pg_file" 2>/dev/null || printf '0')
prev_plan=$(cut -d' ' -f3- "$pg_file" 2>/dev/null || printf '')
case "$prev_left" in ''|*[!0-9]*) prev_left='' ;; esac
case "$stall" in ''|*[!0-9]*) stall=0 ;; esac
# ⚠⚠ **계획이 바뀌면 카운터를 버린다**(2026-09-03 리뷰가 지목). 세션 id 로만 키를 잡으면
#   앞 계획이 남긴 stall 때문에 **새 계획의 첫 Stop 에서 곧바로 게이트가 풀린다** —
#   12단계 계획이 한 항목도 닫히지 않은 채 완주 게이트 없이 끝난다.
#   Q11(계획 덮어쓰기)처럼 한 세션 안의 계획 교체는 드문 일이 아니다.
if [ "$prev_plan" != "$plan" ]; then
  prev_left=''; stall=0
fi
# ⚠ **미완료가 늘어난 것은 진전 없음이 아니다** — 작업 중 하위 항목을 발견해 추가하는 것은
#   정상이다. 그때는 카운터를 리셋한다(늘어남을 stall 로 세면 정상 작업이 게이트를 푼다).
if [ -n "$prev_left" ] && [ "$left" -eq "$prev_left" ] 2>/dev/null; then
  stall=$((stall + 1))
else
  stall=0
fi
printf '%s %s %s' "$left" "$stall" "$plan" > "$pg_file" 2>/dev/null
if [ "$stall" -ge "$stall_max" ] 2>/dev/null; then
  cat <<MSG
{"decision":"approve","systemMessage":"⛔ 진전 없음 — 미완료 ${left}개가 ${stall}회 연속 줄지 않았다. 차단을 푼다(붙잡아 두면 루프만 길어진다).\n무엇이 막고 있는지, 무엇을 시도했고 왜 안 됐는지를 사용자에게 **구체적으로** 말해라. 「계속하겠습니다」로 넘기지 마라 — 그것이 이 탐지기가 잡으려는 바로 그 상태다."}
MSG
  exit 0
fi

list=$(grep -nE '^[[:space:]]*[-*+][[:space:]]+\[.\]' "$plan" 2>/dev/null \
       | grep -vE '\[[xX]\]' \
       | sed -e 's/^\([0-9]*\):[[:space:]]*[-*+][[:space:]]*/  \1: /' \
       | head -20)
more=''
[ "$left" -gt 20 ] && more="
  … 외 $((left - 20))개"

# ── 「남의 계획일 수 있다」 진단 ─────────────────────────────────────────────
# ⭐ 왜 이 진단이 필요한가(2026-09-02, 한 세션에서 **세 번** 겪었다):
#   같은 워킹트리에서 세션이 여럿 돌면 이 파일 하나를 공유한다. 그러면 B 세션이 A 의
#   미완료 계획으로 차단되는데, 메시지는 "완주해라" 라고만 말한다 — B 는 완주할 수 없다.
#   그 계획은 B 의 것이 아니고, B 가 지우면 A 의 추적이 사라진다. **진단이 틀린 것이다.**
#
# ⚠ **그렇다고 통과시키지는 않는다.** 소유자를 가릴 신호가 없기 때문이다 —
#   계획을 쓴 세션도 이 디렉토리에 있으므로, 불일치를 근거로 열면 **진짜 주인의 게이트까지**
#   꺼진다(fail-open). 그래서 차단은 유지하고 **무엇이 일어났는지만 정확히 말한다.**
#   푸는 것은 사람의 몫이다(워크트리 분리 · CLAUDE_PLAN_FILE · 그 계획을 끝내거나 지우기).
# ⭐ 공용 함수(`_planpath.sh`)를 쓴다 — 이 파싱이 훅마다 갈라져서 한쪽만 고친 채로
#   다른 쪽이 계속 오진했다. 특히 **첫 공백 절단**이 없으면 경로 뒤 설명을 붙인 계획을
#   「남의 것」으로 오진하고, 그 진단은 「멈춰라」라서 오진의 대가가 곧 작업 중단이다.
if command -v plan_owner_of >/dev/null 2>&1; then
  owner=$(plan_owner_of "$plan")
else
  owner=$(grep -m1 -E '^[[:space:]]*(작업 위치|Work dir)[[:space:]]*:' "$plan" 2>/dev/null \
          | sed -e 's/.*: *//' -e 's/\*\*//g' -e 's/[[:space:]]*(.*//' -e 's/[[:space:]]*$//')
fi
foreign=''
if [ -n "$owner" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "$owner" != "$CLAUDE_PROJECT_DIR" ]; then
  foreign="⚠ **이 계획은 다른 세션의 것일 수 있다.**
   계획 머리말의 작업 위치: ${owner}
   지금 세션의 프로젝트  : ${CLAUDE_PROJECT_DIR}
   둘이 다르다. 그렇다면 이 항목들은 네가 완주할 수 있는 일이 아니다 —
   **[x] 로 위장하지도, 줄을 지우지도 마라**(지우면 그 세션의 완주 추적이 사라진다).
   사용자에게 이 사실과 해결법을 말하고 멈춰라:
     ① 그 세션이 계획을 끝내거나 파일을 지운다
     ② 각 세션을 \`git worktree\` 로 나눈다(CLAUDE_PROJECT_DIR 가 달라져 계획도 분리된다)
     ③ 세션을 \`CLAUDE_PLAN_FILE=<경로>\` 로 띄워 파일을 나눈다
   ⚠ 소유자를 가릴 신호가 없어 게이트는 계속 차단한다 — 불일치로 열면 진짜 주인의
     게이트까지 꺼지기 때문이다. 이 차단은 세션당 ${max}회까지만이다.

"
fi

reason="계획 ${boxes}단계 중 ${left}개가 미완료인데 턴을 끝내려 했다.
계획 파일: ${plan}

${foreign}${list}${more}

승인된 다단계 계획은 완주한다(CLAUDE.md 전역 불변식 10). 단계 경계는 멈춤 지점이 아니다 —
\"이어할까요?\" 를 묻지 말고 다음 항목을 진행하고, 끝낸 항목은 그 파일에서 [x] 로 닫아라.

정말 멈춰야 하는 경우는 둘뿐이고, 그때는 멈추기 전에 그 사유를 말해야 한다:
  ① 사용자 답 없이는 진행이 무의미한 설계 갈림길 → AskUserQuestion 으로 물어라
  ② 남은 항목이 이 요청의 범위가 아님(사용자가 \"C2까지만\" 이라 했거나 계획이 낡음)
     → 그 줄을 [x] 로 위장하지 말고 **파일에서 지우고**, 왜 뺐는지 사용자에게 말하라"

jq -n --arg r "$reason" '{decision: "block", reason: $r}' 2>/dev/null

exit 0
