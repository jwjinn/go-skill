#!/usr/bin/env bash
# review-gate.sh — Stop 훅. 「구현 → 리뷰 → 반영」 사슬의 마지막 고리를 집행한다.
#
# 왜 필요한가:
#   리뷰를 돌리는 것은 규율로도 된다. 안 되는 것은 **반영**이다 — 리뷰어가 blocker 를
#   찾아 줬는데 고치지 않고 턴이 끝나면, 그 리뷰는 "돌렸다"는 기록만 남기고 아무것도
#   바꾸지 못한다. 한 줄로: **집행은 규율이 아니라 구조다**.
#   plan-file-gate 가 계획 완주에 대해 하는 일을 이 훅은 리뷰 반영에 대해 한다.
#
# ⭐ 두 축을 **다르게** 다룬다 — 이 구분이 이 훅 설계의 전부다:
#
#   ① 차단(BLOCK) — 확정된 결함이 미해결
#        `.claude/review-active.md` 에 `- [ ]` 가 남아 있다.
#        근거가 명확하다: 리뷰어가 찾았고, 병합 에이전트가 CONFIRMED 로 확정했고,
#        아무도 안 고쳤다. 여기서 오탐이 나려면 병합이 틀렸어야 하는데, 그때의 조치는
#        "조용히 통과"가 아니라 "줄을 지우고 사용자에게 기각 사유를 말하는 것"이다.
#
#   ② 경고(WARN) — 리뷰를 한 번도 안 돌렸다
#        판정이 애매하다. 문서만 고친 턴인가? 탐색 중인가? WIP 인가?
#        ⚠ 2026-08-03 credentials.go 의 교훈: **거부하는 검사에서 오탐 비용은 미탐보다
#        즉각적이다.** 미탐은 조용히 남지만 오탐은 작업을 세운다. 그래서 여기서는
#        차단하지 않고 말만 한다. 게다가 조건을 좁혔다 — **계획 파일이 살아 있을 때만**
#        (= `/go` 로 승인된 다단계 구현일 때만) 말한다. 그 밖의 턴에는 조용하다.
#
# 규약:
#   · 리뷰 파일 : $CLAUDE_PROJECT_DIR/.claude/review-active.md (CLAUDE_REVIEW_FILE 로 덮어쓴다)
#   · 형식     : 마크다운 체크박스 `- [ ]` / `- [x]` — plan-file-gate 와 같은 모양이다
#                (같은 사실을 두 모양으로 담지 않는다)
#   · 미완료   : `[x]`·`[X]` 가 **아닌** 모든 표식
#   · 끝나면   : 전부 닫거나 파일을 지운다. 기각 항목은 **체크하지 말고 지우고** 사유를 말한다.
#
# 설계 원칙 3종은 plan-file-gate 에서 그대로 이식했다(두 축이 같은 규칙을 공유해야
# 사람이 하나만 이해하면 된다):
#   · 낡은 기록 판별 — 사용자가 그 뒤로 말했으면 지금 요청의 것이 아니다
#   · 세션당 상한   — 무한루프 방지(CLAUDE_REVIEW_GATE_MAX, 기본 8)
#   · 훅 고장은 통과 — 관측이 서비스를 죽이면 안 된다(항상 exit 0)
#
# stdin : Stop 훅 JSON(session_id·transcript_path·stop_hook_active)
# stdout: {"decision":"block","reason":…} | {"systemMessage":…} | 없음(통과)
set -u

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

# ⛔ **jq 가 없으면 이 축은 아무것도 보지 않는다** — 아래의 모든 판정이 jq 를 거친다.
#   종전에는 `… | jq … || exit 0` 로 떨어져 **출력 0바이트 · rc=0** 이었다(조용한 fail-open).
#   막지는 않되(도구 부재는 사람이 고칠 일이다) **침묵하지는 않는다**. 근거는 `_deps.sh` 머리말.
if ! command -v jq >/dev/null 2>&1; then
  . "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_deps.sh" 2>/dev/null || exit 0
  deps_jq_missing_notice "리뷰 반영 게이트(확정 결함 미해결 차단)"
  exit 0
