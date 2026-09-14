#!/usr/bin/env bash
# _sem.sh — 동시 호출 슬롯. `source` 로 쓴다.
#
# 왜 필요한가: 서빙은 GPU 1개에 한 모델이다. fan-out 워커 N 명이 각자 테스트 에이전트를
#   부르면 그 전부가 같은 GPU 로 간다. 실측(2026-09-15)에서 짧은 작업은 동시 12까지
#   실패 0 이었지만 지연이 4배가 됐고, **긴 작업의 동시성은 재지 않았다.**
#   재지 않은 구간에 여유를 두는 것이 이 파일의 목적이다.
#
# 구현: `mkdir` 는 원자적이다(존재하면 실패). 파일 락보다 이식성이 좋고 NFS 에서도 맞다.
# ⚠ 죽은 슬롯을 회수한다 — 프로세스가 죽으면 슬롯이 영영 잠기고, 그러면 상한이 0이 된다.

SEM_DIR="${TMPDIR:-/tmp}/go-tester/sem"

sem_acquire() { # sem_acquire <최대> <대기초> → 획득한 슬롯 경로를 SEM_SLOT 에 담는다
  local max="${1:-4}" waitfor="${2:-600}" i waited=0
  mkdir -p "$SEM_DIR"
  while :; do
    sem_reap "$max"
    i=1
    while [ "$i" -le "$max" ]; do
      if mkdir "$SEM_DIR/slot-$i" 2>/dev/null; then
        echo $$ > "$SEM_DIR/slot-$i/pid"
        SEM_SLOT="$SEM_DIR/slot-$i"
        return 0
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
  [ -n "${SEM_SLOT:-}" ] && rm -rf "$SEM_SLOT"
  SEM_SLOT=""
}

sem_reap() { # 죽은 슬롯 회수 — pid 가 살아 있지 않으면 슬롯을 연다
  local max="${1:-4}" i=1 p
  while [ "$i" -le "$max" ]; do
    if [ -d "$SEM_DIR/slot-$i" ]; then
      p=$(cat "$SEM_DIR/slot-$i/pid" 2>/dev/null)
      if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then
        rm -rf "$SEM_DIR/slot-$i"
      fi
    fi
    i=$((i+1))
  done
}

sem_count() { # 지금 잡힌 슬롯 수
  ls -d "$SEM_DIR"/slot-* 2>/dev/null | wc -l | tr -d ' '
}
