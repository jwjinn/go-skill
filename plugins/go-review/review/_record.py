# -*- coding: utf-8 -*-
"""라운드 하나를 rounds.jsonl 한 줄로 요약한다. record-round.sh 가 부른다.

⭐ 이 파일의 존재 이유는 `must_fix_by` 하나다 — must_fix 마다 **누가 발견했는가**.
   그것이 있어야 measure.sh 가 절제(ablation)를 계산할 수 있다:
   "리뷰어 X 를 빼면 놓쳤을 must_fix 가 몇 건인가" = X 의 **고유 기여**.
   나머지 필드는 그 판단의 문맥이다.

⚠ 못 잰 것은 **null** 이다. 0 으로 채우면 「없었다」와 「못 쟀다」가 섞여
  나중에 비율을 계산할 때 조용히 틀린 답이 나온다(정직 공백).
"""
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _findings  # noqa: E402

REVIEWERS = ("claude-contract", "claude-blind", "codex")


def load(path):
    try:
        with io.open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def n(x):
    """리스트면 길이, 아니면 None(= 못 쟀다)."""
    return len(x) if isinstance(x, list) else None


def reviewers_of(item):
    """병합 산출물의 항목에서 발견자 목록을 뽑는다(키 이름이 두 가지다)."""
    rs = item.get("reviewers") or item.get("raised_by") or []
    return sorted(set(rs)) if isinstance(rs, list) else []


def codex_tokens(round_dir):
    """codex.err 꼬리에서 `tokens used\\n<숫자>` 를 읽는다.

    ⚠ 숫자는 **다음 줄**에 있고 콤마가 섞인다. 같은 줄로 가정하면 조용히 None 이 된다.
    """
    p = os.path.join(round_dir, "codex.err")
    if not os.path.exists(p):
        return None
    try:
        with io.open(p, encoding="utf-8", errors="replace") as f:
            txt = f.read().replace("\x00", "")
    except Exception:
        return None
    m = re.findall(r"tokens used\s*\n\s*([\d,]+)", txt)
    if not m:
        m = re.findall(r"tokens used[^\d]*([\d,]+)", txt)
    if not m:
        return None
    try:
        return int(m[-1].replace(",", ""))
    except ValueError:
        return None


def parse_tokens(spec, round_dir):
    """"a=1,b=2" → dict. codex 는 없으면 로그에서 자동 파싱한다."""
    out = {}
    for part in (spec or "").split(","):
        part = part.strip()
        if not part or "=" not in part:
            continue
        k, _, v = part.partition("=")
        try:
            out[k.strip()] = int(v.strip().replace(",", ""))
        except ValueError:
            pass
    if "codex" not in out:
        ct = codex_tokens(round_dir)
        if ct is not None:
            out["codex"] = ct
    # ⚠ dict 병합에 `|` 를 쓰지 마라 — 3.9+ 전용이고 이 스크립트는 어느 파이썬에서든 돌아야 한다
    res = dict((r, out.get(r)) for r in REVIEWERS)
    if "review-merger" in out:
        res["review-merger"] = out["review-merger"]
    # ⭐ 리뷰어가 아닌 소비자도 한 자리 받는다 — `tester` 는 테스트를 위임한 로컬 모델의 토큰이다.
    #   리뷰 토큰과 **섞지 않는다**(절제 계산은 리뷰어 자리만 본다). 없으면 키가 생기지 않는다.
    if "tester" in out:
        res["tester"] = out["tester"]
    return res


