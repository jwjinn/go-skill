#!/usr/bin/env python3
"""`git status --porcelain -z` 출력에서 경로만 한 줄에 하나씩 뽑는다.

왜 별도 파일인가: 셸 안에서 awk 로 마지막 낱말을 뽑던 판이 셋을 놓쳤다 —
공백이 들어간 경로, 이름이 바뀐 항목의 원본 경로, 그리고 접혀서 나오는 untracked
디렉토리다. 레코드 경계가 NUL 이라 셸의 낱말 분리로는 안전하게 다룰 수 없다.

⚠ 이름이 바뀐 항목(`R`·`C`)은 NUL 필드를 **둘** 쓴다. 앞이 새 경로, 뒤가 원본
경로다. 뒤엣것까지 경로로 읽으면 사본에 엉뚱한 파일이 실린다.
"""
import sys


def main() -> int:
    if len(sys.argv) < 2:
        return 64
    with open(sys.argv[1], "rb") as fh:
        fields = fh.read().split(b"\0")

    i = 0
    while i < len(fields):
        rec = fields[i]
        i += 1
        if len(rec) < 4:
            continue
        xy, path = rec[:2], rec[3:]
        if b"R" in xy or b"C" in xy:
            i += 1  # 바로 뒤 필드는 원본 경로다 — 건너뛴다
        if path:
            sys.stdout.buffer.write(path + b"\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
