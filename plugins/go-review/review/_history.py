# -*- coding: utf-8 -*-
"""리뷰 라운드 히스토리 — `/go` 종료 보고에 싣는 「이런 일들이 있었다」.

⭐ 왜 필요한가(사용자 결정 2026-09-03): 「go 는 최대한 AI-Native 하게. 협의로 플랜을 같이
   만들면, go 가 그 협의문 기준으로 개발·리뷰·수정을 계속하고, **끝났을 때 최종 보고를 받는다**.」
   ⇒ 사람의 검증층이 라운드마다 끼어드는 자리에서 **끝의 보고 한 자리**로 옮겨 갔다.
   그러면 그 보고가 부실할수록 통제가 약해진다. 이 도구가 보고의 그 절을 **기계로** 만든다
   (모델이 산문으로 다시 쓰면 라운드마다 형식이 달라져 비교가 안 되고, 나쁜 라운드가 조용해진다).

읽는 것: docs/리뷰-이력/rounds.jsonl · findings.jsonl (record-round.sh 가 쌓는다)
쓰는 것: 없음 — stdout 만. 판정 출처(user/auto)를 **나눠서** 보여준다.
"""
import io
import json
import os
import sys
from collections import Counter


def load(path):
    rows = []
    if os.path.exists(path):
        with io.open(path, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    try:
                        rows.append(json.loads(line))
                    except Exception:
                        pass
    return rows


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    since = sys.argv[2] if len(sys.argv) > 2 else ""      # 라운드 id 접두(예: 20260903)
    rounds = load(os.path.join(d, "rounds.jsonl"))
    finds = load(os.path.join(d, "findings.jsonl"))
    if since:
        rounds = [r for r in rounds if str(r.get("round", "")).startswith(since)]
        finds = [f for f in finds if str(f.get("round", "")).startswith(since)]
    if not rounds:
        print("리뷰 라운드 기록이 없다: %s%s" % (os.path.join(d, "rounds.jsonl"),
                                              (" (접두 %s)" % since) if since else ""))
        print("⚠ 「리뷰를 안 돌렸다」와 「기록을 안 했다」는 다르다 — record-round.sh 를 돌렸는지 확인해라.")
        return 1

    by_round = {}
    for f in finds:
        by_round.setdefault(f.get("round"), []).append(f)

    print("## 리뷰 히스토리 — 라운드 %d회" % len(rounds))
    print()
    print("| 라운드 | 목표 | 범위 판정 | diff | must_fix | consider | 기각 | 미검토 영역 |")
    print("|---|---|---|---|---|---|---|---|")
    tot = Counter()
    for r in rounds:
        rid = r.get("round")
        goal = (r.get("goal") or "")[:44]
        print("| `%s` | %s | %s | %s파일·%s줄 | %s | %s | %s | %s |" % (
            rid, goal, r.get("scope_verdict") or "—",
            r.get("diff_files") or "?", r.get("diff_lines") or "?",
            r.get("must_fix") or 0, r.get("consider") or 0,
            r.get("rejected") or 0, r.get("coverage_gap") or 0))
        for k in ("must_fix", "consider", "rejected", "pre_existing", "coverage_gap"):
            tot[k] += r.get(k) or 0

    print()
    print("**누계** — must_fix %d · consider %d · 기각 %d · 기존 부채 %d · 아무도 안 본 영역 %d"
          % (tot["must_fix"], tot["consider"], tot["rejected"],
             tot["pre_existing"], tot["coverage_gap"]))

    # ── 판정 출처 ────────────────────────────────────────────────────────────
    judged = [f for f in finds if f.get("human")]
    # ⚠ 필드 부재는 **사람 판정이 아니다** — 「모르는 것」을 사람 판정으로 세면 숫자가 세탁된다.
    auto = [f for f in judged if f.get("judged_by") == "auto"]
    user = [f for f in judged if f.get("judged_by") == "user"]
    unknown = [f for f in judged if f.get("judged_by") not in ("auto", "user")]
    unl = [f for f in finds if not f.get("human") and f.get("bucket") in ("must_fix", "consider")]
    print()
    print("**판정 출처** — 사람 %d건 · 자동(구현자·병합자) %d건 · 출처 불명 %d건 · 미판정 %d건"
          % (len(user), len(auto), len(unknown), len(unl)))
    if auto and not user:
        print("⚠ 판정이 **전부 자동**이다 — 여기서 나오는 정밀도는 자기 채점이다. 숫자로 인용할 때")
        print("  반드시 그 사실과 함께 인용해라. 사람의 검증은 이 보고를 읽는 자리에 있다.")

    # ── 무엇이 잡혔나 — 심각한 것만 ────────────────────────────────────────────
    mf = [f for f in finds if f.get("bucket") == "must_fix"]
    if mf:
        print()
        print("### 확정 결함(must_fix) — 무엇이 잡혔나")
        print()
        print("| 라운드 | 위치 | 요약 | 발견자 | 판정 |")
        print("|---|---|---|---|---|")
        for f in mf:
            loc = "%s:%s" % (f.get("file") or "?", f.get("line") if f.get("line") is not None else "?")
            v = f.get("human") or "미판정"
            if f.get("human") and f.get("judged_by") == "auto":
                v += "(자동)"
            print("| `%s` | `%s` | %s | %s | %s |" % (
                f.get("round"), loc, (f.get("summary") or "")[:88],
                ",".join(f.get("raised_by") or []) or "?", v))

    # ⚠ `bucket == "rejected"` 는 **병합자가** 기각한 것이다. 오탐 판정을 자동으로 하게 되면서
    #   `human == "rejected"` 가 **반영 중 기각한 것**을 담는데, 그것을 이 절에 안 넣으면
    #   「무엇을 왜 기각했는지」가 보고에서 통째로 빠진다 — 사용자가 「히스토리를 남기고
    #   알려 달라」고 한 바로 그것이다(2026-09-03 리뷰가 지목).
    rj = [f for f in finds
          if f.get("bucket") == "rejected" or f.get("human") == "rejected"]
    if rj:
        print()
        print("### 기각된 지적 — 병합자가 코드를 열어 「결함이 아니다」로 판정한 것")
        print()
        for f in rj:
            how = ""
            if f.get("human") == "rejected":
                how = " · 판정: 오탐(%s)" % ("자동" if f.get("judged_by") == "auto" else "사람")
                if f.get("human_note"):
                    how += " — " + str(f.get("human_note"))[:60]
            print("- `%s` %s:%s — %s (발견: %s)%s" % (
                f.get("round"), f.get("file") or "?",
                f.get("line") if f.get("line") is not None else "?",
                (f.get("summary") or "")[:110],
                ",".join(f.get("raised_by") or []) or "?", how))
        print()
        print("⭐ 기각이 0 이면 병합이 판정을 건너뛴 것일 수 있다 — 이 절이 비어 있으면 의심해라.")

    gaps = [(r.get("round"), r.get("coverage_gap") or 0) for r in rounds if (r.get("coverage_gap") or 0) > 0]
    if gaps:
        print()
        print("### ⚠ 아무도 보지 않은 영역")
        print()
        for rid, n in gaps:
            print("- `%s` — %d건. 이 라운드의 「리뷰했다」는 그만큼 좁은 말이다." % (rid, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
