# -*- coding: utf-8 -*-
"""rounds.jsonl 로 **리뷰 파이프라인이 비용을 하는가**를 계산한다.

재는 것은 하나다: **리뷰어를 하나 더 붙이면 무엇을 더 잡는가, 그 값이 토큰값을 하는가.**

⭐ 핵심 지표는 「고유 기여」다 — 그 리뷰어만 발견한 must_fix 수.
   겹쳐 발견한 것은 **확증**이고 값이 다르다(병합자의 확인을 빠르게 하지만, 그 항목은
   그 리뷰어가 없어도 잡혔다). 둘을 섞으면 "세 명이 다 일했다"는 착시가 생긴다.

⚠ 표본 수를 항상 먼저 말한다. 라운드 1~2개로 낸 비율은 근거가 아니라 인상이다 —
  원 레포가 반복해서 배운 것("낮은 수가 나오면 탐지기부터 의심하라")의 통계판이다.
"""
import io
import itertools
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# ⭐ 리뷰어 목록을 **하드코딩하지 않고 데이터에서 파생**한다.
#   2026-09-02 에 하드코딩이 실제로 낡았다: 기본 preset 이 P2 로 바뀌어 자리 이름이
#   codex-contract·codex-blind 가 됐는데 이 상수는 claude-contract·claude-blind·codex 였다.
#   그러면 stat() 이 `if not sel: return` 으로 **조용히 빠져나가** 리뷰어별·1인 기준선·절제·
#   비용 표가 전부 빈다 — 「누가 값을 했나」를 재는 도구가 아무 말도 안 하게 된다.
#   ⚠ 같은 사실(리뷰어 이름)이 _dedup.py 와 여기 두 곳에 있었고 한쪽만 고친 것이 원인이다.
#     그래서 이제 이 파일은 **자기 목록을 갖지 않는다** — 실제로 돈 이름을 rounds.jsonl 에서
#     읽는다. 데이터가 없을 때만 상위집합으로 폴백한다(빈 표보다 낫다).
FALLBACK = ("claude-contract", "claude-blind", "codex", "codex-contract", "codex-blind")
_SHORT = {"claude-contract": "contract", "claude-blind": "blind", "codex": "codex",
          "codex-contract": "cx-contract", "codex-blind": "cx-blind"}
MAX_COMBO_SEATS = 6   # 조합 폭발 방지 — 이보다 많으면 절제표를 생략하고 그렇게 말한다
MIN_ROUNDS = 5   # 이 아래면 "판단하지 마라" 고 말한다


def short(who):
    """모르는 이름도 죽지 않고 짧게 — KeyError 로 측정 전체를 멈추지 않는다."""
    return _SHORT.get(who, who)


def reviewers_of(rows, frows=None):
    """실제로 발견을 올린 이름 전부. ⭐ 순서를 고정한다(표가 실행마다 흔들리면 대조가 안 된다).

    ⚠ **두 파일을 다 봐야 한다.** `rounds.jsonl` 의 `must_fix_by` 만 보면
      **must_fix 가 0 인 라운드에서 자리 이름이 보이지 않는다** — 그러면 기본 목록으로
      폴백해서 「누가 값을 했나」를 못 잰다. 실제로 밟았다(2026-09-02 체인 검증:
      findings.jsonl 에는 codex-contract·codex-blind 가 정확히 있는데 폴백이 떴다).
      기각만 있는 라운드는 드물지 않다 — 오히려 병합자가 일을 한 라운드다.
    """
    seen = set()
    for r in rows:
        for by in (r.get("must_fix_by") or []):
            seen.update(by)
        for f in (r.get("findings") or []):
            seen.update(f.get("raised_by") or [])
    for r in (frows or []):                       # findings.jsonl — 발견 단위 행
        seen.update(r.get("raised_by") or [])
    env = os.environ.get("CLAUDE_REVIEW_REVIEWERS", "")
    for x in env.split(","):
        if x.strip():
            seen.add(x.strip())
    if not seen:
        return FALLBACK
    # 알려진 이름을 먼저(안정된 표), 나머지는 사전순
    known = [w for w in FALLBACK if w in seen]
    return tuple(known + sorted(seen - set(known)))


