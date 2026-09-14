#!/usr/bin/env bash
# _deps.sh — 이 체인이 실제로 돌기 위해 필요한 **외부 도구**를 한 자리에 정의한다.
#            실행 파일이 아니라 `source` 로 쓴다(`_planpath.sh` 와 같은 자리다).
#
# ⭐⭐ 왜 이 파일이 생겼나(2026-09-14 실측): `jq` 가 없으면 Stop 게이트 세 축이 **조용히
#   통과한다.** 훅 머리의 `… | jq … || exit 0` 이 「입력이 이상하면 통과」를 뜻하는데,
#   도구 자체가 없을 때도 같은 자리로 떨어진다. 재현했다 — 미완료 2개짜리 계획을 두고
#   PATH 에서 jq 만 뺐더니 `plan-file-gate.sh` 가 **출력 0바이트 · rc=0** 이었다.
#   즉 새 기계에 설치하면 훅이 붙어 있는데 아무것도 막지 않고, 그 사실을 아무도 모른다.
#   이 레포가 반복해서 밟은 「게이트가 조용히 무장해제」 그 부류다.
#
# ⚠ 그래서 여기서 하는 일은 **고치는 것이 아니라 말하는 것**이다. 도구가 없으면 게이트는
#   여전히 통과하지만(관측이 작업을 죽이면 안 된다) **침묵하지 않는다.**
#   침묵하는 fail-open 과 알려진 fail-open 은 다르다.
#
# ⚠⚠ 이 파일은 **jq 도 python3 도 쓰지 않는다.** 없는 도구를 알리는 코드가 그 도구를
#   요구하면 정확히 알려야 할 때 아무 말도 못 한다. JSON 은 손으로 만든다.

# ── 무엇이 필수이고 무엇이 선택인가 ─────────────────────────────────────────
#
# 필수 = 없으면 이 체인의 **어떤 축이 통째로 죽는** 것.
# 선택 = 없으면 기능이 줄지만 체인은 성립하는 것(대체 경로가 코드에 있다).
deps_required_list() { printf 'bash git jq python3'; }
deps_optional_list() { printf 'codex timeout'; }

# deps_role <도구> — 그 도구가 없으면 무엇이 죽는가. ⚠ 「필요하다」가 아니라 **대가**를 적는다.
deps_role() {
  case "$1" in
    bash)    printf '훅·스크립트 전부(실행기 자신)' ;;
    git)     printf '리뷰 범위 산정(diff)·워크트리 판별·계획 소유자 진단' ;;
    jq)      printf '⛔ Stop 게이트 3축(계획 완주 2축·리뷰 반영)과 목표 재주입 — 없으면 조용히 통과한다' ;;
    python3) printf '리뷰 구성 해석·중복 제거·측정·회귀 평가(review/ 전량)' ;;
    codex)   printf '교차 모델 리뷰어. 없으면 preset 을 P1 로 내리고 그 자리를 비운다(리뷰는 돈다)' ;;
    timeout) printf 'codex 호출의 시간 상한. 없으면 상한 없이 부른다(gtimeout 이 있으면 그것을 쓴다)' ;;
    *)       printf '' ;;
  esac
}

# deps_hint <도구> — 설치 방법 한 줄. ⚠ 플랫폼을 단정하지 말고 셋을 나란히 적는다.
deps_hint() {
  case "$1" in
    jq)      printf 'brew install jq   |   apt-get install -y jq   |   dnf install -y jq' ;;
    python3) printf 'brew install python@3.12   |   apt-get install -y python3   |   dnf install -y python3' ;;
    git)     printf 'brew install git   |   apt-get install -y git   |   dnf install -y git' ;;
    codex)   printf 'npm i -g @openai/codex   (설치 뒤 `codex login` 까지 해야 실제로 돈다)' ;;
    timeout) printf 'brew install coreutils   (gtimeout 로 깔린다 — 이 체인이 자동으로 찾는다)   |   리눅스는 기본 포함' ;;
    bash)    printf '이 스크립트가 돌고 있다면 있다' ;;
    *)       printf '' ;;
  esac
}

# deps_missing <도구 목록> — 그중 **없는 것만** 공백으로 이어 출력한다(없으면 빈 출력).
deps_missing() {
  _dm_out=''
  for _dm_c in $1; do
    command -v "$_dm_c" >/dev/null 2>&1 || _dm_out="$_dm_out $_dm_c"
  done
  printf '%s' "${_dm_out# }"
}

