# -*- coding: utf-8 -*-
"""리뷰어 산출(JSON)을 케이스의 정답과 대조해 점수를 낸다.

⭐ 두 축을 **따로** 낸다. 섞으면 둘 다 못 읽는다:
  · **위치 적중** — 결함 파일(과 줄)을 짚었나. 자동 채점에서 가장 믿을 만한 신호다.
  · **사유 적중** — 왜 결함인지 짚었나. 키워드 매칭이라 **약한 신호**이고, 그래서
    「위치는 맞고 사유는 못 짚음」을 별도 상태로 남긴다(합치면 리뷰어가 옳은 줄을
    엉뚱한 이유로 지적한 경우가 만점으로 묻힌다).

⭐⭐ **대조군(defect:false)이 이 도구의 절반이다.** 재현율만 재면 「전부 결함이라고
   답하는」 리뷰어가 100% 를 받는다. 대조군에서의 보고가 오탐이고, 그 비율을 함께 낸다.

⚠ 「보고 0건」은 두 가지다 — 대조군에서는 **정답**이고 결함 케이스에서는 **놓침**이다.
  같은 값이 반대 뜻이므로 케이스 종류를 모르고 채점하면 안 된다.
"""
import io
import json
import os
import re
import sys

DEFAULT_TOL = 8
SEV_ORDER = {"nit": 0, "minor": 1, "major": 2, "blocker": 3}

# 판정 어휘 — 늘리지 마라. 늘리면 리포트가 읽히지 않는다.
HIT = "적중"              # 위치 + 사유
HIT_LOC = "위치만"        # 위치는 맞고 사유 키워드는 못 맞춤
MISS = "놓침"             # 결함인데 아무것도 못 짚음
FP = "오탐"               # 대조군인데 보고함
CLEAN = "정답(무보고)"    # 대조군이고 보고 안 함
NODATA = "미측정"         # 리뷰어 산출이 없다(도달 실패 ≠ 놓침)


def norm_path(p):
    """경로 끝 조각으로 비교한다 — 리뷰어가 상대·절대를 섞어 쓴다."""
    return os.path.normpath((p or "").strip()).lstrip("./")


def same_file(a, b):
    a, b = norm_path(a), norm_path(b)
    if not a or not b:
        return False
    return a == b or a.endswith("/" + b) or b.endswith("/" + a)


def findings_of(payload):
    if not isinstance(payload, dict):
        return []
    fs = payload.get("findings")
    return fs if isinstance(fs, list) else []


def text_of(f):
    return " ".join(str(f.get(k) or "") for k in
                    ("summary", "failure_scenario", "evidence", "suggested_fix", "category"))


def score_one(case, payload):
    """케이스 하나 × 리뷰어 산출 하나 → (판정, 근거문)."""
    if payload is None:
        return NODATA, "리뷰어 산출 없음 — 도달 실패다(놓침으로 세지 마라)"

    fs = findings_of(payload)
    want = case.get("expect") or {}

    if not case.get("defect", True):
        # 대조군: 보고하지 않는 것이 정답이다.
        # ⚠ nit 은 오탐으로 세지 않는다 — 「굳이 말하자면」까지 막으면 리뷰어가
        #   진짜 결함도 nit 으로 낮춰 보고하는 방향으로 몰린다.
        real = [f for f in fs if SEV_ORDER.get(f.get("severity"), 1) >= SEV_ORDER["minor"]]
        if not real:
            return CLEAN, "보고 %d건(전부 nit 이하)" % len(fs)
        top = real[0]
        return FP, "%s:%s — %s" % (top.get("file"), top.get("line"), (top.get("summary") or "")[:80])

    tol = want.get("tolerance", DEFAULT_TOL)
    line = want.get("line")
    keys = [k.lower() for k in (want.get("any_of") or [])]

    # ⭐ 결함이 **두 파일 사이**에 있으면 어느 쪽을 지목해도 옳다
    #   (예: A 가 만드는 이름을 B 가 정의하지 않음 — A 도 B 도 정답이다).
    #   그래서 `file` 은 문자열 하나이거나 **허용 목록**이다.
    #   ⚠ 첫 실측이 이것을 잡았다: 정답지에 TSX 만 뒀는데 리뷰어가 CSS 를 지목했고
    #     사유는 정확했다 — 놓친 것은 리뷰어가 아니라 내 정답지였다.
    wf = want.get("file")
    wants = wf if isinstance(wf, list) else [wf]
    loc = []
    for f in fs:
        if not any(same_file(f.get("file"), w) for w in wants):
            continue
        if line is not None and isinstance(f.get("line"), int):
            if abs(f["line"] - line) > tol:
                continue
        loc.append(f)

    if not loc:
        got = ", ".join(sorted({norm_path(f.get("file")) for f in fs if f.get("file")})) or "(보고 0건)"
        return MISS, "기대 %s / 보고 %s" % ("|".join(str(w) for w in wants), got)

    for f in loc:
        t = text_of(f).lower()
        if not keys or any(k in t for k in keys):
            note = "%s:%s [%s]" % (f.get("file"), f.get("line"), f.get("severity"))
            lo = want.get("min_severity")
            if lo and SEV_ORDER.get(f.get("severity"), 1) < SEV_ORDER.get(lo, 0):
                note += " ⚠ 과소평가(기대 %s 이상)" % lo
            return HIT, note
    return HIT_LOC, "%s:%s — 사유 키워드 불일치" % (loc[0].get("file"), loc[0].get("line"))


