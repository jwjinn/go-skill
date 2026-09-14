# -*- coding: utf-8 -*-
"""리뷰 대상의 크기를 재고 **나눌지 말지를 말한다.**

⭐ 왜 스크립트인가: 「크면 나눠라」를 산문으로 두면 그것은 **규율**이고, 모델이 재지 않고
   넘어가면 아무 일도 일어나지 않는다. 재서 숫자로 말하면 **구조**다.
   (규약: 「집행은 규율이 아니라 구조다」)

⚠⚠ **임계값은 아직 추측이다.** 근거는 라운드 1 하나뿐이다 — 1,335줄에 리뷰어당 ~120K 토큰,
   그중 입력이 ~25K(diff ~19K)였다. 거기서 「4,000줄이면 diff 만 ~230K 라 리뷰어가 다 들고
   판단하지 못한다」를 외삽해 2,000 을 잡았다. **외삽이지 측정이 아니다.**
   ⭐ 교정 경로: `verdict.sh` 판정이 쌓이면 `measure.sh` 가 「diff 크기 ↔ 정밀도」를
     상관 지어 진짜 임계를 말할 수 있다. 그때까지 이 숫자를 근거로 인용하지 마라.

⚠ 나누는 단위는 **커밋**이지 파일이 아니다. 파일로 자르면 한 단계가 두 라운드에 걸쳐
   쪼개져 리뷰어가 그 변경의 의도를 못 본다. 그래서 커밋 경계에서만 자를 곳을 제안한다.
"""
import io
import os
import re
import subprocess
import sys

# ⭐ 2026-09-13 사용자 결정: 「리뷰 상한은 없애죠.」
# 종전 기본은 2000 줄이었고, 넘으면 「나누기를 권한다」로 커밋 경계 분할을 제안했다. 그 숫자는
# 라운드 1에서 외삽한 추측이었고(근거는 비용이 아니라 「리뷰어가 한 번에 들고 판단할 양」), 실제로
# 쌓인 판정으로 교정된 적이 없다. 반면 분할의 대가는 실측됐다 — 2026-09-13 야간 실행에서 합본을
# 워커 경계로 4라운드로 자르자 라운드 고정비를 네 번 냈고, 경계에 걸친 통합 결함을 볼 자리가
# 사라졌다(합본 라운드의 존재 이유가 바로 그 자리다).
# ⇒ 기본은 **무제한**이다. 숫자를 넣고 싶으면 CLAUDE_REVIEW_SPLIT_LINES 로 명시해라.
_raw_max = os.environ.get("CLAUDE_REVIEW_SPLIT_LINES", "0").strip()
DEFAULT_MAX = int(_raw_max) if _raw_max.isdigit() else 0
BYTES_PER_TOKEN = 4.0   # 코드 diff 기준 어림. 라운드 1 실측과 맞다(75,558B ≈ 19K 토큰)


def sh(args, cwd=None):
    try:
        return subprocess.check_output(args, cwd=cwd, stderr=subprocess.DEVNULL).decode("utf-8", "replace")
    except Exception:
        return ""


def measure(patch_path):
    """diff 파일에서 변경 줄 수와 파일 수를 센다."""
    if not os.path.exists(patch_path):
        return None
    txt = io.open(patch_path, encoding="utf-8", errors="replace").read()
    # ⚠ `+++`/`---` 헤더는 변경 줄이 아니다 — 그것까지 세면 파일 수만큼 부풀려진다.
    add = len(re.findall(r"^\+(?!\+\+ )", txt, re.M))
    dele = len(re.findall(r"^-(?!-- )", txt, re.M))
    files = len(re.findall(r"^\+\+\+ ", txt, re.M))
    return {"changed": add + dele, "add": add, "del": dele,
            "files": files, "bytes": len(txt.encode("utf-8"))}


def commit_sizes(base, head, cwd):
    """커밋마다 그 커밋의 변경 줄 수 — 자를 곳을 커밋 경계에서만 찾기 위해."""
    log = sh(["git", "log", "--reverse", "--format=%H\t%s", "%s..%s" % (base, head)], cwd)
    out = []
    for line in log.splitlines():
        if "\t" not in line:
            continue
        sha, subj = line.split("\t", 1)
        st = sh(["git", "show", "--stat", "--format=", sha], cwd).strip().splitlines()
        n = 0
        if st:
            m = re.search(r"(\d+) insertion", st[-1])
            n += int(m.group(1)) if m else 0
            m = re.search(r"(\d+) deletion", st[-1])
            n += int(m.group(1)) if m else 0
        out.append((sha[:8], subj, n))
    return out


