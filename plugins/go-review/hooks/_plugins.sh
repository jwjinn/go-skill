#!/usr/bin/env bash
# _plugins.sh — **형제 플러그인**의 설치 위치를 찾는다. `source` 로 쓴다(실행 파일이 아니다).
#
# ⭐⭐ 왜 생겼나(2026-09-16 실측): go-review 는 자기 일만 하지 않는다 — 테스트를 `go-tester` 에
#   위임하고, 자원 회수를 `go-fanout` 에 넘긴다. 그런데 그 둘을 찾는 코드·문서 **아홉 자리**가
#   `~/.claude/skills/<이름>` 을 **고정 문자열**로 적고 있었다. 그 경로는 이 기계의 설치 방식
#   (심링크)에만 있다. 마켓플레이스로 받으면 파일은 `~/.claude/plugins/cache/<마켓>/<플러그인>/
#   <버전>/` 에 놓이므로 **없는 경로를 보게 되고**, go-tester 는 「없음」으로 판정돼 위임이
#   조용히 rc 70(안 쓰는 쪽)으로 닫힌다. 켰다고 믿는 사람에게는 아무 신호도 없다.
#
# ⭐ 핵심 사실 하나로 푼다: **셋은 한 저장소·한 마켓플레이스에서 나오므로 언제나 형제다.**
#   그래서 내 루트의 형제를 보면 된다 — 설치 방식마다 「형제」의 모양만 다르다.
#
#     심링크(@skills-dir) : ~/.claude/skills/go-review        → ../go-tester
#     마켓플레이스        : …/cache/<마켓>/go-review/<버전>   → ../../go-tester/<버전>
#
# ⚠ **이름만 맞으면 채택하지 않는다.** 두 번째 인자로 「그 안에 있어야 하는 파일」을 받아
#   그것까지 확인한다. 빈 껍데기 디렉토리(설치 중단·이름만 같은 남의 디렉토리)를 찾았다고
#   말하면 호출부가 그 경로로 스크립트를 부르고, 그때 나오는 오류는 원인을 가리키지 않는다.
#   「틀린 사유는 없는 것보다 나쁘다」.
#
# 용법:
#   . "$(dirname "$0")/_plugins.sh"
#   tt=$(sibling_plugin go-tester tester/_config.py) || tt=""
#
# 반환: 경로를 stdout 에 출력하고 rc 0 · 못 찾으면 빈 출력에 rc 1.

# sibling_plugin <플러그인 이름> [확인용 상대 경로]
sibling_plugin() {
  _sp_name="${1:-}"; _sp_probe="${2:-}"
  [ -n "$_sp_name" ] || return 1

  # 내 플러그인 루트 — 하네스가 주면 그것을, 아니면 자기 위치에서(hooks/ 의 부모).
  # ⚠ 상태가 아니라 **코드**의 위치를 구하는 자리다. `_planpath.sh` 의 반대편 규약이고,
  #   그 파일 머리말이 그 둘을 섞지 말라고 적어 둔 그 구분이다.
  _sp_self="${CLAUDE_PLUGIN_ROOT:-}"
  if [ -z "$_sp_self" ]; then
    _sp_self=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd) || _sp_self=""
  fi

  # 후보를 가까운 것부터. ⚠ 순서가 계약이다 — 심링크(개발본)가 마켓플레이스 사본을 이긴다.
  #   한 기계에 둘 다 있으면 사람이 고치고 있는 쪽이 심링크이고, 그쪽이 정본이다.
  for _sp_c in \
      ${_sp_self:+"$_sp_self/../$_sp_name"} \
      ${_sp_self:+"$_sp_self"/../../"$_sp_name"/*/} \
      "$HOME/.claude/skills/$_sp_name" \
      "$HOME"/.claude/plugins/cache/*/"$_sp_name"/*/ ; do
    [ -d "$_sp_c" ] || continue
    if [ -n "$_sp_probe" ]; then
      [ -e "$_sp_c/$_sp_probe" ] || continue
    fi
    # 끝의 `/` 를 떼고 **정규화해서** 돌려준다. `…/go-review/../go-tester` 처럼 되돌아가는
    # 경로를 그대로 주면 사람이 읽는 안내 문구에 그 모양이 그대로 실린다.
    _sp_c="${_sp_c%/}"
    _sp_abs=$(CDPATH='' cd -- "$_sp_c" 2>/dev/null && pwd) || _sp_abs="$_sp_c"
    printf '%s' "$_sp_abs"
    return 0
  done
  return 1
}

# ── 실행도 된다 — 문서(마크다운)가 함수를 source 하지 않고 부를 수 있게 ──────────────
#
# ⚠ 지시문에서 쓰는 형태가 함수든 명령이든 **정본은 이 파일 하나**여야 한다. 문서마다 탐색
#   한 줄을 복사해 두면 설치 모양이 하나 늘 때 그 전부를 고쳐야 하고, 반드시 한둘을 놓친다
#   (이 저장소가 19행 밟은 「정본이 둘」).
#
#   bash <go-review 루트>/hooks/_plugins.sh go-tester tester/_config.py
#
# `source` 로 읽힐 때는 아무 일도 하지 않는다.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  sibling_plugin "$@"
  exit $?
fi