def main():
    round_dir, out_dir, rid, day, goal, tokens_spec = sys.argv[1:7]
    models_spec = sys.argv[7] if len(sys.argv) > 7 else ""

    merged = load(os.path.join(round_dir, "merged.json")) or {}
    rev = {r: load(os.path.join(round_dir, r + ".json")) for r in REVIEWERS}

    must_fix = merged.get("must_fix") or []
    consider = merged.get("consider") or []

    # ⭐ 절제 분석의 원재료 — must_fix 마다 발견자 집합
    must_fix_by = [reviewers_of(f) for f in must_fix]

    # 리뷰어별 「단독으로 올린 것」 — must_fix + consider 를 합쳐 본다
    # (consider 로 내려간 것도 "실재는 한다"는 판정이므로 값이 0 은 아니다)
    def solo(who, items):
        return sum(1 for it in items if reviewers_of(it) == [who])

    contract = rev.get("claude-contract") or {}
    claims = contract.get("claims_checked") or []

    row = {
        "round": rid,
        "date": day,
        "goal": goal or (merged.get("scope_note") or "")[:120],
        "scope_verdict": merged.get("scope_verdict"),
        "diff_files": None,
        "diff_lines": None,
        # 각 리뷰어가 낸 원 발견 수
        "raised": {r: (n((rev[r] or {}).get("findings")) if rev[r] else None) for r in REVIEWERS},
        # 병합 결과
        "must_fix": len(must_fix),
        "consider": len(consider),
        "pre_existing": n(merged.get("pre_existing")),
        "rejected": n(merged.get("rejected")),
        "coverage_gap": n(merged.get("coverage_gap")),
        # ⭐ 절제 분석용 — 이 필드가 이 파일의 존재 이유다
        "must_fix_by": must_fix_by,
        "solo_must_fix": {r: solo(r, must_fix) for r in REVIEWERS},
        "solo_consider": {r: solo(r, consider) for r in REVIEWERS},
        # 비용
        "tokens": parse_tokens(tokens_spec, round_dir),
        # 구현자 자기평가 정확도
        "claims_total": len(claims) or None,
        "claims_contradicted": sum(1 for c in claims if c.get("verdict") == "contradicted") if claims else None,
        "claims_unverifiable": sum(1 for c in claims if c.get("verdict") == "unverifiable") if claims else None,
        # 사람이 나중에 채운다
        "fixed": None,
        "rejected_by_human": None,
    }

    dp = os.path.join(round_dir, "diff.patch")
    if os.path.exists(dp):
        with io.open(dp, encoding="utf-8", errors="replace") as f:
            txt = f.read()
        row["diff_lines"] = txt.count("\n")
        row["diff_files"] = txt.count("\n+++ ") + (1 if txt.startswith("+++ ") else 0)

    path = os.path.join(out_dir, "rounds.jsonl")
    lines = []
    if os.path.exists(path):
        with io.open(path, encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    old = json.loads(line)
                except Exception:
                    continue
                if old.get("round") == rid:
                    # 재실행은 갱신이다. 다만 사람이 채운 값은 지우지 않는다.
                    for k in ("fixed", "rejected_by_human"):
                        if old.get(k) is not None and row.get(k) is None:
                            row[k] = old[k]
                    continue
                lines.append(json.dumps(old, ensure_ascii=False) + "\n")
    lines.append(json.dumps(row, ensure_ascii=False) + "\n")
    lines.sort(key=lambda l: json.loads(l)["round"])
    with io.open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print("  JSONL  %s  (라운드 %d개)" % (path, len(lines)))

    # ── ⭐ 발견 단위 기록 ────────────────────────────────────────────────────
    # 라운드 단위는 "몇 건 나왔나"까지만 답한다. "그중 몇 건이 옳았나"는 발견마다
    # 사람 판정이 붙어야 계산된다 — 그 자리를 만드는 것이 여기다.
    models = {}
    for part in (models_spec or "").split(","):
        if "=" in part:
            k, _, v = part.partition("=")
            models[k.strip()] = v.strip() or None

    fpath = os.path.join(out_dir, "findings.jsonl")
    rows = _findings.rows_for(round_dir, rid, day, merged,
                              os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd(), models)
    carried, dropped, total = _findings.merge_into(fpath, rows, rid)
    print("  발견   %s  (이 라운드 %d건 · 전체 %d건)" % (fpath, len(rows), total))
    if carried:
        print("         사람 판정 %d건 보존" % carried)
    if dropped:
        print("         ⚠ 내용이 바뀐 %d건의 판정을 **지웠다** — 옛 라벨은 다른 발견의 것이다."
              % dropped)
    unlabeled = sum(1 for r in rows if r["bucket"] in ("must_fix", "consider") and r["human"] is None)
    if unlabeled:
        print("         ⛔ 미판정 %d건 — `bash %s %s` 로 채워라."
              % (unlabeled, os.path.join(HERE, "verdict.sh"), rid))


if __name__ == "__main__":
    main()
