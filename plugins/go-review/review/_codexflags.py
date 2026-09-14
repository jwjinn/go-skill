# -*- coding: utf-8 -*-
"""스킬 문서에 **읽기 전용 플래그 없는 `codex exec`** 가 남아 있는지 본다.

⭐ 왜 문서를 검사하나: 래퍼(`codex-ro.sh`)가 있어도 스킬이 `codex exec` 를 직접 부르면
   통제가 없는 것과 같다. Claude 리뷰어는 frontmatter `tools:` 로 쓰기 도구가 **부재**해서
   구조적으로 읽기 전용이지만, codex 는 플래그 하나에 얹혀 있다 — 그 플래그를 빼먹는
   경로를 **문서 축에서** 막는다.

⚠ 줄 단위 grep 은 쓸 수 없다: 플래그가 **다음 줄**에 오는 명령(백슬래시 연결)을 오탐한다.
  그래서 연결을 먼저 펴고 명령 단위로 본다("탐지기를 먼저 의심하라").

사용: python3 _codexflags.py <검사할 디렉토리...>   → 위반을 줄로 출력, 없으면 무출력
"""
import io
import os
import re
import sys

SAFE = ("sandbox_mode", "codex-ro")     # 플래그를 달았거나 래퍼를 쓴다
# 산문 속 언급(백틱 인용)은 실행이 아니다. 단, 셸 치환이 섞이면 실행문으로 본다.
PROSE = re.compile(r"`codex exec[^`]*`")
JOIN = re.compile(r"\\\n[ \t]*")        # 백슬래시 줄 연결


def violations(paths):
    out = []
    for base in paths:
        for root, _, files in os.walk(base):
            for fn in sorted(files):
                if not fn.endswith(".md"):
                    continue
                p = os.path.join(root, fn)
                try:
                    txt = io.open(p, encoding="utf-8").read()
                except Exception:
                    continue
                for i, line in enumerate(JOIN.sub(" ", txt).split("\n"), 1):
                    if "codex exec" not in line:
                        continue
                    if any(s in line for s in SAFE):
                        continue
                    if PROSE.search(line) and "$(" not in line:
                        continue
                    out.append("%s:%d: %s" % (os.path.basename(p), i, line.strip()[:110]))
    return out


if __name__ == "__main__":
    v = violations(sys.argv[1:])
    if v:
        print("\n".join(v))
    sys.exit(0)