fi

session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null) || exit 0
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null) || exit 0

# ── 경로 확정 ────────────────────────────────────────────────────────────────
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  root="$CLAUDE_PROJECT_DIR"
else
  # ⚠ 플러그인으로 배포되면 `dirname $0/..` 는 **플러그인 디렉토리**(코드)를 가리킨다.
  #   상태(계획·리뷰 파일)는 언제나 **프로젝트**의 .claude/ 에 있어야 하므로 cwd 로 폴백한다.
  root="${PWD}"
fi
# ⚠ **세션별 리뷰 파일을 여기에 다시 넣지 마라**(2026-09-02 에 넣었다가 되돌렸다).
#   `.claude/reviews/<session_id>.md` 를 우선 읽게 했는데 **그 파일을 만드는 곳이 없었다** —
#   `/review-loop` 는 언제나 공용 `review-active.md` 를 쓴다. 즉 읽기만 하는 도달 불가
#   분기였고, 주석은 "세션 충돌을 막았다" 고 단정했다. 리뷰어 셋이 전원 이것을 지목했다.
#   모델이 자기 `session_id` 를 알 방법이 없다는 것이 뿌리다(그 값은 훅 stdin 에만 있다).
#   같은 워킹트리에서 세션 둘이 각자 리뷰를 돌려야 하면 **워크트리를 나누거나**
#   `CLAUDE_REVIEW_FILE` 로 나눠라 — 그 escape hatch 는 아래 그대로 남아 있다.
# ⭐⭐ 고유화(2026-09-16) — 계획은 `plan_pick` 으로, 리뷰 파일은 그 계획 옆(`review_of`)으로.
#   채택한 계획이 없으면 리뷰 후보(env · `plans/*/review.md` · 레거시)를 훑어 이 세션이 채택한
#   리뷰 파일을 찾는다(review-loop 만 돌린 세션). 채택 판별은 `plan_session_claims` 하나다.
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_planpath.sh" 2>/dev/null || true
claims() { # <파일> → rc 0 채택 · 1 남의 것 · 2 판별 불가(=채택으로 다룬다)
  command -v plan_session_claims >/dev/null 2>&1 || return 0
  plan_session_claims "$transcript" "$(plan_claim_name "$1")"
}
base="$root/.claude"
plan=$(plan_pick "$base" "$transcript" 2>/dev/null) || plan=''
if [ -n "$plan" ]; then
  review=$(review_of "$plan" "$base")