def load(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with io.open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass
    return rows


def main():
    path = sys.argv[1]
    rows = load(path)
    if not rows:
        print("rounds.jsonl 이 비었다 — 아직 기록된 라운드가 없다: %s" % path)
        return

    # ⭐ findings.jsonl 도 읽는다 — must_fix 가 0 인 라운드에서는 그쪽에만 자리 이름이 있다.
    fpath = os.path.join(os.path.dirname(path), "findings.jsonl")
    frows = load(fpath)
    seats = reviewers_of(rows, frows)
    dates = [r.get("date") or "?" for r in rows]
    print("리뷰 파이프라인 측정 — 라운드 %d개 (%s ~ %s)" % (len(rows), min(dates), max(dates)))
    print("데이터: %s" % path)
    print("자리: %s%s" % (", ".join(short(w) for w in seats),
                        "  ⚠ 라운드에 발견자 기록이 없어 기본 목록이다" if seats is FALLBACK else ""))
    print()

    # ── 무엇을 잡았나 ────────────────────────────────────────────────────────
    tot = lambda k: sum((r.get(k) or 0) for r in rows)
    mf, cs, rj, pe = tot("must_fix"), tot("consider"), tot("rejected"), tot("pre_existing")
    graded = mf + cs + rj + pe
    print("■ 무엇을 잡았나")
    print("  must_fix %d · consider %d · pre_existing %d · 기각 %d" % (mf, cs, pe, rj))
    if graded:
        pct = 100.0 * rj / graded
        flag = "  ⚠ 기각 0 — 병합이 판정을 건너뛰었을 수 있다" if rj == 0 else ""
        print("  기각률 %d/%d = %.0f%%%s" % (rj, graded, pct, flag))
    fx = [r.get("fixed") for r in rows if r.get("fixed") is not None]
    print("  실제 고친 것: %s" % (sum(fx) if fx else "미측정(fixed 가 null 이다)"))
    print()

    # ── ⭐ 절제 ──────────────────────────────────────────────────────────────
    # 모든 라운드의 must_fix 발견자 집합을 모은다
    items = []
    for r in rows:
        for by in (r.get("must_fix_by") or []):
            items.append(set(by))
    print("■ ⭐ 절제 — 리뷰어 조합별 must_fix 커버리지")
    if not items:
        print("  (must_fix_by 가 없다 — 옛 형식으로 기록된 라운드다. record-round.sh 를 다시 돌려라)")
    else:
        print("  %-26s %-8s %s" % ("조합", "커버", "놓침"))
        best = None
        if len(seats) > MAX_COMBO_SEATS:
            print("  (자리가 %d개라 조합표를 생략한다 — 고유 기여만 본다)" % len(seats))
            seats_combo = ()
        else:
            seats_combo = seats
        for k in (1, 2, 3):
            for combo in itertools.combinations(seats_combo, k):
                cov = sum(1 for s in items if s & set(combo))
                miss = len(items) - cov
                mark = ""
                if miss == 0 and best is None:
                    best = combo
                    mark = "  ⭐ 이것으로 충분했다"
                print("  %-26s %d/%d      %d%s"
                      % ("+".join(short(c) for c in combo), cov, len(items), miss, mark))
        print()
        print("  리뷰어별 **고유** 기여(그 리뷰어만 발견한 must_fix)")
        for r_ in seats:
            solo = sum(1 for s in items if s == {r_})
            conf = sum(1 for s in items if r_ in s and len(s) > 1)
            print("    %-18s 고유 %d건 · 확증(겹침) %d건" % (r_, solo, conf))
    print()

    # ── 비용 ────────────────────────────────────────────────────────────────
    print("■ 비용")
    tk = {}
    for r in rows:
        for who, v in (r.get("tokens") or {}).items():
            if isinstance(v, int):
                tk[who] = tk.get(who, 0) + v
    if not tk:
        print("  토큰이 기록되지 않았다 — record-round.sh 의 3번째 인자로 넘겨라.")
        print("  (codex 는 codex.err 에서 자동 파싱된다)")
    else:
        print("  %-18s %12s %10s %14s" % ("리뷰어", "토큰", "고유 mf", "토큰/고유건"))
        for who in list(seats) + ["review-merger"]:
            if who not in tk:
                continue
            if who == "review-merger":
                print("  %-18s %12s %10s %14s" % (who, "{:,}".format(tk[who]), "—", "(판정 비용)"))
                continue
            solo = sum(1 for s in items if s == {who}) if items else None
            per = "{:,}".format(tk[who] // solo) if solo else ("∞" if solo == 0 else "—")
            print("  %-18s %12s %10s %14s" % (who, "{:,}".format(tk[who]), solo, per))
        print("  %-18s %12s" % ("합계", "{:,}".format(sum(tk.values()))))
        # codex 를 빼면 얼마나 아끼나
        if "codex" in tk and items:
            solo_cx = sum(1 for s in items if s == {"codex"})
            save = 100.0 * tk["codex"] / sum(tk.values())
            print()
            print("  codex 를 빼면: 토큰 %.0f%% 절약 · 놓치는 must_fix %d건" % (save, solo_cx))
    print()

    # ── 판단 ────────────────────────────────────────────────────────────────
    print("■ 판단")
    if len(rows) < MIN_ROUNDS:
        print("  ⚠ **표본 %d 라운드 — 결론을 내리지 마라.** 최소 %d 라운드는 모아라."
              % (len(rows), MIN_ROUNDS))
        print("     지금 숫자는 근거가 아니라 인상이다. 라운드가 쌓이면 이 문장이 사라진다.")
    else:
        print("  표본 %d 라운드 — 아래 수치를 근거로 쓸 수 있다." % len(rows))
    if items:
        solo_cx = sum(1 for s in items if s == {"codex"})
        conf_cx = sum(1 for s in items if "codex" in s and len(s) > 1)
        if solo_cx == 0 and conf_cx > 0:
            print("  · codex 는 고유 발견 0건이지만 %d건을 **확증**했다 — 확증은 병합자의" % conf_cx)
            print("    확인 부담을 줄이지만, 그 항목들은 codex 가 없어도 잡혔다.")
        elif solo_cx > 0:
            print("  · codex 가 **단독으로** must_fix %d건을 잡았다 — 값을 하고 있다." % solo_cx)
    cc = [r.get("claims_contradicted") for r in rows if r.get("claims_contradicted") is not None]
    ct = [r.get("claims_total") for r in rows if r.get("claims_total") is not None]
    if cc and ct and sum(ct):
        print("  · 구현자 주장 %d건 중 %d건이 반박됐다(%.0f%%) — 자기평가는 실제보다 후하다."
              % (sum(ct), sum(cc), 100.0 * sum(cc) / sum(ct)))
    gaps = [r.get("coverage_gap") for r in rows if r.get("coverage_gap")]
    if gaps:
        print("  · 커버리지 공백이 라운드당 평균 %.1f개 — 「리뷰했다」의 실제 범위다."
              % (sum(gaps) / float(len(gaps))))

    print()
    # ⚠ diff_lines 는 rounds.jsonl 에 있고 판정은 findings.jsonl 에 있다 —
    #   크기↔정밀도를 보려면 라운드로 조인해야 한다.
    precision(fpath, dict((r.get("round"), r.get("diff_lines")) for r in rows))


def precision(fpath, diff_by_round=None):
    """⭐ 정밀도 — 사람 판정이 있어야만 계산된다. 없으면 계산하지 않고 그렇게 말한다."""
    print("■ ⭐ 정밀도 — 올린 것 중 몇 건이 실제 결함이었나")
    if not os.path.exists(fpath):
        print("  findings.jsonl 이 없다 — record-round.sh 를 다시 돌리면 생긴다.")
        return
    rows = load(fpath)
    # ⚠ 여기서도 목록을 하드코딩하지 않는다 — findings 행의 raised_by 가 정본이다.
    seats = reviewers_of([{"findings": rows}])
    gradable = [r for r in rows if r.get("bucket") in ("must_fix", "consider")]
    labeled = [r for r in gradable if r.get("human")]
    if not gradable:
        print("  판정 대상 발견이 없다.")
        return
    if not labeled:
        print("  ⛔ **계산하지 않았다 — 사람 판정이 0건이다**(대상 %d건)." % len(gradable))
        print("     `bash %s` 로 채워라. 이 값 없이는 「몇 건 나왔나」까지만"
              % os.path.join(HERE, "verdict.sh"))
        print("     알 수 있고 **「그중 몇 건이 옳았나」는 알 수 없다**. 그것이 이 절의 전부다.")
        return

    cov = 100.0 * len(labeled) / len(gradable)
    print("  라벨 %d/%d (%.0f%%)%s"
          % (len(labeled), len(gradable), cov,
             "  ⚠ 절반도 안 채워졌다 — 아래 비율은 편향될 수 있다" if cov < 50 else ""))
    print()

    def stat(sel, name):
        if not sel:
            return
        a = sum(1 for r in sel if r["human"] == "accepted")
        d = sum(1 for r in sel if r["human"] == "deferred")
        rj = sum(1 for r in sel if r["human"] == "rejected")
        # deferred 는 오탐이 아니다 — 타당한데 지금 범위가 아닐 뿐이라 분자에 든다
        print("  %-20s 올림 %3d · 결함 %3d · 범위밖 %2d · 오탐 %2d → 정밀도 %.0f%%"
              % (name, len(sel), a, d, rj, 100.0 * (a + d) / len(sel)))

    stat(labeled, "전체")
    print()
    print("  리뷰어별(그 리뷰어가 올린 것 기준 — 겹쳐 올린 것은 양쪽에 센다)")
    for who in seats:
        stat([r for r in labeled if who in (r.get("raised_by") or [])], short(who))
    print()
    print("  ⭐ 1인 기준선 — 그 리뷰어 **혼자였다면** 실제 결함을 몇 건 잡았나")
    real = [r for r in labeled if r["human"] in ("accepted", "deferred")]
    # ⚠ 발견자가 안 적힌 항목(병합자가 스스로 올린 것 등)은 **분모에서 뺀다** —
    #   남겨 두면 어느 리뷰어도 잡지 못한 것을 「셋 다」가 잡은 것으로 세어
    #   세 명 구성을 근거 없이 유리하게 만든다.
    attributed = [r for r in real if r.get("raised_by")]
    orphan = len(real) - len(attributed)
    if not attributed:
        print("    (아직 발견자가 기록된 실제 결함이 없다)")
    else:
        for who in seats:
            got = sum(1 for r in attributed if who in (r.get("raised_by") or []))
            print("    %-20s %d/%d" % (short(who), got, len(attributed)))
        # ⚠ 「셋 다」로 하드코딩돼 있었다 — 자리가 둘인 P2 에서 **틀린 라벨**이 나왔다.
        #   표의 라벨이 실제 구성을 말하지 않으면 사람을 잘못된 결론으로 보낸다.
        allname = "전원(%d)" % len(seats)
        print("    %-20s %d/%d  ← 지금 구성" % (allname, len(attributed), len(attributed)))
        if orphan:
            print("    (발견자 미기록 %d건은 위 비교에서 제외했다 — 병합자가 스스로 올린 것)"
                  % orphan)
        print()
        print("  ⚠ 이 표가 답하는 질문: **리뷰어를 %d 두는 값이 그 비용을 하는가.**" % len(seats))
        print("     1인 최고치가 「%s」과 같으면 나머지는 확증만 한 것이다." % allname)

    # ── ⭐ diff 크기 ↔ 정밀도 — `_scope.py` 의 임계값을 교정하는 자리 ──────────
    # ⚠ `_scope.py` 의 상한 2000 은 라운드 1에서 **외삽한 추측**이다. 여기가 그것을
    #   데이터로 바꾸는 경로다 — 큰 diff 에서 정밀도가 실제로 떨어지는지 본다.
    dbr = diff_by_round or {}
    for r in labeled:
        r["_diff"] = dbr.get(r.get("round"))
    sized = [r for r in labeled if isinstance(r.get("_diff"), int)]
    if sized:
        print()
        print("  ⭐ diff 크기 ↔ 정밀도 (`_scope.py` 상한 교정용)")
        buckets = [(0, 500), (500, 1500), (1500, 3000), (3000, 10 ** 9)]
        rows_seen = 0
        for lo, hi in buckets:
            sel = [r for r in sized if lo <= r["_diff"] < hi]
            if not sel:
                continue
            rows_seen += 1
            a = sum(1 for r in sel if r["human"] in ("accepted", "deferred"))
            label = "%d~%s줄" % (lo, "∞" if hi > 10 ** 8 else str(hi))
            print("    %-12s 발견 %3d · 정밀도 %.0f%%" % (label, len(sel), 100.0 * a / len(sel)))
        if rows_seen < 2:
            print("    ⚠ 구간이 %d개뿐 — **비교가 성립하지 않는다.** 크기가 다른 라운드가"
                  % rows_seen)
            print("       쌓여야 임계를 말할 수 있다. 그때까지 2000 은 추측이다.")
        else:
            print("    ⚠ 구간마다 diff 난이도가 다르면 이 비교는 상관이지 인과가 아니다 —")
            print("       큰 변경이 원래 어려운 것과 「크기 때문에 놓친다」는 다른 주장이다.")

    # ── 프롬프트 버전별 ─────────────────────────────────────────────────────
    vers = {}
    for r in labeled:
        vers.setdefault(r.get("prompt_version") or "?", []).append(r)
    if len(vers) > 1:
        print()
        print("  프롬프트 버전별(「지난주 프롬프트 변경이 좋아진 건가」)")
        for v, sel in sorted(vers.items()):
            a = sum(1 for r in sel if r["human"] in ("accepted", "deferred"))
            print("    %-14s 올림 %3d · 정밀도 %.0f%%" % (v, len(sel), 100.0 * a / len(sel)))
        print("    ⚠ 버전 간 diff 난이도가 다르면 이 비교는 성립하지 않는다 —")
        print("       같은 코드에 두 버전을 돌린 것이 아니면 **관찰이지 실험이 아니다**.")


if __name__ == "__main__":
    main()
