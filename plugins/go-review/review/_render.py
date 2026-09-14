# -*- coding: utf-8 -*-
"""merged.json → merged.md (사람이 읽는 보고서).

왜 스크립트가 하나:
  병합 에이전트가 JSON 과 MD 를 **둘 다** 쓰면 같은 내용을 두 번 생성하는 것이고,
  그 두 번째가 **출력 토큰**(가장 비싼 종류)이다. 1라운드 실측으로 merged.md 는 7,151자였다.
  게다가 LLM 이 쓰면 라운드마다 형식이 달라져 나중에 비교하기 어렵다.
  ⭐ 규칙: **에이전트 간 교환은 구조화 데이터, 사람이 읽는 산출물만 마크다운.**
     그리고 그 마크다운은 **결정론적으로 렌더**한다.

사용: python3 _render.py <merged.json> <merged.md>
"""
import io
import json
import sys


CELL = 140   # 표 셀 상한(문자). 넘으면 자르되 **잘랐다고 표시한다**.


def esc(s, cap=CELL):
    """표 안에서 파이프가 열을 깨뜨리지 않게 + 셀 길이 제한.

    ⚠ **조용히 자르지 않는다.** 이 파이프라인은 `head -12` 가 목표 계약의 「범위 밖」을
      말없이 잘라 낸 결함을 겪었다 — 자른 사실을 표시하지 않으면 읽는 쪽은 그것이
      전부라고 믿는다. must_fix 전문은 아래 details 블록에 그대로 남는다.
    """
    t = (s or "").replace("|", "\\|").replace("\n", " ").strip()
    if cap and len(t) > cap:
        t = t[:cap - 1].rstrip() + "…"
    return t


def sec(out, title, items, cols, rows):
    if not items:
        return
    out.append("## %s (%d)" % (title, len(items)))
    out.append("")
    out.append("| " + " | ".join(cols) + " |")
    out.append("|" + "|".join(["---"] * len(cols)) + "|")
    for it in items:
        out.append("| " + " | ".join(esc(c) for c in rows(it)) + " |")
    out.append("")


def loc(f):
    p = f.get("file") or ""
    ln = f.get("line")
    return "%s:%s" % (p, ln) if p and ln else (p or "—")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    m = json.load(io.open(src, encoding="utf-8"))
    o = []

    verdict = m.get("scope_verdict") or "?"
    badge = {"on-goal": "✅", "drifted": "⚠", "incomplete": "⚠", "cannot-judge": "—"}.get(verdict, "")
    o += ["# 리뷰 병합 결과", "", "**목표 판정: %s `%s`**" % (badge, verdict), ""]
    if m.get("scope_note"):
        o += ["> " + m["scope_note"].replace("\n", "\n> "), ""]

    counts = [(k, len(m.get(k) or [])) for k in
              ("must_fix", "consider", "pre_existing", "rejected", "coverage_gap")]
    o += ["| " + " | ".join(k for k, _ in counts) + " |",
          "|" + "|".join(["---"] * len(counts)) + "|",
          "| " + " | ".join(str(v) for _, v in counts) + " |", ""]

    sec(o, "🔴 must_fix — 고치지 않으면 끝낼 수 없다", m.get("must_fix"),
        ["심각도", "위치", "요약", "발견자", "판정"],
        lambda f: [f.get("severity", ""), loc(f), f.get("summary", ""),
                   "+".join(f.get("reviewers") or []), f.get("verdict", "")])

    # must_fix 는 실패 시나리오까지 보여 준다 — 고치는 사람이 판단할 재료다
    if m.get("must_fix"):
        o += ["<details><summary>must_fix 상세(실패 시나리오·수정 방향)</summary>", ""]
        for i, f in enumerate(m["must_fix"], 1):
            o += ["**MF%d · %s** — `%s`" % (i, f.get("severity", ""), loc(f)), "",
                  "- %s" % f.get("summary", ""),
                  "- **터지는 경로**: %s" % esc(f.get("failure_scenario") or "—", 0),
                  "- **수정 방향**: %s" % esc(f.get("suggested_fix") or "—", 0)]
            if f.get("verify_note"):
                o += ["- **병합자 확인**: %s" % esc(f["verify_note"], 0)]
            o += [""]
        o += ["</details>", ""]

    sec(o, "🟡 consider — 고치면 좋다", m.get("consider"),
        ["심각도", "위치", "요약", "발견자", "must_fix 가 아닌 이유"],
        lambda f: [f.get("severity", ""), loc(f), f.get("summary", ""),
                   "+".join(f.get("reviewers") or []), f.get("why_not_must_fix", "")])

    sec(o, "🟣 pre_existing — 실재하지만 이 변경이 만든 것이 아니다", m.get("pre_existing"),
        ["위치", "요약", "발견자"],
        lambda f: [loc(f), f.get("summary", ""), "+".join(f.get("reviewers") or [])])

    # ⭐ 기각이 병합의 본체다 — 무엇을 왜 버렸는지가 가장 중요한 정보다
    sec(o, "⭕ 기각 — 병합자가 확인하고 버린 것", m.get("rejected"),
        ["제기", "요약", "기각 사유"],
        lambda f: ["+".join(f.get("raised_by") or []), f.get("summary", ""),
                   f.get("reject_reason", "")])

    if m.get("claims_contradicted"):
        sec(o, "❗ 구현자 주장 중 반박된 것", m["claims_contradicted"],
            ["주장", "무엇이 틀렸나"],
            lambda c: [c.get("claim", ""), c.get("note", "")])

    if m.get("coverage_gap"):
        o += ["## ⚠ 커버리지 공백 — 아무도 확인하지 않은 영역", ""]
        o += ["- " + esc(g) for g in m["coverage_gap"]]
        o += ["", "> 이것을 말하지 않으면 「리뷰했다」가 과장이 된다.", ""]

    if m.get("agreement_note"):
        o += ["## 리뷰어 일치·불일치", "", m["agreement_note"], ""]
    if m.get("merge_note"):
        o += ["## 병합 노트", "", m["merge_note"], ""]

    o += ["---", "",
          "<sub>이 문서는 `merged.json` 에서 **결정론적으로 렌더**됐다"
          "(`_render.py`). 에이전트 간 교환은 구조화 데이터이고, "
          "마크다운은 사람이 읽는 이 산출물에만 쓴다.</sub>"]

    io.open(dst, "w", encoding="utf-8").write("\n".join(o) + "\n")
    print("  렌더   %s  (%d줄)" % (dst, len(o)))


if __name__ == "__main__":
    main()
