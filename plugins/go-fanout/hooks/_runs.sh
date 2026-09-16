#!/usr/bin/env bash
# _runs.sh — 「이 세션이 관여한 run 은 무엇인가」를 한 곳에서 판별한다.
#
# ⭐⭐ 왜 함수로 뺐나 (2026-09-16): 이 판별을 게이트 **둘**이 쓴다(완주 게이트 `wave-close-gate.sh` ·
#   코디네이터 인박스 게이트 `coordinator-inbox-gate.sh`). 같은 사실을 두 곳이 각자 판단하면
#   어긋난다 — 한쪽만 고치면 「한 게이트는 막고 다른 게이트는 통과」가 되고, 그 상태는 사람이
#   게이트 자체를 불신하게 만든다(이 레포군이 여러 번 밟은 「정본이 둘」 부류다).
#
# 판별 근거는 transcript 하나다. 코디네이터는 run_id 를 **도구 호출의 입력**(`--run …`)이나
# **한 run 만 담은 도구 결과**로 만난다.
#
# ⛔⛔ **전체 목록 응답은 관여의 근거가 아니다**(2026-09-16 리뷰가 실측으로 잡았다).
#   `orca orchestration worker-list --json`(run 필터 없이)은 이 기계의 **모든 run** 을 한 번에
#   돌려준다 — 실측 45 레코드·7 run. 그것을 재료에 넣으면 코디네이터가 상태를 한 번 조회하는
#   순간 사흘 전 파도까지 「내 것」이 되고, run 스코프가 사실상 사라진다. 그것이 바로 이
#   스코프가 고치려던 상태다(훅을 점검하던 세션이 지난 사흘의 세 차수로 매 턴 막혔다).
#   ⇒ 한 응답에서 서로 다른 run_id 가 **둘 이상** 보이면 그 응답은 목록 조회로 보고 버린다.
#     한 run 만 담긴 응답(그 run 을 지목해서 부른 결과)은 그대로 관여로 센다.
#
# ⚠ **모델이 쓴 산문은 보지 않는다.** 게이트에 한 번 막힌 세션은 그 run_id 를 답변에 인용하게
#   되고, 산문까지 세면 그 인용이 다음 턴의 「관여」 근거가 된다. 자기 출력을 자기 근거로 삼는
#   부류이고, 같은 함정을 계획 파일 쪽에서도 밟았다(`_planpath.sh` 의 Bash 재지향 · `5b29ada`).
# ⚠ **사람 발화 행도 보지 않는다.** 차단 문구 자체가 사람 발화 행으로 남는다.
# ⚠ `isMeta` 행은 하네스가 넣은 것이라 세션의 행위가 아니다.
#
# 쓰는 법:
#   . "$(dirname "$0")/_runs.sh"
#   session_owns_run "$TR" run_abc123 && …     # rc 0 관여 · 1 남의 것 · 2 판별 불가
#   session_runs "$TR"                         # 진단용 목록 · rc 2 판별 불가

