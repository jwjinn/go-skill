#!/usr/bin/env bash
# _sem.sh — 동시 호출 슬롯. `source` 로 쓴다.
#
# 왜 필요한가: 서빙은 GPU 1개에 한 모델이다. fan-out 워커 N 명이 각자 테스트 에이전트를
#   부르면 그 전부가 같은 GPU 로 간다. 실측(2026-09-15)에서 짧은 작업은 동시 12까지
#   실패 0 이었지만 지연이 4배가 됐고, **긴 작업의 동시성은 재지 않았다.**
#   재지 않은 구간에 여유를 두는 것이 이 파일의 목적이다.
#
# 구현: `mkdir` 는 원자적이다(존재하면 실패). 파일 락보다 이식성이 좋고 NFS 에서도 맞다.
#
# ⛔ 종전 판에는 경쟁 조건이 있었다(리뷰가 지목): `mkdir slot-N` 과 `echo $$ > slot-N/pid`
#   사이에 창이 있어서, 그 사이 다른 프로세스의 `sem_reap` 이 **pid 없는 새 슬롯을 죽은
#   슬롯으로 보고 지웠다.** 그러면 둘이 같은 슬롯을 잡았다고 믿고 상한이 조용히 초과된다.
#   ⇒ pid 를 **먼저** 쓰고 `mv` 로 자리를 잡는다(rename 도 원자적이다).
#   ⇒ 그래도 남는 창(회수 판정과 mv 사이)을 위해, 회수는 **생성 후 유예 시간이 지난** 슬롯만 한다.

SEM_DIR="${TMPDIR:-/tmp}/go-tester/sem"
SEM_REAP_GRACE="${SEM_REAP_GRACE:-30}"   # 초. pid 가 아직 없는 슬롯을 이 시간 전에는 건드리지 않는다

sem_acquire() { # sem_acquire <최대> <대기초> → 획득한 슬롯 경로를 SEM_SLOT 에 담는다
  local max="${1:-4}" waitfor="${2:-600}" i waited=0 stage
  mkdir -p "$SEM_DIR"
  while :; do
    sem_reap "$max"
    i=1
    while [ "$i" -le "$max" ]; do
      if [ ! -e "$SEM_DIR/slot-$i" ]; then
        # pid 를 담은 디렉토리를 먼저 완성하고, 그것을 슬롯 자리로 **rename** 한다.
        stage="$SEM_DIR/.stage-$$-$i"
        rm -rf "$stage" 2>/dev/null
        if mkdir "$stage" 2>/dev/null; then
          echo $$ > "$stage/pid"
          if mv "$stage" "$SEM_DIR/slot-$i" 2>/dev/null; then
            # ⚠ rename 은 대상이 있으면 **덮어쓸 수 있다** — 잡았는지 pid 로 확인한다.
            if [ "$(cat "$SEM_DIR/slot-$i/pid" 2>/dev/null)" = "$$" ]; then
              SEM_SLOT="$SEM_DIR/slot-$i"
              return 0
            fi
          fi
          rm -rf "$stage" 2>/dev/null
        fi
      fi
      i=$((i+1))
    done
    if [ "$waited" -ge "$waitfor" ]; then
      SEM_SLOT=""
      return 1
    fi
    sleep 2; waited=$((waited+2))
  done
}

sem_release() {
  # ⚠ **내 슬롯일 때만** 지운다. 남의 슬롯을 지우면 상한이 무너진다.
  if [ -n "${SEM_SLOT:-}" ] && [ "$(cat "${SEM_SLOT}/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$SEM_SLOT"
  fi
  SEM_SLOT=""
}

sem_reap() { # 죽은 슬롯 회수 — pid 가 살아 있지 않으면 슬롯을 연다
  local max="${1:-4}" i=1 p age now mtime
  now=$(date +%s)
  while [ "$i" -le "$max" ]; do
    if [ -d "$SEM_DIR/slot-$i" ]; then
      p=$(cat "$SEM_DIR/slot-$i/pid" 2>/dev/null)
      if [ -n "$p" ]; then
        kill -0 "$p" 2>/dev/null || rm -rf "$SEM_DIR/slot-$i"
      else
        # pid 가 없다 — 초기화 중일 수 있으므로 **유예 시간이 지난 것만** 회수한다.
        mtime=$(stat -f %m "$SEM_DIR/slot-$i" 2>/dev/null || stat -c %Y "$SEM_DIR/slot-$i" 2>/dev/null || echo "$now")
        age=$((now - mtime))
        [ "$age" -ge "$SEM_REAP_GRACE" ] && rm -rf "$SEM_DIR/slot-$i"
      fi
    fi
    i=$((i+1))
  done
  # 버려진 stage 디렉토리도 유예 뒤 거둔다(획득 도중에 죽은 프로세스의 잔재).
  for stage in "$SEM_DIR"/.stage-*; do
    [ -d "$stage" ] || continue
    mtime=$(stat -f %m "$stage" 2>/dev/null || stat -c %Y "$stage" 2>/dev/null || echo "$now")
    [ $((now - mtime)) -ge "$SEM_REAP_GRACE" ] && rm -rf "$stage"
  done
}

sem_count() { # 지금 잡힌 슬롯 수
  ls -d "$SEM_DIR"/slot-* 2>/dev/null | wc -l | tr -d ' '
}