else
  review=''
  if [ -n "${CLAUDE_REVIEW_FILE:-}" ]; then
    review="$CLAUDE_REVIEW_FILE"
  else
    for r in "$base"/plans/*/review.md "$base/review-active.md"; do
      [ -f "$r" ] || continue
      claims "$r"; rc=$?
      [ "$rc" -ne 1 ] && { review="$r"; break; }
    done
  fi
fi

# ── 공통 헬퍼 ────────────────────────────────────────────────────────────────
epoch_of() {  # ISO8601(UTC) → epoch. BSD·GNU date 양쪽을 시도한다.
  b="${1%%.*}"; b="${b%Z}"
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$b" +%s 2>/dev/null && return 0
  date -u -d "$b" +%s 2>/dev/null && return 0
  return 1
}
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# 마지막 **사람** 프롬프트 시각.
# ⚠⚠ 도구 결과도 type:"user" 로 기록된다 — 실측상 user 행의 92.9% 가 그것이다.
#     안 거르면 턴마다 판별이 뒤집혀 게이트가 통째로 죽는다(2026-08-22 실화).
user_at=''
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  user_ts=$(jq -r 'select(.type=="user" and (has("toolUseResult")|not) and (.isMeta != true))
                   | .timestamp // empty' "$transcript" 2>/dev/null | head -1)
  [ -n "${user_ts:-}" ] && user_at=$(epoch_of "$user_ts")
fi
case "${user_at:-x}" in ''|*[!0-9]*) user_at='' ;; esac

# 세션당 차단 상한 — 소비는 실제로 차단할 때만 한다(경고는 세지 않는다).
max=${CLAUDE_REVIEW_GATE_MAX:-8}
cnt_file="${TMPDIR:-/tmp}/claude-review-gate-${session}"
under_cap() {
  cnt=$(cat "$cnt_file" 2>/dev/null || printf '0')
  case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
  [ "$cnt" -lt "$max" ] || return 1
  printf '%s' "$((cnt + 1))" > "$cnt_file" 2>/dev/null
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# ②-a 원장 누락 축 — 라운드는 돌았는데 아무도 세지 않았나 (2026-09-16)
# ════════════════════════════════════════════════════════════════════════════
# 다른 세션의 실사용 보고(2026-09-16): 리뷰 라운드 둘을 돌리고 must_fix 13건을 반영했는데
# `rounds.jsonl` 기록은 **0건**이었다. 원인은 `Skill(go-review:review-loop)` 대신 `Agent` 로
# 리뷰어를 직접 띄운 것이다 — 그러면 `_dedup.py`·병합자·`verdict.sh`·원장 기록이 전부
# 건너뛰어진다.
#
# ⭐ **결함은 잡혔고 측정만 사라졌다.** 그래서 조용하다 — 겉으로는 리뷰를 제대로 한 것처럼
#   보이고 `measure.sh` 의 표본만 실제보다 적어진다. 정밀도·절제 통계가 그 위에서 계산된다.
#
# ⚠ 리뷰어를 직접 띄우는 것 자체는 막을 일이 아니다(그렇게 해서 blocker 를 잡았다).
#   막을 것은 **세지 않는 것**이고, 그래서 이 축은 알리기만 한다.
#
# ⚠⚠ 이 축은 위 경고 축의 조건(계획 활성·코드 변경)과 **독립**이다. 라운드를 돌렸는데
#   원장에 없는 것은 계획 상태와 무관하므로 그 조기 종료들보다 **앞에** 둔다.
if [ -d "$root/.claude/review/runs" ]; then
  _rl="$root/docs/리뷰-이력/rounds.jsonl"
  _missing=""
  _seen=0
  for _d in "$root"/.claude/review/runs/*/; do
    [ -d "$_d" ] || continue
    _seen=$((_seen + 1))
    _rid=$(basename "$_d")
    # 라운드 디렉토리가 **결과를 낸 것**만 센다. 만들다 만 자리는 누락이 아니다.
    [ -f "$_d/merged.json" ] || [ -f "$_d/candidates.json" ] || continue
    if [ ! -f "$_rl" ] || ! grep -Fq "\"$_rid\"" "$_rl" 2>/dev/null; then
      _missing="$_missing $_rid"
    fi
  done
  # ⭐ `runs/` 가 비어 있으면 **판정하지 않는다.** 「0건 누락」과 「잴 것이 없었다」는 다르다.
  if [ "$_seen" -gt 0 ] && [ -n "$_missing" ]; then
    LEDGER_MSG="📒 라운드 디렉토리는 있는데 **원장에 없다**:$_missing — \`docs/리뷰-이력/rounds.jsonl\` 에 그 라운드가 없다. \`Agent\` 로 리뷰어를 직접 띄우면 _dedup·병합자·verdict·원장 기록이 전부 건너뛰어진다(결함은 잡히고 측정만 사라진다 — 그래서 조용하다). 다음부터는 \`Skill(go-review:review-loop)\` 로 불러라. 이미 돈 라운드는 \`review/record-round.sh\` 로 기록할 수 있다. ⚠ 차단이 아니라 안내다."
  fi
fi

# ⚠⚠ **`systemMessage` 를 두 번 내지 마라.** 훅 출력은 JSON 하나로 파싱되므로 두 덩이를
#   내면 뒤엣것이 버려지거나 파싱이 통째로 깨진다. 아래 축들은 조기 종료가 여럿이라,
#   그 전부가 이 함수를 지나게 해서 원장 메시지가 묻히지 않게 한다.
finish() { # finish [덧붙일 메시지]
  _fm="${LEDGER_MSG:-}"
  if [ -n "${1:-}" ]; then
    if [ -n "$_fm" ]; then _fm="$_fm
$1"; else _fm="$1"; fi
  fi
  [ -n "$_fm" ] && jq -n --arg m "$_fm" '{systemMessage: $m}' 2>/dev/null
  exit 0
}