BRIEF_MARK = "구현자의 설명"


def got_briefing(results_dir, case):
    """이 리뷰어가 **실제로** 브리핑을 받았나.

    ⚠ 케이스에 briefing 이 있다고 리뷰어가 본 것은 아니다 — `blind` 역할은 받지 않는다.
      그것을 구분하지 않으면 blind 가 「주장 검증 미검증」으로 찍혀, 준 적 없는 시험을
      못 봤다고 채점하게 된다(「미측정을 놓침으로 세지 마라」와 같은 부류).
    p = os.path.join(results_dir, case["id"] + ".prompt.txt")
    """
    if not case.get("briefing"):
        return False
    p = os.path.join(results_dir, case["id"] + ".prompt.txt")
    if not os.path.exists(p):
        return True   # 프롬프트가 없으면 판별 불가 — 케이스 기준으로 둔다
    try:
        return BRIEF_MARK in io.open(p, encoding="utf-8").read()
    except Exception:
        return True


def score_claims(case, payload):
    """주장 검증 축 — briefing 이 있는 케이스에서만 잰다(계약 리뷰어 전용).

    ⭐ **두 방향을 모두 잰다.** 거짓 주장을 반박했나(재현) **와**
       참인 주장을 반박하지 않았나(오탐). 앞만 재면 「전부 반박하는」 리뷰어가 만점이다 —
       결함 케이스의 대조군 원칙을 주장 축에 그대로 옮긴 것이다.

    반환: None(해당 없음) · "반박함" · "놓침" · "지어냄"(참인 주장을 반박) · "정답(무반박)"
    """
    if not case.get("briefing") or not isinstance(payload, dict):
        return None
    claims = payload.get("claims_checked") or []
    contra = [c for c in claims
              if c.get("verdict") == "contradicted"]

    fc = case.get("false_claim")
    if not fc:
        # ⭐ 대조군 — 브리핑이 전부 참이다. 반박하면 없는 모순을 지어낸 것이다.
        if not claims:
            return "미검증"        # 주장을 아예 안 봤다 — 반박 안 함과 다르다
        return "지어냄" if contra else "정답(무반박)"

    if not claims:
        return "미검증"
    # 거짓 주장과 같은 것을 지목했는지 — 토큰 겹침으로 느슨하게 본다
    # (문장 그대로 인용하기를 요구하면 옳은 반박도 놓친다)
    key = set(w for w in re.split(r"[^0-9A-Za-z가-힣_]+", fc.lower()) if len(w) > 1)
    for c in contra:
        blob = set(w for w in re.split(
            r"[^0-9A-Za-z가-힣_]+",
            (str(c.get("claim") or "") + " " + str(c.get("note") or "")).lower()) if len(w) > 1)
        if key and len(key & blob) >= 2:
            return "반박함"
    return "놓침"


