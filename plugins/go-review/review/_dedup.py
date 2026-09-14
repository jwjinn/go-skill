# -*- coding: utf-8 -*-
"""리뷰어 셋의 JSON 을 **결정론적으로** 묶어 병합자에게 줄 후보 목록을 만든다.

⭐ 왜 스크립트인가: 중복 제거는 판단이 아니라 대조다. 병합자가 그것을 읽어서 하면
   토큰을 쓰는데, 같은 일을 0 토큰으로 할 수 있다. 병합자의 값은 **기각**에 있고,
   기각은 코드를 열어 봐야 하는 일이라 스크립트가 대신할 수 없다.

⚠⚠ **애매하면 합치지 않는다.** 서로 다른 결함 둘을 하나로 묶으면 그중 하나가 조용히
   사라진다 — 중복이 남는 것보다 나쁘다. 그래서 확신 조건 둘을 **동시에** 요구하고
   (같은 파일 · 줄 차이 ≤3 · 요약 토큰 겹침 ≥0.25), 애매한 것은 `near` 로 **알리기만** 한다.

⭐ `needs_verify` 가 이 파일의 두 번째 존재 이유다. 라운드 1 실측:
   **기각 3건이 전부 「단독 발견」**이었고(`[blind]`·`[codex]`·`[blind]`),
   둘 이상이 짚은 항목에서는 기각이 0건이었다. 즉 합의는 검증의 한 형태다.
   ⚠ 다만 **합의가 증명은 아니다** — 리뷰어 둘이 같은 틀린 전제를 공유할 수 있다.
   그래서 `blocker` 는 합의 여부와 무관하게 항상 확인 대상이다.
"""
import io
import json
import os
import re
import sys

# ⭐ **자리와 모델은 다른 축이다.** A(계약)·B(무편향)를 가르는 것은 받는 정보이지 모델이
#   아니므로, 어느 모델이든 어느 자리에나 앉을 수 있다(review-loop ③ 의 프리셋 표).
#   그래서 이 목록은 **자리 이름이 아니라 산출 파일 이름**이고, 구성을 바꾸면 여기에 추가한다.
#   ⚠ 여기 없는 이름의 `<name>.json` 은 **조용히 무시된다** — 리뷰어를 늘렸는데 집계에
#     안 잡히면 이 상수부터 의심하라(「0 이 나오면 탐지기부터」의 이 파일 판).
#   env 로도 덧붙일 수 있다: CLAUDE_REVIEW_REVIEWERS="codex-contract,codex-blind"
#     이름을 배포본에서만 바꾸면 **같은 파일이 다르게 동작한다**(정본 이중화의 최악형).
REVIEWERS = ("claude-contract", "claude-blind", "codex",
             "codex-contract", "codex-blind")
_extra = os.environ.get("CLAUDE_REVIEW_REVIEWERS", "")
if _extra:
    REVIEWERS = tuple(dict.fromkeys(REVIEWERS + tuple(
        x.strip() for x in _extra.split(",") if x.strip())))

LINE_SAME = 3      # 이 안이면 같은 자리로 본다
LINE_NEAR = 12     # 이 안이면 「볼 만하다」고 알린다(합치지는 않는다)
OVERLAP_MIN = 0.25  # 요약 토큰 자카드 하한
SEV = {"nit": 0, "minor": 1, "major": 2, "blocker": 3}


def toks(s):
    return set(w for w in re.split(r"[^0-9A-Za-z가-힣_]+", (s or "").lower()) if len(w) > 1)


