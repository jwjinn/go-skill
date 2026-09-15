#!/usr/bin/env python3
"""워커 워크트리들의 변경 파일 집합에서 **진짜 교차**만 센다.

# 왜 별도 파일인가 (2026-09-15 실측)

셸에서 `cat 모아서 sort | uniq -d` 로 세던 판이 **거짓 양성 셋**을 냈다. 한 워커만 건드린
파일 셋(`docs/배포/설치-시험-…`, 목업 대응표 둘)이 교차로 보고됐다. 전부 **한글 경로**다.
이 저장소가 여러 번 밟은 「git 비ASCII 경로」 부류의 새 변종이다.

⇒ 여기서 셋을 지킨다.
  ① **워크트리 안에서 먼저 중복을 없앤다.** 한 워크트리가 같은 경로를 두 번 내면 그것은
     교차가 아니다(교차는 **다른 워커끼리**여야 한다).
  ② **유니코드 정규화를 맞춘다.** macOS 파일시스템은 NFD, git 저장은 NFC 인 경우가 있어
     겉보기가 같은 경로가 다른 바이트로 나온다. 비교 전에 NFC 로 모은다.
  ③ **공용 산출물과 소스를 가른다.** 리뷰 원장·종료 보고·게이트 파일은 워커 전원이 건드리는
     것이 정상이고 「합치는 대상」이지 충돌이 아니다. 섞어 세면 이 검사가 언제나 붉어지고,
     언제나 붉은 검사는 아무도 안 본다.

출력: 첫 줄 `SHARED <n>`, 그 뒤 소스 교차를 `<경로>\t<워커,워커>` 로 한 줄씩.
종료: 0 소스 교차 없음 · 1 있음 · 2 잴 수 없음.
"""
import collections
import pathlib
import re
import subprocess
import sys
import unicodedata

SHARED_RE = re.compile(r"^(\.claude/(go-report\.md|tester/|hooks/)|docs/리뷰-이력/)")


def main() -> int:
    if len(sys.argv) < 3:
        print("사용: _crossing.py <base ref> <워크트리 경로...>", file=sys.stderr)
        return 2

    base, wts = sys.argv[1], sys.argv[2:]
    owners = collections.defaultdict(set)
    measured = 0

    for wt in wts:
        p = pathlib.Path(wt)
        if not p.is_dir():
            continue
        r = subprocess.run(
            ["git", "-C", str(p), "-c", "core.quotePath=false",
             "diff", "--name-only", base + "...HEAD"],
            capture_output=True, text=True)
        if r.returncode != 0:
            continue
        measured += 1
        name = p.name
        # ① 워크트리 안에서 먼저 집합으로 모은다 · ② NFC 로 정규화한다
        for line in {unicodedata.normalize("NFC", x) for x in r.stdout.splitlines() if x.strip()}:
            owners[line].add(name)

    if measured == 0:
        print("측정한 워크트리가 없다", file=sys.stderr)
        return 2

    crossed = {p: ws for p, ws in owners.items() if len(ws) > 1}
    shared = {p: ws for p, ws in crossed.items() if SHARED_RE.match(p)}
    real = {p: ws for p, ws in crossed.items() if p not in shared}

    print("SHARED %d" % len(shared))
    for p in sorted(real):
        print("%s\t%s" % (p, ",".join(sorted(real[p]))))
    return 1 if real else 0


if __name__ == "__main__":
    sys.exit(main())