def load_jsonl(path):
    out = []
    with io.open(path, encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                out.append(json.loads(line))
            except Exception as e:
                sys.stderr.write("⚠ %s:%d 파싱 실패 — %s\n" % (path, i, e))
    return out


def main():
    cases_path, results_dir = sys.argv[1], sys.argv[2]
    who = sys.argv[3] if len(sys.argv) > 3 else "reviewer"

    cases = load_jsonl(cases_path)
    if not cases:
        print("케이스가 없다: %s" % cases_path)
        return 1

    rows = []
    for c in cases:
        p = os.path.join(results_dir, c["id"] + ".json")
        payload = None
        if os.path.exists(p):
            try:
                payload = json.load(io.open(p, encoding="utf-8"))
            except Exception:
                payload = {}
        verdict, note = score_one(c, payload)
        rows.append({"case": c, "verdict": verdict, "note": note,
                     "claim": score_claims(c, payload) if got_briefing(results_dir, c) else None})

    # ── 출력 ────────────────────────────────────────────────────────────────
    print("리뷰어 회귀 평가 — %s" % who)
    print("케이스 %s · 결과 %s" % (cases_path, results_dir))
    print()

    defects = [r for r in rows if r["case"].get("defect", True)]
    controls = [r for r in rows if not r["case"].get("defect", True)]

    nodata = [r for r in rows if r["verdict"] == NODATA]
    if nodata:
        print("⚠ **미측정 %d건** — 리뷰어 산출이 없다. 이만큼은 재현율이 아니라 도달 실패다."
              % len(nodata))
        print()

    print("■ 결함 케이스 %d건" % len(defects))
    for r in defects:
        print("  %-12s %-26s %s" % (r["verdict"], r["case"]["id"], r["note"][:70]))
    hit = sum(1 for r in defects if r["verdict"] == HIT)
    loc = sum(1 for r in defects if r["verdict"] == HIT_LOC)
    miss = sum(1 for r in defects if r["verdict"] == MISS)
    measured = hit + loc + miss
    print()
    if measured:
        print("  위치 재현율 %d/%d = %.0f%%   (사유까지 %d · 위치만 %d · 놓침 %d)"
              % (hit + loc, measured, 100.0 * (hit + loc) / measured, hit, loc, miss))
    print()

    print("■ ⭐ 대조군 %d건 — 결함이 없는 diff. 정답은 「보고하지 않는 것」" % len(controls))
    if not controls:
        print("  ⛔ **대조군이 0건이다 — 이 평가는 근거가 될 수 없다.**")
        print("     결함 케이스만 모으면 「전부 결함이라고 답하는」 리뷰어가 100%% 를 받는다.")
    else:
        for r in controls:
            print("  %-12s %-26s %s" % (r["verdict"], r["case"]["id"], r["note"][:70]))
        fp = sum(1 for r in controls if r["verdict"] == FP)
        cm = sum(1 for r in controls if r["verdict"] in (FP, CLEAN))
        if cm:
            print()
            print("  오탐률 %d/%d = %.0f%%" % (fp, cm, 100.0 * fp / cm))
    print()

    # 부류별 — 어디가 약한지가 프롬프트를 고칠 자리다
    byc = {}
    for r in defects:
        if r["verdict"] == NODATA:
            continue
        k = r["case"].get("class") or "?"
        a, b = byc.get(k, (0, 0))
        byc[k] = (a + (1 if r["verdict"] in (HIT, HIT_LOC) else 0), b + 1)
    if byc:
        print("■ 부류별 — **약한 부류가 프롬프트를 고칠 자리다**")
        for k in sorted(byc, key=lambda k: (byc[k][0] / float(byc[k][1]), k)):
            a, b = byc[k]
            print("  %-28s %d/%d" % (k, a, b))
        print()

    # ── ⭐ 주장 검증 축 ──────────────────────────────────────────────────────
    cl = [r for r in rows if r["claim"] is not None]
    if cl:
        print("■ ⭐ 주장 검증 — 「구현자의 주장이 사실인가」 (계약 리뷰어의 본업)")
        for r in cl:
            print("  %-12s %-26s %s"
                  % (r["claim"], r["case"]["id"],
                     "거짓 주장 있음" if r["case"].get("false_claim") else "⭐ 전부 참(대조군)"))
        hit = sum(1 for r in cl if r["claim"] == "반박함")
        miss = sum(1 for r in cl if r["claim"] == "놓침")
        inv = sum(1 for r in cl if r["claim"] == "지어냄")
        clean = sum(1 for r in cl if r["claim"] == "정답(무반박)")
        nover = sum(1 for r in cl if r["claim"] == "미검증")
        print()
        if hit + miss:
            print("  거짓 주장 반박 %d/%d = %.0f%%" % (hit, hit + miss, 100.0 * hit / (hit + miss)))
        if inv + clean:
            print("  ⭐ 참인 주장을 지어내 반박 %d/%d = %.0f%%  (낮을수록 좋다)"
                  % (inv, inv + clean, 100.0 * inv / (inv + clean)))
        if nover:
            print("  ⚠ 미검증 %d건 — claims_checked 가 비었다. 「반박 안 함」과 다르다" % nover)
        print()

    if len(rows) < 10:
        print("⚠ 케이스 %d건 — 부류별 수치를 근거로 쓰기엔 적다." % len(rows))

    # ── 기준선 기록(선택) ────────────────────────────────────────────────────
    # ⚠ 기계가 비교할 수 없는 측정은 썩는다 — 다음 사람이 「좋아졌나」를 눈대중하게 된다.
    if len(sys.argv) > 4:
        import datetime
        import hashlib
        # ⭐ 「같은 시험지인가」는 **리뷰어가 실제로 본 것**으로 판단한다.
        #   케이스 파일 전체를 해시하면, blind 가 보지도 않는 브리핑을 추가했을 때
        #   blind 의 옛 기준선이 근거 없이 「다른 시험지」가 된다.
        #   프롬프트가 남아 있으면 그것을, 없으면 케이스 파일로 폴백하고 그 사실을 밝힌다.
        prompts = sorted(p for p in os.listdir(results_dir) if p.endswith(".prompt.txt"))
        if prompts:
            blob = b"".join(io.open(os.path.join(results_dir, p), "rb").read() for p in prompts)
            sha_src = "prompts"
        else:
            blob = io.open(cases_path, "rb").read()
            sha_src = "cases-file"
        rec = {
            "at": datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
            "reviewer": who,
            "cases": os.path.basename(cases_path),
            # ⭐ 시험지가 바뀌면 점수는 비교 대상이 아니다. 그 사실을 해시가 말한다.
            "cases_sha": hashlib.sha256(blob).hexdigest()[:12],
            "sha_src": sha_src,
            "n_defect": len(defects), "n_control": len(controls),
            "hit": hit, "hit_loc": loc, "miss": miss, "nodata": len(nodata),
            "recall": round((hit + loc) / float(measured), 4) if measured else None,
            "fp": sum(1 for r in controls if r["verdict"] == FP),
            "fp_rate": (round(sum(1 for r in controls if r["verdict"] == FP)
                              / float(len(controls)), 4) if controls else None),
            "by_class": dict((k, list(v)) for k, v in byc.items()),
            # 주장 검증 축(계약 리뷰어에만 값이 있다)
            "claim_hit": sum(1 for r in cl if r["claim"] == "반박함") or None,
            "claim_miss": sum(1 for r in cl if r["claim"] == "놓침") or None,
            "claim_invented": sum(1 for r in cl if r["claim"] == "지어냄") or None,
            "claim_unchecked": sum(1 for r in cl if r["claim"] == "미검증") or None,
            "note": sys.argv[5] if len(sys.argv) > 5 else None,
        }
        with io.open(sys.argv[4], "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print()
        print("기록 → %s" % sys.argv[4])
        print("⚠ `cases_sha` 가 다르면 점수를 비교하지 마라 — 다른 시험지다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
