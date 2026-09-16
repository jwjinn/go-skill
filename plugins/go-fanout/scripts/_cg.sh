#!/usr/bin/env bash
# _cg.sh — 「대조군 스크립트가 남긴 워크트리」를 한 곳에서 찾는다.
#
# ⭐⭐ 왜 함수로 뺐나 (2026-09-16 리뷰가 지적했다): 이 판정을 둘이 쓴다 — `wave-close.sh` 의 ⑥
#   축이 **세어서 보고**하고, `cleanup.sh --cg-orphans` 가 **지운다**. 같은 사실을 두 곳이 각자
#   판단하면 한쪽만 고쳤을 때 「보고한 수」와 「지운 수」가 갈라지고, 그 어긋남은 「개수를 세라」를
#   탐지 수단으로 쓰는 이 체인에서 가장 알아채기 어렵다. `_runs.sh` 를 뺀 것과 같은 이유다.
#
# cg_candidates — 줄마다 `<상태>\t<경로>\t<시간>\t<미커밋수>`
#   상태: `cand`(후보 · 미커밋 0) · `dirty`(미커밋 있음) · `unknown`(git 을 못 돌렸다) · `fresh`(너무 최근)
#
# ⚠ macOS 에서 `/tmp` 는 `/private/tmp` 의 심링크다. 둘을 다 훑으면 **같은 워크트리를 두 번**
#   세고(실측 2026-09-16: 후보 2개가 4개로 보고됐다) `--apply` 가 두 번째에서 실패한다.
#   실경로로 정규화해 중복을 지운다.
# ⛔ **git 을 못 돌렸으면 「미커밋 0」이 아니다.** 파이프 뒤에서 판정을 읽으면 dubious ownership
#   같은 실패가 0 으로 보이고, 「미커밋이 있으면 지우지 않는다」는 보호가 통째로 열린다.

cg_candidates() {
  _cg_roots="${CLAUDE_CG_ROOTS:-/private/tmp/go-tester/cg /tmp/go-tester/cg}"
  _cg_hours="${CLAUDE_CG_ORPHAN_HOURS:-6}"
  _cg_seen=''
  for _cg_root in $_cg_roots; do
    [ -d "$_cg_root" ] || continue
    for _cg_raw in "$_cg_root"/wt-*; do
      [ -d "$_cg_raw" ] || continue
      _cg_wt=$(cd "$_cg_raw" 2>/dev/null && pwd -P) || _cg_wt="$_cg_raw"
      case " $_cg_seen " in *" $_cg_wt "*) continue ;; esac
      _cg_seen="$_cg_seen $_cg_wt"

      _cg_age=$(python3 -c 'import os,sys,time;print(int((time.time()-os.path.getmtime(sys.argv[1]))//3600))' "$_cg_wt" 2>/dev/null || echo 0)
      case "$_cg_age" in ''|*[!0-9]*) _cg_age=0 ;; esac
      if [ "$_cg_age" -lt "$_cg_hours" ]; then
        printf 'fresh\t%s\t%s\t0\n' "$_cg_wt" "$_cg_age"; continue
      fi

      _cg_out=$(git -C "$_cg_wt" status --porcelain 2>/dev/null); _cg_rc=$?
      if [ "$_cg_rc" -ne 0 ]; then
        printf 'unknown\t%s\t%s\t-1\n' "$_cg_wt" "$_cg_age"; continue
      fi
      _cg_n=$(printf '%s' "$_cg_out" | grep -c . || true)
      case "$_cg_n" in ''|*[!0-9]*) _cg_n=0 ;; esac
      if [ "$_cg_n" -gt 0 ]; then
        printf 'dirty\t%s\t%s\t%s\n' "$_cg_wt" "$_cg_age" "$_cg_n"
      else
        printf 'cand\t%s\t%s\t0\n' "$_cg_wt" "$_cg_age"
      fi
    done
  done
}

# cg_remove <경로> — 후보 하나를 지운다. rc 0 지웠다 · 1 실패.
#   ⚠ 부르는 쪽이 「후보인지」를 먼저 확인해야 한다. 이 함수는 판정하지 않는다.
cg_remove() {
  _cg_t="$1"
  _cg_main=$(git -C "$_cg_t" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's@/\.git$@@')
  if [ -n "$_cg_main" ] && [ -d "$_cg_main" ] && git -C "$_cg_main" worktree remove --force "$_cg_t" >/dev/null 2>&1; then
    return 0
  fi
  rm -rf "$_cg_t" 2>/dev/null && return 0
  return 1
}