# session_seen <transcript> — 이 세션의 도구 입력·도구 결과를 한 덩어리로. rc 2 면 판별 불가다.
#   ⚠ 매치는 이 덩어리에 대한 **문자열 존재 확인**이다(`session_owns_run`). run_id 의 생김새를
#     정규식으로 좁히지 마라 — 첫 판에 `run_[0-9a-f]+` 로 좁혔더니 실제 Orca 형식(16진)만 맞고
#     대조군 픽스처(`run_x`)가 통과했다. 형식이 바뀌면 **게이트가 조용히 꺼지는** 부류다.
#   ⛔⛔ **jq 가 실패하면 rc 2 다**(2026-09-16 리뷰가 잡았다). 첫 판은 무조건 `return 0` 이었고,
#     그러면 하네스가 transcript 스키마를 바꾸거나 jq 가 중간에 죽었을 때 **빈 재료를 성공으로
#     넘겨** 부르는 쪽이 「좁힐 수 있다」고 믿는다. 그 순간 모든 run 이 「남의 것」이 되어 게이트
#     둘이 동시에 조용히 꺼진다 — 이 파일이 막으려던 바로 그 부류다.
#   ⚠ 다만 **빈 출력 자체는 실패가 아니다**(도구를 안 쓴 세션은 있을 수 있다). 「재료가 비면
#     좁히지 않는다」는 판단은 **부르는 쪽**이 한다 — 게이트가 파일 크기로 그것을 본다.
session_seen() {
  _ss_tr="$1"
  command -v jq >/dev/null 2>&1 || return 2
  [ -n "$_ss_tr" ] && [ -f "$_ss_tr" ] || return 2
  # shellcheck disable=SC2034
  _ss_out=$(jq -rR 'fromjson?
      | select(.isMeta != true)
      | if .type=="assistant" then ("IN\t" + (.message.content[]? | select(.type=="tool_use") | .input | tostring))
        elif (.type=="user" and has("toolUseResult")) then ("OUT\t" + (.toolUseResult | tostring))
        else empty end' "$_ss_tr" 2>/dev/null \
    | python3 -c '
import re, sys
# ⚠ 목록 제외는 **도구 결과**(OUT)에만 건다. 도구 입력(IN)에 run 이 여럿이면 그것은 세션이
#   그 run 들을 **지목한** 것이라 관여가 맞다. 결과 쪽만 전량 목록이 섞여 들어온다.
pat = re.compile(r"run_[A-Za-z0-9_-]+")
for line in sys.stdin:
    kind, _, body = line.partition("\t")
    if kind == "OUT" and len(set(pat.findall(body))) > 1:
        continue
    sys.stdout.write(body)
' 2>/dev/null) || return 2
  [ -n "$_ss_out" ] && printf '%s\n' "$_ss_out"
  return 0
}

# session_owns_run <transcript> <run_id> — rc 0 이 세션의 것 · 1 남의 것 · 2 판별 불가
# ⚠ 매치는 **경계를 붙인 부분 문자열**이다. 맨 `grep -F` 로 두면 `run_1` 이 `run_12` 에 걸려
#   남의 run 으로 막는다(2026-09-16 리뷰가 실측으로 재현했다). 오탐은 사람이 게이트를 끄게
#   만드는 쪽이라 값이 싸지 않다. ⛔ 이것은 식별자의 **형식을 좁히는 것이 아니다** — 어떤
#   글자를 쓰든 앞뒤가 식별자 문자가 아니어야 한다는 것뿐이다.
session_owns_run() {
  _so_tr="$1"; _so_run="$2"
  [ -n "$_so_run" ] || return 2
  _so_seen=$(session_seen "$_so_tr") || return 2
  printf '%s' "$_so_seen" | grep -qE "(^|[^A-Za-z0-9_-])$(printf '%s' "$_so_run" | sed 's/[][\\.*^$/]/\\&/g')([^A-Za-z0-9_-]|$)" && return 0
  return 1
}

# session_runs <transcript> — 진단·보고용 목록(줄마다 하나). rc 2 면 판별 불가다.
#   ⚠ 판정에는 쓰지 마라 — 여기서 쓰는 패턴은 「보이는 것」을 나열할 뿐이고,
#     「이 run 이 이 세션의 것인가」는 `session_owns_run` 이 답한다.
#   ⚠ 목록에 소음이 섞인다. 실측(2026-09-16)에서 `run_id`·`run_main`·`run_in_background` 같은
#     **영어 식별자**가 함께 잡혔다. 「숫자가 없으면 뺀다」로 걸러 봤다가 **되돌렸다** — 진짜
#     식별자가 16진이라 `run_abcdef` 처럼 숫자가 없을 수 있고, 그러면 진단이 진짜를 놓친다.
#     사람이 읽는 목록의 소음보다 **누락이 나쁘다.** 판정은 이 목록을 쓰지 않으므로 게이트
#     동작과는 무관하다.
session_runs() {
  _sr_seen=$(session_seen "$1") || return 2
  printf '%s' "$_sr_seen" | grep -oE 'run_[A-Za-z0-9_-]+' 2>/dev/null | sort -u
  return 0
}

# 직접 실행하면 목록을 낸다(진단용).
# ⛔ `$0` 로 판별하지 마라 — zsh 에서 source 하면 `$0` 이 이 파일이 되어 이 블록이 돌고,
#   `exit 2` 가 **부르는 셸을 통째로 죽인다**(2026-09-16 리뷰가 재현했다). 게이트의
#   `. … || true` 는 `exit` 를 잡지 못한다. bash 에서만 정의되는 `BASH_SOURCE` 로 가른다.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
  session_runs "${1:-}" || { echo "판별 불가(transcript 부재·jq 없음): ${1:-<없음>}" >&2; exit 2; }
fi