# ════════════════════════════════════════════════════════════════════════════
# ① 차단 축 — 확정된 결함이 미해결인가
# ════════════════════════════════════════════════════════════════════════════
if [ -f "$review" ]; then
  boxes=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[.\]' "$review" 2>/dev/null || printf '0')
  done_n=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[[xX]\]' "$review" 2>/dev/null || printf '0')
  case "$boxes"  in ''|*[!0-9]*) boxes=0 ;; esac
  case "$done_n" in ''|*[!0-9]*) done_n=0 ;; esac

  # ⭐ 탐지기 자체 검증 — 파일은 있는데 체크박스가 0개면 **판정할 수 없다**.
  #   원 레포의 규칙("0 이 나오면 탐지기부터 의심하라")대로 조용히 넘기지 않고 말한다.
  #   다만 차단하지도 않는다 — 못 쟀다는 것을 알리는 것까지가 이 자리의 몫이다.
  if [ "$boxes" -eq 0 ]; then
    jq -n --arg p "$review" \
      '{systemMessage: ("⚠ 리뷰 파일에 체크박스가 0개다(" + $p + ") — 반영 게이트가 이 파일을 판정하지 못한다. `- [ ] [severity] 파일:줄 — 요약` 형식으로 적어라(반영이 끝났으면 파일을 지워라).")}' 2>/dev/null
    exit 0
  fi

  # ── ⭐⭐ 반영 주장에 「재는 법」이 있나 (2026-09-16) ─────────────────────────
  # 다른 세션 실사용 보고: 반영 둘이 **거짓**이었고, 다음 단계 리뷰가 **우연히** 같은 파일을
  # 봐서 잡혔다. 단계마다 머지하는 흐름에서는 「머지 전 합본 라운드」도 존재하지 않았다.
  #
  # ⛔ 이것을 「재리뷰를 더 하자」로 풀면 사용자 결정(「지속적 반복에 좋은 결과를 못 받았다」)을
  #   어긴다. 주장에 재는 법을 붙이면 재리뷰 없이 명령 하나로 판정된다.
  #
  # ⚠ 여기서 보는 것은 **「근거 없이 체크했나」**이지 「그 명령이 통과했나」가 아니다.
  #   후자를 보려면 게이트가 임의 명령을 실행해야 하고, 그것은 위험해서 하지 않는다.
  #   이 경계를 넓히지 마라.
  # ⭐⭐ **이 파일이 새 형식을 쓸 때만 센다.** `확인:` 이 하나도 없는 파일은 이행기의 옛
  #   형식이고, 거기에 발화하면 **모든 기존 리뷰 파일이 언제나 붉다** — 그러면 아무도 안 본다
  #   (같은 날 격자 축에서 고정 절 때문에 똑같은 자리를 밟았다). 새 형식을 도입하라는 것은
  #   `review-loop.md` 의 지시가 하고, 이 게이트는 **쓰기 시작한 파일의 누락**을 잡는다.
  if [ "$done_n" -gt 0 ] && grep -q '확인[[:space:]]*:' "$review" 2>/dev/null; then
    # 닫힌 항목 줄번호마다 **다음 두 줄 안에** `확인:` 이 있는지 본다.
    _noverify=$(awk '
      /^[[:space:]]*[-*+][[:space:]]+\[[xX]\]/ { pend=2; miss++; next }
      pend > 0 { if ($0 ~ /확인[[:space:]]*:/) { miss--; pend=0 } else pend-- ; next }
      END { print miss+0 }' "$review" 2>/dev/null || printf '0')
    case "$_noverify" in ''|*[!0-9]*) _noverify=0 ;; esac
    if [ "$_noverify" -gt 0 ]; then
      if [ -n "${LEDGER_MSG:-}" ]; then LEDGER_MSG="$LEDGER_MSG