def jaccard(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / float(len(a | b))


def norm(p):
    return os.path.normpath((p or "").strip()).lstrip("./")


def same_file(a, b):
    a, b = norm(a), norm(b)
    if not a or not b:
        return False
    return a == b or a.endswith("/" + b) or b.endswith("/" + a)


def dline(a, b):
    """⚠⚠ **`0` 은 줄 번호가 아니라 「모른다」다** — finding-schema.json 이 그렇게 정의한다
    ("1-기반 줄 번호. 특정할 수 없으면 0.").

    ⭐ 2026-09-02 에 이것을 안 걸러서 **가짜 합의를 만들고 있었다.** `isinstance(0, int)` 이
       참이라 줄을 모르는 발견 둘이 `d == 0`(같은 줄)으로 읽혔고, 그러면 아래 group() 의
       「같은 파일 같은 줄이면 어휘 겹침을 요구하지 않는다」 규칙에 걸려 **전혀 무관한
       발견이 한 그룹으로 합쳐졌다**(실측: "쿼터 음수 허용" + "로그 오타" → 1그룹).
       결과가 유실보다 나쁘다 — `raised_by` 가 둘이 되어 **합의**로 보이고, non-blocker 면
       `needs_verify: false` 가 되어 **병합자가 코드를 열지 않는다.**
    ⚠ 이 함수는 `bool` 도 거른다 — 파이썬에서 `isinstance(True, int)` 가 참이다.
    """
    def known(x):
        return isinstance(x, int) and not isinstance(x, bool) and x > 0
    if not known(a) or not known(b):
        return None      # 한쪽이라도 줄을 모르면 줄로 판단하지 않는다
    return abs(a - b)


def load(round_dir):
    """REVIEWERS 는 **가능한 자리의 상위집합**이므로 「없는 파일」을 결함으로 세지 않는다.

    ⚠ 처음엔 목록의 모든 이름에 대해 파일 부재를 「산출 없는 리뷰어」로 보고했는데,
      자리 구성을 고를 수 있게 만든 순간 **설정하지도 않은 자리 4개가 매번 경고**로 찍혔다
      — 진짜 신호(도달 실패)가 그 소음에 묻힌다.
    ⭐ 의미 있는 것은 「몇 자리가 실제로 산출을 냈나」다. 그것이 2 미만이면 교차검증이
      성립하지 않으므로 그때만 알린다. **시도했는데 실패한 것**(`.err` 는 있고 `.json` 은
      없다)은 진짜 도달 실패이므로 따로 센다.
    """
    items = []
    found = []
    failed = []
    notrev = {}
    for r in REVIEWERS:
        p = os.path.join(round_dir, r + ".json")
        if not os.path.exists(p):
            # 시도한 흔적(.err)이 있는데 산출이 없으면 도달 실패다.
            if os.path.exists(os.path.join(round_dir, r + ".err")):
                failed.append(r)
            continue
        found.append(r)
        try:
            d = json.load(io.open(p, encoding="utf-8"))
        except Exception as e:
            failed.append("%s(파싱 실패: %s)" % (r, e))
            found.pop()
            continue
        notrev[r] = d.get("not_reviewed") or []
        for f in (d.get("findings") or []):
            if isinstance(f, dict):
                f = dict(f)
                f["_reviewer"] = r
                f["_toks"] = toks(f.get("summary"))
                items.append(f)
    return items, found, failed, notrev


def group(items):
    """확신 조건을 동시에 만족할 때만 합친다."""
    groups = []
    for it in items:
        placed = False
        for g in groups:
            # 같은 리뷰어의 두 발견은 합치지 않는다 — 그 리뷰어가 따로 올린 것은 따로다
            if it["_reviewer"] in [m["_reviewer"] for m in g]:
                continue
            head = g[0]
            if not same_file(it.get("file"), head.get("file")):
                continue
            d = dline(it.get("line"), head.get("line"))
            if d is not None and d > LINE_SAME:
                continue
            # ⭐ 같은 파일 **같은 줄**을 서로 다른 리뷰어가 짚었으면 같은 결함이다 —
            #   어휘 겹침을 요구하지 않는다. 라운드 1 실측이 그것을 잡았다:
            #   「경계문이 diff 읽기와 충돌」 vs 「읽으라고 주는 diff 가 읽지 말라는 곳에 있다」는
            #   같은 결함인데 자카드가 0.25 미만이라 안 합쳐졌다(g2/g15·g6/g18).
            #   **다른 어휘로 말하는 것이 다른 모델을 쓰는 이유**이므로 어휘로 가르면 안 된다.
            # ⚠ 대가: 같은 줄의 서로 다른 결함 둘이 합쳐질 수 있다. 다만 members 에 둘 다
            #   남으므로 사라지지는 않고 **함께 제시**될 뿐이다(중복보다 나쁘지 않다).
            if d != 0 and jaccard(it["_toks"], head["_toks"]) < OVERLAP_MIN:
                continue
            g.append(it)
            placed = True
            break
        if not placed:
            groups.append([it])
    return groups


def near_of(groups):
    """합치지는 않았지만 같은 것일 수 있는 짝 — 병합자가 판단한다."""
    out = {}
    for i, a in enumerate(groups):
        for j, b in enumerate(groups):
            if j <= i:
                continue
            if not same_file(a[0].get("file"), b[0].get("file")):
                continue
            d = dline(a[0].get("line"), b[0].get("line"))
            if d is None or d > LINE_NEAR:
                continue
            out.setdefault("g%d" % (i + 1), []).append("g%d" % (j + 1))
    return out


def main():
    round_dir = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(round_dir, "candidates.json")

    items, found, failed, notrev = load(round_dir)
    if not items:
        sys.stderr.write("리뷰어 산출이 없다: %s\n" % round_dir)
        return 1

    gs = group(items)
    keep = lambda f: dict((k, v) for k, v in f.items() if not k.startswith("_"))

    out = []
    for i, g in enumerate(gs, 1):
        by = sorted(set(m["_reviewer"] for m in g))
        top = max(SEV.get(m.get("severity"), 1) for m in g)
        # ⭐ 단독은 항상 확인. 합의했어도 blocker 는 확인(같은 틀린 전제를 공유할 수 있다).
        nv = len(by) == 1 or top >= SEV["blocker"]
        out.append({
            "gid": "g%d" % i,
            "file": norm(g[0].get("file")),
            "line": g[0].get("line"),
            "raised_by": by,
            "max_severity": [k for k, v in SEV.items() if v == top][0],
            "needs_verify": nv,
            "verify_reason": ("단독 발견" if len(by) == 1
                              else ("blocker — 합의도 증명은 아니다" if nv else "")),
            "members": [keep(m) for m in g],
        })

    doc = {
        "round": os.path.basename(round_dir.rstrip("/")),
        "stats": {
            "raw": len(items),
            "groups": len(gs),
            "solo": sum(1 for g in out if len(g["raised_by"]) == 1),
            "multi": sum(1 for g in out if len(g["raised_by"]) > 1),
            "needs_verify": sum(1 for g in out if g["needs_verify"]),
            "reviewers_found": found,
            "reviewers_failed": failed,
        },
        # ⚠ 합치지 않았지만 같을 수 있는 짝 — 병합자가 본다
        "near": near_of(gs),
        "candidates": out,
        "not_reviewed": notrev,
    }
    with io.open(out_path, "w", encoding="utf-8") as f:
        f.write(json.dumps(doc, ensure_ascii=False, indent=1))

    s = doc["stats"]
    print("원 발견 %d → 후보 %d (단독 %d · 합의 %d)" % (s["raw"], s["groups"], s["solo"], s["multi"]))
    print("⭐ 확인 필요 %d/%d — 나머지 %d 는 합의된 non-blocker 라 건너뛴다"
          % (s["needs_verify"], s["groups"], s["groups"] - s["needs_verify"]))
    if doc["near"]:
        print("⚠ 같을 수 있으나 합치지 않은 짝 %d — 병합자가 판단한다: %s"
              % (len(doc["near"]), json.dumps(doc["near"], ensure_ascii=False)))
    print("자리 %d개가 산출을 냈다: %s" % (len(found), ", ".join(found)))
    if failed:
        print("⚠ 도달 실패 %s — 시도했으나 산출이 없다(재현율이 아니라 도달 실패)"
              % ", ".join(failed))
    if len(found) < 2:
        print("⚠⚠ 자리가 %d개뿐이다 — **교차검증이 성립하지 않는다.** 합의 신호가 없으므로"
              % len(found))
        print("   모든 발견이 단독이고 전부 확인 대상이 된다.")
    print("→ %s" % out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