def main():
    patch = sys.argv[1]
    base = sys.argv[2] if len(sys.argv) > 2 else "main"
    head = sys.argv[3] if len(sys.argv) > 3 else "HEAD"
    cwd = sys.argv[4] if len(sys.argv) > 4 else None

    m = measure(patch)
    if not m:
        print("diff 파일이 없다: %s" % patch)
        return 1

    est = int(m["bytes"] / BYTES_PER_TOKEN)
    print("리뷰 대상 — %s" % patch)
    print("  변경 %d줄 (+%d / -%d) · 파일 %d개 · %.0f KB"
          % (m["changed"], m["add"], m["del"], m["files"], m["bytes"] / 1024.0))
    print("  리뷰어 1명당 diff 입력 추정 **~%s 토큰** (어림 — 코드 기준 4B/토큰)"
          % "{:,}".format(est))
    print()

    if DEFAULT_MAX <= 0:
        print("⭐ **한 라운드로 간다 — 분할 상한이 없다**(2026-09-13 사용자 결정: 「리뷰 상한은 없애죠」)")
        print("   %d줄을 한 라운드가 본다. 나누면 라운드 고정비를 그 횟수만큼 내고," % m["changed"])
        print("   **경계에 걸친 통합 결함을 볼 자리가 사라진다** — 합본 라운드의 존재 이유가 그 자리다.")
        print("   ⚠ 그래도 리뷰어가 한 번에 전부 읽지는 못한다. 브리핑에 **어디부터 보라**를 적어라")
        print("     (통합 지점·경계 파일·아무도 안 본 커밋). 좁혀 읽기는 리뷰어의 몫이고, 그 순서는 네 몫이다.")
        print("   숫자를 다시 쓰려면 CLAUDE_REVIEW_SPLIT_LINES=<줄수> 로 명시해라.")
        return 0

    if m["changed"] <= DEFAULT_MAX:
        print("⭐ **한 라운드로 충분하다** (%d줄 ≤ 상한 %d)" % (m["changed"], DEFAULT_MAX))
        print("   나누면 라운드 고정비(브리핑·역할 정본·병합자 기동)만 20~30% 더 든다.")
        print("   ⚠ diff 총량은 나눠도 같다 — 늘어나는 것은 그 고정비뿐이다.")
        return 0

    print("⚠ **상한 초과 — 나누기를 권한다** (%d줄 > %d)" % (m["changed"], DEFAULT_MAX))
    print("   이유는 비용이 아니라 **품질**이다. 리뷰어가 한 번에 들고 판단할 수 있는 양을")
    print("   넘으면 주의가 희석되고, 그 지점부터는 라운드를 더 도는 편이 싸다.")
    print()

    cs = commit_sizes(base, head, cwd)
    if not cs:
        print("   ⚠ %s..%s 사이에 커밋이 없다 — 자를 곳을 제안하지 못한다." % (base, head))
        print("      (base 를 실제 분기점으로 주면 커밋 경계를 제안한다:")
        print("       python3 _scope.py <patch> <base> <head> <repo>)")
        print("   ⚠⚠ **파일 단위로 자르지 마라** — 한 단계가 두 라운드에 걸쳐 쪼개지면")
        print("      리뷰어가 그 변경의 의도를 못 본다. 커밋 경계에서 잘라라.")
        return 0

    print("   커밋 %d개. 누적이 상한의 절반을 넘는 지점에서 자르면:" % len(cs))
    half = m["changed"] / 2.0
    acc = 0
    cut = None
    for sha, subj, n in cs:
        acc += n
        mark = ""
        if cut is None and acc >= half:
            cut = sha
            mark = "   ⭐ ← 여기서 자른다"
        print("     %-9s %5d줄  %s%s" % (sha, n, subj[:44], mark))
    if cut:
        print()
        print("   R-mid : diff = %s..%s" % (base, cut))
        print("   R1    : diff = %s..%s" % (cut, head))
    print()
    print("   ⚠⚠ 이 제안은 **크기만 보고 나눈 것**이다. 되돌리기 어려운 결정(보안·집행 게이트·")
    print("      무인증 표면)이 앞쪽에 몰려 있으면 **그 결정의 마지막 것 뒤**로 옮겨라 —")
    print("      그 편이 재작업 반경을 묶는다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