"; fi
      LEDGER_MSG="${LEDGER_MSG:-}🧾 반영했다고 체크한 항목 $_noverify 건에 \`확인:\` 줄이 없다 — 「고쳤다」가 참인지 재는 명령이 없으면 그 판정이 우연에 달린다(실측: 반영 둘이 거짓이었고 다음 단계 리뷰가 우연히 같은 파일을 봐서 잡혔다). 각 항목 아래에 \`확인: \\\`<명령>\\\` 의 <출력>\` 을 적고, 잴 수 없으면 \`확인: 없음 — 코드를 읽어야 한다\` 라고 적어라. ⚠ 차단이 아니라 안내다."
    fi
  fi

  left=$((boxes - done_n))
  if [ "$left" -gt 0 ]; then
    # 낡은 기록 판별 — **이 세션이 시작되기 전에 쓰인 파일인가**(2026-09-02 개정).
    # ⚠⚠ 이전 기준은 「마지막 사람 발화 뒤면 낡음」이었고 그것이 게이트를 무력화했다 —
    #   대화형 세션에서 사용자는 작업 내내 말하므로 거의 항상 참이 되어 **리뷰를 만든 그
    #   턴에만 무장**됐다. plan 축과 같은 결함이고 같은 방식으로 고쳤다(첫 발화와 비교).
    review_at=$(mtime_of "$review")
    case "${review_at:-x}" in ''|*[!0-9]*) review_at='' ;; esac
    stale=0
    if [ -n "$review_at" ] && [ -n "$user_at" ] && [ "$review_at" -lt "$user_at" ] 2>/dev/null; then
      stale=1
    fi
    # ⚠⚠ 판별 불가(둘 중 하나라도 못 구함)는 **차단 유지**다.
    #    모르는 것을 근거로 게이트를 열면 게이트가 통째로 무력화된다.

    # (채택 판별은 위에서 review 를 고를 때 했다 — 여기 도달한 리뷰 파일은 이 세션의 것이거나 판별 불가다)
    if [ "$stale" -eq 0 ] && under_cap; then
      list=$(grep -nE '^[[:space:]]*[-*+][[:space:]]+\[.\]' "$review" 2>/dev/null \
             | grep -vE '\[[xX]\]' \
             | sed -e 's/^\([0-9]*\):[[:space:]]*[-*+][[:space:]]*/  \1: /' \
             | head -20)
      more=''
      [ "$left" -gt 20 ] && more="
  … 외 $((left - 20))개"

      reason="리뷰가 확정한 결함 ${boxes}건 중 ${left}건이 미해결인데 턴을 끝내려 했다.
리뷰 파일: ${review}

${list}${more}

이 항목들은 독립 리뷰어가 찾았고 병합 에이전트가 **CONFIRMED** 로 확정한 것이다
(오탐은 병합 단계에서 이미 기각됐다). 고치지 않고 끝내면 리뷰는 기록만 남고 아무것도 바꾸지 못한다.

지금 할 일:
  · 고쳐라. 고친 항목은 그 파일에서 [x] 로 닫아라.
  · 고친 뒤 해당 슬라이스 게이트를 다시 돌려라(go vet/test · tsc · lint · vite build).
  · ⛔ 고친 뒤 **재리뷰하지 마라**(2026-09-03 규약 변경 — review-loop ⑥-4). 한 단계는
    「개발 → 리뷰 1회 → 반영」으로 끝난다. 반영 결과는 **머지 전 합본 라운드**가 본다.

기각해야 한다면(병합 에이전트가 틀렸다면):
  · [x] 로 위장하지 마라. **그 줄을 지우고** 사용자에게 왜 기각하는지 말해라.
    침묵으로 넘기면 다음 사람이 그 판단을 다시 할 수 없다."

      jq -n --arg r "$reason" '{decision: "block", reason: $r}' 2>/dev/null
      exit 0
    fi
  fi
fi


