#!/usr/bin/env bash
# cleanup.sh 의 판정·회수·보존 로직을 스텁(orca·gh)으로 잰다.
# ⭐ 대조군이 있다 — 「게이트가 hold 를 낸다」는 그 게이트를 풀었을 때 ready 가 나와야 참이다.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/cleanup.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# ── 스텁 ────────────────────────────────────────────────────────────────────
mkdir -p "$T/bin"
cat > "$T/bin/orca" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "orchestration worker-list") cat "$STUB_WORKERS" ;;
  "orchestration worker-release") echo '{"ok":true}' ;;
  "worktree rm")
    # 실제 Orca 동작을 흉내낸다: ①미커밋 파일이 하나라도 있으면 거부한다(실측 2026-09-07)
    # ②워크트리를 지우고 **체크아웃된 브랜치도 지운다**.
    p="${4#path:}"
    dirty="$(git -C "$p" status --porcelain -uall 2>/dev/null | head -1)"
    if [ -n "$dirty" ]; then
      printf '{"ok": false, "error": {"message": "Failed to delete worktree at %s. %s"}}\n' "$p" "$dirty"
      exit 1
    fi
    br="$(git -C "$p" symbolic-ref --short -q HEAD 2>/dev/null)"
    common="$(git -C "$p" rev-parse --git-common-dir)"
    case "$common" in /*) ;; *) common="$p/$common" ;; esac
    git -C "$p" worktree remove --force "$p" 2>/dev/null || rm -rf "$p"
    [ -n "$br" ] && git --git-dir="$common" branch -D "$br" >/dev/null 2>&1
    echo '{"ok":true}' ;;
  *) echo '{"ok":true}' ;;
esac
EOF
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh pr list --head <branch> ... → $STUB_PR 파일에서 "<branch> <STATE>" 를 찾는다
br=""; while [ $# -gt 0 ]; do [ "$1" = "--head" ] && br="$2"; shift; done
awk -v b="$br" '$1==b {print $2}' "$STUB_PR"
EOF
chmod +x "$T/bin/orca" "$T/bin/gh"
export ORCA_BIN="$T/bin/orca" GH_BIN="$T/bin/gh"
export STUB_LOG="$T/orca.log" STUB_WORKERS="$T/workers.json" STUB_PR="$T/pr.txt"
export FANOUT_ARCHIVE_DIR="$T/archive"

# ── 가짜 레포 + 워크트리 ─────────────────────────────────────────────────────
REPO="$T/repo"
git init -q -b main "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mk_wt() {  # $1 이름 → 워크트리 경로 출력
  local p="$T/wt/$1"
  git -C "$REPO" worktree add -q -b "feat/$1" "$p" main
  echo "$p"
}
WT_MERGED_CLEAN="$(mk_wt merged-clean)"
WT_MERGED_HARVEST="$(mk_wt merged-harvest)"
WT_MERGED_CODE="$(mk_wt merged-code)"
WT_OPEN="$(mk_wt open-pr)"
WT_RUNNING="$(mk_wt running)"
WT_GONE="$T/wt/gone"   # 만들지 않는다

mkdir -p "$WT_MERGED_HARVEST/.claude" "$WT_MERGED_HARVEST/docs/리뷰-이력"
echo "7절 보고" > "$WT_MERGED_HARVEST/.claude/go-report.md"
echo "라운드" > "$WT_MERGED_HARVEST/docs/리뷰-이력/2026-09.md"
echo "real code" > "$WT_MERGED_CODE/main.go"

cat > "$STUB_PR" <<EOF
feat/merged-clean MERGED
feat/merged-harvest MERGED
feat/merged-code MERGED
feat/open-pr OPEN
feat/running MERGED
EOF

worker() { printf '{"runId":"%s","dispatchId":"%s","workerState":"%s","terminalState":"retained","resource":{"worktreeId":"repo::%s"}}' "$@"; }
write_workers() {  # 인자: worker JSON 들
  local IFS=,; printf '{"ok":true,"result":{"workers":[%s]}}' "$*" > "$STUB_WORKERS"
}
write_workers \
  "$(worker run_A d1 succeeded "$WT_MERGED_CLEAN")" \
  "$(worker run_A d2 succeeded "$WT_MERGED_HARVEST")" \
  "$(worker run_A d3 succeeded "$WT_MERGED_CODE")" \
  "$(worker run_A d4 succeeded "$WT_OPEN")" \
  "$(worker run_A d5 running   "$WT_RUNNING")" \
  "$(worker run_A d6 succeeded "$WT_GONE")" \
  "$(worker run_A d7 succeeded "$WT_MERGED_CLEAN")"

row() { printf '%s\n' "$1" | grep -F "$2" | head -1; }

echo "▶ dry-run 판정"
: > "$STUB_LOG"
OUT="$(bash "$SUT" 2>&1)"; RC=$?
check "t1 미머지 PR → hold"            "row \"\$OUT\" open-pr | grep -q 'hold.*MERGED 가 아니다'" "$OUT"
check "t2 미커밋 코드 → hold"           "row \"\$OUT\" merged-code | grep -q 'hold.*코드 변경 1건'" "$OUT"
check "t3 리뷰이력·보고서만 dirty → ready" "row \"\$OUT\" merged-harvest | grep -q ready" "$OUT"
check "t4 워커 running → hold"           "row \"\$OUT\" running | grep -q 'hold.*settled'" "$OUT"
check "t5 경로 없음 → gone"              "row \"\$OUT\" 'gone ' | grep -q '이미 정리됨'" "$OUT"
check "t6 dry-run 은 rm 을 부르지 않는다" "! grep -q 'worktree rm' \"\$STUB_LOG\" && [ $RC -eq 0 ]" "$(cat "$STUB_LOG")"
check "t6b dry-run 은 아카이브도 만들지 않는다" "[ ! -d \"$FANOUT_ARCHIVE_DIR\" ]"
check "t6c 같은 경로의 두 번째 dispatch 는 dup(release 만)" "grep -c 'merged-clean' <<< \"\$OUT\" | grep -qx 2 && grep -q 'dup .*release 만' <<< \"\$OUT\"" "$OUT"

echo "▶ 대조군 — 게이트를 풀면 hold 가 ready 로 바뀌어야 한다"
sed -i '' 's/^feat\/open-pr OPEN$/feat\/open-pr MERGED/' "$STUB_PR"
rm "$WT_MERGED_CODE/main.go"
OUT2="$(bash "$SUT" 2>&1)"
check "t7a PR 을 MERGED 로 바꾸면 open-pr 이 ready" "row \"\$OUT2\" open-pr | grep -q ready" "$OUT2"
check "t7b 코드 dirty 를 지우면 merged-code 가 ready" "row \"\$OUT2\" merged-code | grep -q ready" "$OUT2"
# 원상 복구
sed -i '' 's/^feat\/open-pr MERGED$/feat\/open-pr OPEN/' "$STUB_PR"
echo "real code" > "$WT_MERGED_CODE/main.go"

echo "▶ --run 필터·gh 부재·orca 무응답"
: > "$STUB_LOG"
bash "$SUT" --run run_X >/dev/null 2>&1
check "t8 --run 이 orca worker-list 에 전달된다" "grep -q 'worker-list --json --run run_X' \"\$STUB_LOG\"" "$(cat "$STUB_LOG")"
OUT3="$(GH_BIN=/nonexistent/gh bash "$SUT" 2>&1)"
check "t9 gh 없으면 머지 판정 불가로 hold(열지 않는다)" "row \"\$OUT3\" merged-clean | grep -q 'hold.*gh 없음'" "$OUT3"
OUT4="$(STUB_WORKERS=/dev/null bash "$SUT" 2>&1)"; RC4=$?
check "t10 orca 가 빈 응답이면 중단(exit≠0)" "[ $RC4 -ne 0 ] && grep -q '중단' <<< \"\$OUT4\"" "$OUT4"

echo "▶ --apply — 회수·release·삭제·브랜치 보존"
: > "$STUB_LOG"
OUT5="$(bash "$SUT" --apply 2>&1)"; RC5=$?
A="$FANOUT_ARCHIVE_DIR/run_A"
check "t11 exit 0"                                   "[ $RC5 -eq 0 ]" "$OUT5"
check "t12 ready 2개만 삭제됐다(rm 호출 2)"           "[ \"\$(grep -c 'worktree rm' \"\$STUB_LOG\")\" = 2 ]" "$(cat "$STUB_LOG")"
check "t13 hold 워크트리는 그대로 있다"              "[ -d \"$WT_MERGED_CODE\" ] && [ -d \"$WT_OPEN\" ] && [ -d \"$WT_RUNNING\" ]"
check "t14 ready 워크트리는 사라졌다"                "[ ! -d \"$WT_MERGED_CLEAN\" ] && [ ! -d \"$WT_MERGED_HARVEST\" ]"
check "t15 아카이브에 go-report.md 가 회수됐다"      "[ -f \"$A/merged-harvest/files/.claude/go-report.md\" ]" "$(find "$A" 2>/dev/null)"
check "t16 아카이브에 리뷰 이력이 회수됐다"          "[ -f \"$A/merged-harvest/files/docs/리뷰-이력/2026-09.md\" ]"
check "t17 아카이브에 git-status·meta 가 있다"       "[ -s \"$A/merged-harvest/git-status.txt\" ] && grep -q 'branch:   feat/merged-harvest' \"$A/merged-harvest/meta.txt\""
check "t18 release 가 ready 각각에 불렸다"           "grep -q 'worker-release --dispatch d1' \"\$STUB_LOG\" && grep -q 'worker-release --dispatch d2' \"\$STUB_LOG\""
check "t18b dup dispatch 도 release 됐고 rm 은 안 늘었다" "grep -q 'worker-release --dispatch d7' \"\$STUB_LOG\"" "$(cat "$STUB_LOG")"
check "t19 ⭐ 브랜치가 남아 있다(스텁 Orca 가 지우려 했는데도)" \
      "git -C \"$REPO\" show-ref --verify -q refs/heads/feat/merged-clean && git -C \"$REPO\" show-ref --verify -q refs/heads/feat/merged-harvest" \
      "$(git -C "$REPO" branch)"
check "t20 출력이 브랜치 보존을 말한다"              "grep -q '브랜치 feat/merged-clean 보존' <<< \"\$OUT5\"" "$OUT5"

echo "▶ 대조군 — 스텁 Orca 가 미커밋 파일을 정말 거부하는가(t14~t16 이 「치운 뒤 삭제」를 증명하려면 필요)"
WT_DIRTY="$(mk_wt dirty-ctrl)"
echo x > "$WT_DIRTY/junk.txt"
"$ORCA_BIN" worktree rm --worktree "path:$WT_DIRTY" --json >/dev/null 2>&1; RCD=$?
check "t20b 미커밋이 있으면 스텁 rm 이 거부한다(exit≠0 · 워크트리 잔존)" "[ $RCD -ne 0 ] && [ -d \"$WT_DIRTY\" ]"

echo "▶ 대조군 — detach 를 빼면 스텁 Orca 가 브랜치를 실제로 지운다(t19 가 살아 있음을 증명)"
WT_CTRL="$(mk_wt ctrl)"
echo "feat/ctrl MERGED" >> "$STUB_PR"
"$ORCA_BIN" worktree rm --worktree "path:$WT_CTRL" --json >/dev/null
check "t21 detach 없이 rm 하면 브랜치가 사라진다" "! git -C \"$REPO\" show-ref --verify -q refs/heads/feat/ctrl" "$(git -C "$REPO" branch)"

echo "▶ 멱등"
OUT6="$(bash "$SUT" --apply 2>&1)"; RC6=$?
check "t22 두 번째 --apply 는 이미 정리된 것을 gone 으로 보고 exit 0" "[ $RC6 -eq 0 ] && row \"\$OUT6\" merged-clean | grep -q gone" "$OUT6"

echo
echo "== ⭐⭐ 대조군 고아(--cg-orphans) — 대조군 스크립트가 남긴 워크트리 (2026-09-16) =="
# Orca 가 만든 것이 아니라 worker-list 에 없고, 그래서 본 경로가 영영 안 본다.
# 실측: 4개 855MB 가 며칠째 남아 있었고 세어 보고서야 알았다.
CG="$(mktemp -d)"; mkdir -p "$CG/cg"
mk_wt(){ # mk_wt <이름> <시간 전> <미커밋 수>
  d="$CG/cg/wt-$1"; mkdir -p "$d"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t \
    && echo base > base.txt && git add base.txt && git commit -qm base ) >/dev/null 2>&1
  i=0; while [ "$i" -lt "$3" ]; do echo x > "$d/dirty$i.txt"; i=$((i+1)); done
  python3 -c 'import os,sys,time;t=time.time()-int(sys.argv[2])*3600;os.utime(sys.argv[1],(t,t))' "$d" "$2"
}
cg_run(){ CLAUDE_CG_ROOTS="$CG/cg" bash "$SUT" --cg-orphans "$@" 2>&1; }

mk_wt old 22 0
out=$(cg_run)
printf '%s' "$out" | grep -q '후보.*wt-old' && ok "6시간 이상 · 미커밋 0 → 후보" || bad "고아 미검출" "$out"
printf '%s' "$out" | grep -q '후보 1개' && ok "개수를 센다" || bad "개수가 틀리다" "$out"

mk_wt fresh 1 0
out=$(cg_run)
printf '%s' "$out" | grep -q '건너뜀.*wt-fresh' && ok "⭐ 6시간 미만은 건너뛴다(아직 쓰는 중일 수 있다)" || bad "신선한 것을 후보로 올렸다" "$out"

mk_wt dirty 30 3
out=$(cg_run)
printf '%s' "$out" | grep -q '⛔ 건너뜀.*wt-dirty.*미커밋 3건' && ok "⛔ 미커밋이 있으면 후보에서 빼고 사유를 말한다" || bad "미커밋을 지우려 한다" "$out"
printf '%s' "$out" | grep -q '건드리지 않음 1개' && ok "건드리지 않은 개수를 따로 센다" || bad "그 개수가 틀리다" "$out"

echo "== ⭐ --apply 는 미커밋 0 인 것만 지운다 =="
out=$(cg_run --apply)
[ -d "$CG/cg/wt-old" ] && bad "미커밋 0 인데 안 지웠다" "$out" || ok "미커밋 0 은 지웠다"
[ -d "$CG/cg/wt-dirty" ] && ok "⛔ 미커밋이 있는 것은 그대로 있다" || bad "미커밋이 있는데 지웠다" "$out"
[ -d "$CG/cg/wt-fresh" ] && ok "신선한 것도 그대로 있다" || bad "신선한 것을 지웠다" "$out"

echo "== ⭐ 같은 디렉토리를 두 번 세지 않는다(심링크) =="
# macOS 에서 /tmp 는 /private/tmp 의 심링크다. 실경로로 정규화하지 않으면 후보가 2배가 된다.
ln -s "$CG/cg" "$CG/cg-link" 2>/dev/null
mk_wt dup 40 0
out=$(CLAUDE_CG_ROOTS="$CG/cg $CG/cg-link" bash "$SUT" --cg-orphans 2>&1)
n=$(printf '%s' "$out" | grep -c '후보 .*wt-dup')
[ "$n" = 1 ] && ok "같은 워크트리를 한 번만 센다" || bad "중복으로 셌다($n회)" "$out"

echo "== ⭐ 사보타주 — 미커밋 판정을 지우면 dirty 도 후보가 된다 =="
# ⚠ 판정은 이제 `_cg.sh` 에 있다(cleanup 과 wave-close 가 공유한다). 사보타주도 그쪽에 건다 —
#   사본을 나란히 두어야 `dirname $0` 으로 찾는다.
mkdir -p "$CG/sab"
cp "$SUT" "$CG/sab/cleanup.sh"
sed 's@if \[ "\$_cg_n" -gt 0 \]; then@if false; then@' "$HERE/_cg.sh" > "$CG/sab/_cg.sh"
out=$(CLAUDE_CG_ROOTS="$CG/cg" bash "$CG/sab/cleanup.sh" --cg-orphans 2>&1)
printf '%s' "$out" | grep -q '후보.*wt-dirty' && ok "사보타주하면 미커밋이 후보로 올라온다(탐지기가 살아 있다)" || bad "사보타주해도 그대로다" "$out"

echo "== ⭐⭐ git 을 못 돌리면 지우지 않는다(모르면 건드리지 않는다) =="
# 실측 부류: dubious ownership·인덱스 손상이면 stdout 이 비어 「미커밋 0」으로 보인다.
mkdir -p "$CG/cg/wt-nogit"
python3 -c 'import os,sys,time;t=time.time()-40*3600;os.utime(sys.argv[1],(t,t))' "$CG/cg/wt-nogit"
out=$(cg_run)
printf '%s' "$out" | grep -q 'git status 를 못 돌렸다' && ok "git 실패를 「모른다」로 분류한다" || bad "git 실패를 미커밋 0 으로 읽었다" "$out"
printf '%s' "$out" | grep -q '후보.*wt-nogit' && bad "git 을 못 돌린 것을 후보로 올렸다" "$out" || ok "⭐ 후보로 올리지 않는다"
out=$(cg_run --apply)
[ -d "$CG/cg/wt-nogit" ] && ok "⛔ --apply 로도 지우지 않는다" || bad "git 을 못 돌린 것을 지웠다" "$out"
rm -rf "$CG"

echo "통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ]