# deps_timeout_cmd — 쓸 수 있는 타임아웃 명령 이름(없으면 빈 출력).
#
# ⚠ macOS 는 `timeout` 이 **기본에 없다**(coreutils 를 깔면 `gtimeout` 으로 들어온다).
#   이름 하나만 보고 부르면 rc=127 로 죽고, 호출부는 그것을 「codex 가 실패했다」로 읽는다 —
#   「틀린 사유는 없는 것보다 나쁘다」.
deps_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'
  else printf ''; fi
}

# ── 알림 — 같은 말을 매 턴 반복하지 않는다 ──────────────────────────────────
#
# ⚠ 소음이면 사람이 훅을 끈다(그러면 게이트가 통째로 사라진다). 그래서 슬롯마다 TTL 을 둔다.
#   TTL 0 은 「항상 알린다」이고 테스트가 그것을 쓴다.
# ⚠ 스탬프는 **레포별**이다 — 전역 하나면 다른 레포에서 알린 것이 여기서 「알렸음」이 된다.
deps_notice_once() {          # <슬롯> [TTL초] → rc 0 지금 알려라 / rc 1 최근에 알렸다
  _dn_slot="$1"
  _dn_ttl="${2:-${CLAUDE_DEPS_NOTICE_TTL:-3600}}"
  case "$_dn_ttl" in ''|*[!0-9]*) _dn_ttl=3600 ;; esac
  [ "$_dn_ttl" -eq 0 ] && return 0
  _dn_key=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}" | cksum 2>/dev/null | cut -d' ' -f1)
  _dn_f="${TMPDIR:-/tmp}/claude-go-deps-${_dn_slot}-${_dn_key:-x}"
  _dn_now=$(date +%s 2>/dev/null || printf '0')
  if [ -f "$_dn_f" ]; then
    _dn_was=$(cat "$_dn_f" 2>/dev/null)
    case "${_dn_was:-x}" in ''|*[!0-9]*) _dn_was=0 ;; esac
    [ $((_dn_now - _dn_was)) -lt "$_dn_ttl" ] && return 1
  fi
  printf '%s' "$_dn_now" > "$_dn_f" 2>/dev/null
  return 0
}

# deps_json_escape <문자열> — JSON 문자열 값으로 넣을 수 있게 이스케이프한다.
#
# ⚠ jq 없이 JSON 을 만드는 자리다. 역슬래시 → 따옴표 → 개행 순서를 지켜라(뒤집으면
#   우리가 넣은 이스케이프를 다시 이스케이프한다).
deps_json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' \
    | awk 'BEGIN{ORS=""} NR>1{printf "\\n"} {print}'
}

# deps_jq_missing_notice <훅 이름> — jq 부재를 Stop 훅의 systemMessage 로 알린다.
#
# ⚠ `decision:"block"` 이 아니라 **알림**이다. 도구가 없는 것은 사람이 고쳐야 하는 일이고,
#   그 상태에서 턴을 막으면 작업이 통째로 서 버린다(관측이 서비스를 죽이는 부류).
deps_jq_missing_notice() {
  deps_notice_once "jq" || return 0
  _dj_msg="[go-review] ⛔ \`jq\` 가 없다. 그래서 이번 턴에 다음 축이 무장되지 않았다:
    $1
  이 상태에서는 미완료 계획이 남아 있어도 턴이 그냥 끝난다. 게이트가 「통과」한 것이 아니라
  **아무것도 보지 않았다** — 조용한 통과와 검사한 통과를 같은 것으로 읽지 마라.
  설치: $(deps_hint jq)
  확인: bash \"\${CLAUDE_PLUGIN_ROOT:-<플러그인 루트>}/scripts/deps-check.sh\""
  printf '{"systemMessage":"%s"}\n' "$(deps_json_escape "$_dj_msg")"
}

# deps_jq_missing_text <무엇이 죽나> — 평문 stdout 이 곧 문맥인 이벤트(UserPromptSubmit)용.
deps_jq_missing_text() {
  deps_notice_once "jq" || return 0
  printf '[go-review] ⛔ `jq` 가 없다. 그래서 이번 턴에 동작하지 않은 것: %s — 설치: %s\n' "$1" "$(deps_hint jq)"
}