# ════════════════════════════════════════════════════════════════════════════
# ② 경고 축 — 승인된 구현인데 리뷰를 한 번도 안 돌렸나
# ════════════════════════════════════════════════════════════════════════════
# ⚠ 조건을 좁게 잡는다. 넓히면 소음이 되고, 소음이 되면 아무도 안 읽는다.
#   ㉠ 계획 파일이 살아 있다(= /go 로 승인된 다단계 구현이다)
#   ㉡ 코드가 실제로 바뀌었다(문서·이미지만 바뀐 턴은 대상이 아니다)
#   ㉢ 이번 요청 안에서 리뷰 산출물이 하나도 안 나왔다
# ㉠ 계획이 **살아 있는가** — 파일 존재만으로는 부족하다.
#   ⚠ 전부 [x] 인데 아직 안 지운 계획도 파일은 남아 있다. 그것을 「승인된 구현 진행 중」으로
#     세면, 끝난 뒤 별건으로 코드 한 줄만 고쳐도 매 턴 리뷰 넛지가 뜬다 — 이 훅이 스스로
#     경계한 그 소음이다. goal-echo.sh 는 같은 상황에서 미완료 수를 세어 조용해진다;
#     두 훅의 「살아 있다」 정의가 어긋나면 안 된다.
[ -f "$plan" ] || finish
p_boxes=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[.\]' "$plan" 2>/dev/null || printf '0')
p_done=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[[xX]\]' "$plan" 2>/dev/null || printf '0')
case "$p_boxes" in ''|*[!0-9]*) p_boxes=0 ;; esac
case "$p_done"  in ''|*[!0-9]*) p_done=0 ;; esac
[ "$p_boxes" -gt 0 ] && [ "$((p_boxes - p_done))" -gt 0 ] || finish

# ㉡ 코드 변경 — 미커밋 기준. 확장자로 코드/비코드를 가른다.
#   ⚠ **`-uall` 이 필수다.** 기본(`-unormal`)은 미추적 **디렉토리를 한 줄로 접어** 보고하므로
#     `?? backend/internal/foo/` 가 되어 확장자 정규식에 걸리지 않는다 → 새 슬라이스를 통째로
#     만든, **가장 리뷰가 필요한 순간에 탐지기가 0 을 돌려준다**. 원 레포의 대표 실패 부류
#     (「0 이 나오면 탐지기부터 의심하라」)를 이 훅이 그대로 재현할 뻔했다.
# ⭐ 경고 축도 세션 스코프다 — `plan_pick` 이 고른 계획이 없으면(남의 것만) 위에서 이미 빈 값이라
#   `[ -f "$plan" ]` 에서 조용히 통과했다. 여기 도달한 계획은 이 세션의 것이거나 판별 불가다.
changed=$(cd "$root" 2>/dev/null && git status --porcelain -uall 2>/dev/null \
          | grep -cE '\.(go|ts|tsx|js|jsx|py|lua|sh|sql|ya?ml)$' || printf '0')
case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
[ "$changed" -gt 0 ] || finish

# ㉢ 이번 요청 안의 리뷰 산출물 — merged.json 이 마지막 사람 발화보다 새것인가.
#    ⚠ user_at 을 못 구했으면 판정하지 않는다(모르는 것을 근거로 잔소리하지 않는다).
[ -n "$user_at" ] || finish
fresh=0
for m in "$root"/.claude/review/runs/*/merged.json; do
  [ -f "$m" ] || continue
  mt=$(mtime_of "$m")
  case "${mt:-x}" in ''|*[!0-9]*) continue ;; esac
  [ "$mt" -ge "$user_at" ] 2>/dev/null && { fresh=1; break; }
done
[ "$fresh" -eq 0 ] || finish

finish "$(printf '🔍 승인된 구현(계획 파일 활성) + 코드 변경 %s개인데 이번 요청에서 리뷰가 한 번도 안 돌았다 — `/review-loop` 로 독립 리뷰어(Claude 2 + Codex)를 돌려라. 구현자 자신은 같은 맹점을 갖는다. ⚠ 차단이 아니라 안내다: 문서 중심 턴이거나 아직 구현 중이면 무시해도 된다.' "$changed")"
