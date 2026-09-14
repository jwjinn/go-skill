# -*- coding: utf-8 -*-
"""findings.jsonl 의 판정을 채운다.

판정에는 **출처가 둘**이고 그 구분이 이 도구의 핵심이다:
  · `judged_by="user"`  사람이 명령줄로 직접 준 판정. 가장 신뢰도가 높다.
  · `judged_by="auto"`  구현자·병합자가 반영 결과대로 붙인 판정(`--auto`).

⭐ 왜 구분하나: 자동 판정만으로 낸 정밀도는 **자기 판정을 자기가 채점한 값**이다. 섞어서
   한 숫자로 내면 그 사실이 사라지고, 로그는 "리뷰가 잘 됐다"를 항상 말하는 장식이 된다.
   그래서 값은 받되 **출처를 지우지 않는다** — `history.sh`·`measure.sh` 가 나눠서 보여준다.

⚠ `--auto` 는 사용자 결정으로 열렸다(2026-09-03): 「리뷰 라운드의 오탐 판정은 동의를 받지
   마라. codex 가 판정하는 영역이다. 히스토리를 남기고 go 가 끝나면 알려 달라.」
   ⇒ 사람의 검증층이 **라운드 단위에서 최종 결과물 단위로 옮겨 간 것**이지 사라진 것이 아니다.
   그래서 `/go` 는 종료 보고에 라운드 히스토리를 반드시 싣는다(go.md §7).

판정 어휘 셋(이 이상 늘리지 마라 — 늘리면 아무도 일관되게 못 쓴다):
  a(ccepted)  실제 결함이었다. 고쳤거나 고칠 것이다.
  r(ejected)  결함이 아니었다(오탐·취향·이미 의도된 것).
  d(eferred)  타당하지만 지금 범위가 아니다. **오탐이 아니다** — 정밀도 계산에서 분자에 든다.
"""
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

WORDS = {"a": "accepted", "r": "rejected", "d": "deferred",
         "accepted": "accepted", "rejected": "rejected", "deferred": "deferred"}
PREFIX = {"mf": "must_fix", "c": "consider", "pe": "pre_existing", "rj": "rejected"}


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


def short(row):
    """mf1 · c3 처럼 사람이 타이핑하는 짧은 이름."""
    fid = row.get("fid") or ""
    tail = fid.rsplit("#", 1)[-1]          # must_fix-3
    bucket, _, n = tail.rpartition("-")
    for p, b in PREFIX.items():
        if b == bucket:
            return p + n
    return tail


def show(rows, rid, only_unlabeled=True):
    sel = [r for r in rows if (not rid or r.get("round") == rid)]
    if not sel:
        print("해당 라운드의 발견이 없다: %s" % (rid or "(전체)"))
        return 1
    shown = 0
    for r in sel:
        if r.get("bucket") in ("pre_existing",):
            continue
        if only_unlabeled and r.get("human") is not None:
            continue
        shown += 1
        mark = r.get("human") or "미판정"
        if r.get("human") and r.get("judged_by") == "auto":
            mark += "(자동)"
        loc = "%s:%s" % (r.get("file") or "?", r.get("line") if r.get("line") is not None else "?")
        by = ",".join(r.get("raised_by") or []) or "?"
        print("  %-6s [%-11s] %-9s %s" % (short(r), r.get("bucket"), mark, loc))
        print("         %s" % (r.get("summary") or "")[:150])
        print("         발견: %s · 병합판정: %s" % (by, r.get("merger_verdict") or "—"))
    if shown == 0:
        print("  미판정이 없다 — 이 라운드는 전부 채워졌다.")
    else:
        print()
        print("판정: a=결함이었다 · r=결함이 아니었다 · d=타당하나 범위 밖")
        print("예:  bash %s %s mf1=a mf2=r:오탐이다 c3=d"
              % (os.path.join(HERE, "verdict.sh"), rid or "<라운드>"))
    return 0


def main():
    argv = [a for a in sys.argv[1:]]
    auto = "--auto" in argv
    argv = [a for a in argv if a != "--auto"]
    path = argv[0]
    rid = argv[1] if len(argv) > 1 else ""
    pairs = argv[2:]

    rows = load(path)
    if not rows:
        print("findings.jsonl 이 비었다 — record-round.sh 를 먼저 돌려라: %s" % path)
        return 1

    if not pairs:
        return show(rows, rid)

    if not rid:
        print("판정을 쓰려면 라운드를 지정해야 한다.")
        return 1

    index = {}
    for r in rows:
        if r.get("round") == rid:
            index[short(r)] = r

    bad = []
    applied = 0
    for p in pairs:
        key, _, val = p.partition("=")
        val, _, note = val.partition(":")
        key = key.strip().lower()
        v = WORDS.get(val.strip().lower())
        if key not in index:
            bad.append("%s (그런 발견이 없다)" % key)
            continue
        if not v:
            bad.append("%s (판정은 a·r·d 중 하나다: %r)" % (key, val))
            continue
        index[key]["human"] = v
        index[key]["human_note"] = note.strip() or None
        index[key]["judged_by"] = "auto" if auto else "user"
        applied += 1

    if bad:
        print("⛔ 다음을 처리하지 못했다 — **아무것도 쓰지 않았다**:")
        for b in bad:
            print("   %s" % b)
        print()
        print("현재 이 라운드의 발견:")
        show(rows, rid, only_unlabeled=False)
        return 1

    with io.open(path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    left = sum(1 for r in rows
               if r.get("round") == rid and r.get("bucket") in ("must_fix", "consider")
               and r.get("human") is None)
    print("판정 %d건 기록(%s). 남은 미판정 %d건."
          % (applied, "자동 — 구현자·병합자 판정" if auto else "사람 판정", left))
    if auto:
        print("⚠ 자동 판정이다 — 정밀도로 인용할 때 반드시 그 사실과 함께 인용해라(자기 채점).")
    if left == 0:
        print("측정: bash %s" % os.path.join(HERE, "measure.sh"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
