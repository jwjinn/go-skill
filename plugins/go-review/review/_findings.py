# -*- coding: utf-8 -*-
"""병합 산출물을 **발견 단위** 행으로 펼쳐 findings.jsonl 에 쌓는다.

⭐ 이 파일이 있는 이유 하나: `human` 컬럼이다 — **사람이 그 발견을 받아들였는가.**
   그것 없이는 어떤 정밀도도 계산되지 않는다. 라운드 단위 집계(rounds.jsonl)는
   "몇 건 나왔나"까지만 답하고 **"그중 몇 건이 옳았나"에는 답하지 못한다**.

⚠⚠ **모델이 이 값을 채우면 측정이 통째로 무의미해진다** — 병합자가 자기 판정을
   자기가 채점하는 것이 되기 때문이다. 그래서 여기서는 **항상 null 로 쓰고**,
   채우는 것은 `verdict.sh`(사람이 실행)뿐이며, `measure.sh` 는 라벨이 없으면
   정밀도 절을 **계산하지 않고 그 사실을 말한다**(정직 공백).

⚠ 재기록(같은 라운드를 다시 record)은 사람이 채운 값을 **보존**한다. 다만 같은 id 의
   **내용이 바뀌었으면 판정을 지운다** — 병합을 다시 돌려 항목이 달라졌는데 옛 판정이
   남으면, 그 라벨은 다른 발견에 붙은 라벨이다(조용히 틀린 데이터가 된다).
"""
import hashlib
import io
import json
import os
import re

# 병합 산출물의 구역 → severity. 순서가 곧 id 순서다.
BUCKETS = ("must_fix", "consider", "pre_existing", "rejected")

# 프롬프트 버전에 들어가는 파일 — 리뷰 결과를 좌우하는 것만 넣는다.
# ⚠ 훅·측정 스크립트는 넣지 마라. 그것이 바뀌었다고 리뷰 품질이 바뀌지 않는데
#   해시가 달라지면 "프롬프트를 바꿨다"는 거짓 신호가 된다.
#
# ⭐ **기준점이 둘이다**(플러그인으로 배포되면서 갈라졌다):
#   · `plugin`  — 지시문 정본. 플러그인 디렉토리에 있다.
#   · `project` — 그 프로젝트만의 리뷰 규칙. 리뷰어가 실제로 읽으므로 **프롬프트의 일부**다.
#   프로젝트 규칙을 넣지 않으면 「규칙을 고쳤는데 버전이 그대로」인 거짓 신호가 난다.
# ⚠ 프로젝트 루트 기준으로만 찾던 옛 코드를 플러그인에 그대로 두면 5개가 **전부 부재**로
#   기록되고, 그 뒤로 이 축은 아무것도 구분하지 못한다(조용히 죽는 탐지기).
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PROMPT_FILES = (
    ("plugin", "agents/reviewer-contract.md"),
    ("plugin", "agents/reviewer-blind.md"),
    ("plugin", "agents/review-merger.md"),
    ("plugin", "commands/review-loop.md"),
    ("plugin", "review/finding-schema.json"),
    ("project", ".claude/review-rules.md"),
)


def prompt_version(root):
    """리뷰 지시문의 내용 해시. 「지난주 프롬프트 변경이 좋아진 건가」에 답할 축이다.

    ⚠ 없는 파일은 **건너뛰지 않고 부재로 기록**한다 — 건너뛰면 파일이 사라진 것과
      내용이 같은 것이 같은 해시를 낳는다.
    """
    h = hashlib.sha256()
    found = []
    for kind, rel in PROMPT_FILES:
        base = PLUGIN_ROOT if kind == "plugin" else root
        p = os.path.join(base, rel)
        h.update(("%s:%s" % (kind, rel)).encode("utf-8"))
        if os.path.exists(p):
            with io.open(p, "rb") as f:
                h.update(f.read())
            found.append(rel)
        else:
            h.update(b"\x00MISSING")
    return h.hexdigest()[:12], len(found), len(PROMPT_FILES)


def codex_model(round_dir):
    """codex.err 배너에서 모델명을 읽는다. 못 읽으면 None(0 으로 채우지 않는다)."""
    p = os.path.join(round_dir, "codex.err")
    if not os.path.exists(p):
        return None
    try:
        with io.open(p, encoding="utf-8", errors="replace") as f:
            txt = f.read(8000).replace("\x00", "")
    except Exception:
        return None
    m = re.search(r"^\s*model:\s*(\S+)", txt, re.M)
    return m.group(1) if m else None


def sig_of(item):
    """발견의 내용 지문 — 같은 id 아래에서 항목이 바뀐 것을 감지한다."""
    key = "|".join(str(item.get(k) or "") for k in ("file", "line", "summary"))
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:10]


def raised_by(item):
    rs = item.get("reviewers") or item.get("raised_by") or []
    return sorted(set(rs)) if isinstance(rs, list) else []


def rows_for(round_dir, rid, day, merged, root, models):
    pv, pf, pt = prompt_version(root)
    cm = models.get("codex") or codex_model(round_dir)
    out = []
    for bucket in BUCKETS:
        items = merged.get(bucket) or []
        if not isinstance(items, list):
            continue
        for i, it in enumerate(items, 1):
            if not isinstance(it, dict):
                continue
            out.append({
                "round": rid,
                "date": day,
                # 사람이 보고서에서 그대로 지목하는 이름이다("must_fix 3번")
                "fid": "%s#%s-%d" % (rid, bucket, i),
                "bucket": bucket,
                "severity": it.get("severity") or bucket,
                "category": it.get("category"),
                "file": it.get("file"),
                "line": it.get("line"),
                "summary": (it.get("summary") or "")[:400],
                "raised_by": raised_by(it),
                "merger_verdict": it.get("verdict"),
                "introduced_by_this_change": it.get("introduced_by_this_change"),
                "sig": sig_of(it),
                # 프롬프트·모델 버전 — 이것이 있어야 "무엇이 좋아졌나"를 가를 수 있다
                "prompt_version": pv,
                "prompt_files": "%d/%d" % (pf, pt),
                "models": {"reviewers": models.get("reviewers"), "codex": cm},
                # ⛔ 사람만 채운다. verdict.sh 를 써라.
                "human": None,
                "human_note": None,
                "judged_by": None,
            })
    return out


def merge_into(path, new_rows, rid):
    """같은 라운드의 옛 행을 새 행으로 갈아 끼우되 사람 판정은 보존한다."""
    old_by_fid = {}
    kept = []
    if os.path.exists(path):
        with io.open(path, encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("round") == rid:
                    old_by_fid[o.get("fid")] = o
                else:
                    kept.append(o)

    carried = dropped = 0
    for r in new_rows:
        old = old_by_fid.get(r["fid"])
        if not old or old.get("human") is None:
            continue
        if old.get("sig") == r["sig"]:
            r["human"] = old["human"]
            r["human_note"] = old.get("human_note")
            # ⚠ `judged_by` 도 함께 이월한다(2026-09-03 리뷰가 지목). 안 옮기면 라운드를 다시
            #   기록할 때 이 필드가 사라지고, 「필드 부재 = 사람 판정」으로 세는 집계가
            #   **자동 판정을 사람 판정으로 세탁**한다 — 「출처를 지우지 않는다」의 정반대다.
            r["judged_by"] = old.get("judged_by")
            carried += 1
        else:
            # 내용이 달라졌다 — 옛 판정은 다른 발견의 것이다. 지우고 알린다.
            dropped += 1

    kept.extend(new_rows)
    kept.sort(key=lambda r: (r.get("round") or "", r.get("fid") or ""))
    with io.open(path, "w", encoding="utf-8") as f:
        for r in kept:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    return carried, dropped, len(kept)
