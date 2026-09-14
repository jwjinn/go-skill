# -*- coding: utf-8 -*-
"""케이스를 리뷰어에게 줄 수 있는 모양(patch + 프롬프트)으로 펼친다.

⚠ **정답(`why`·`expect`)은 절대 내보내지 않는다** — 그것이 새면 오픈북 시험이 된다.
  이 파일이 그 경계다: 여기서 나가는 것은 diff 와 (있으면) 브리핑뿐이다.
"""
import io
import json
import os
import sys

# 리뷰어에게 나가도 되는 필드. **화이트리스트다** — 새 필드를 추가해도 기본이 「안 나간다」
# 여야 정답이 조용히 새지 않는다(위조 가능한 값과 같은 원칙: 기본이 닫힘).
SAFE = ("id", "lang", "diff", "briefing")

# ⭐ 역할이 받는 것이 다르다 — 그것이 이 파이프라인의 설계 전부다.
#   `blind` 에게 브리핑을 주면 「편향 0」이라는 그 리뷰어의 존재 이유가 사라진다.
#   ⚠ 그래서 브리핑을 케이스에 추가해도 blind 의 시험지는 **바뀌지 않는다** —
#     그 사실이 유지돼야 blind 의 옛 기준선이 계속 비교 가능하다.
ROLE_SAFE = {
    "blind": ("id", "lang", "diff"),
    "contract": SAFE,
    "codex": SAFE,
}


def validate(c, i):
    errs = []
    for k in ("id", "class", "lang", "defect", "diff"):
        if k not in c:
            errs.append("필수 필드 없음: %s" % k)
    if c.get("defect") and not (c.get("expect") or {}).get("file"):
        errs.append("defect:true 인데 expect.file 이 없다 — 채점할 수 없다")
    if not c.get("defect") and c.get("expect"):
        errs.append("대조군인데 expect 가 있다 — 정답은 「보고하지 않는 것」이다")
    if c.get("false_claim") and not c.get("briefing"):
        errs.append("false_claim 이 있는데 briefing 이 없다 — 검증할 주장이 없다")
    d = c.get("diff") or ""
    if "+++ " not in d or "@@" not in d:
        errs.append("diff 가 unified 형식이 아니다(+++ / @@ 없음)")
    return ["케이스 #%d %s: %s" % (i, c.get("id", "?"), e) for e in errs]


def load(path):
    cases, errs = [], []
    with io.open(path, encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                c = json.loads(line)
            except Exception as e:
                errs.append("%s:%d JSON 파싱 실패 — %s" % (path, i, e))
                continue
            errs.extend(validate(c, i))
            cases.append(c)
    ids = [c.get("id") for c in cases]
    for x in set(ids):
        if ids.count(x) > 1:
            errs.append("id 중복: %s (%d회) — 점수를 라운드 간 비교할 수 없다" % (x, ids.count(x)))
    return cases, errs


PROMPT = """당신은 코드 리뷰어다. 아래 변경에 **무엇이 잘못됐는지** 찾아라.

⚠ 변경된 파일들은 이 저장소에 실재하지 않을 수 있다 — **diff 만으로 판단하라.**
파일을 열 수 없다는 것을 결함으로 보고하지 마라.

⭐ 이 변경에 **결함이 없을 수도 있다.** 그때는 `findings` 를 빈 배열로 두는 것이 정답이다.
없는 결함을 만들어 내지 마라 — 구체적인 실패 시나리오를 쓸 수 없으면 그것은 결함이 아니라 취향이다.

산출은 스키마 `%(schema)s` 를 따르는 JSON 하나뿐이다(다른 말 금지).
`findings[].file` 은 diff 의 경로를 **그대로** 써라 — 채점이 그것으로 대조한다.
%(briefing)s
```diff
%(diff)s```
"""

BRIEF = """
구현자의 설명(사실이 아닐 수 있다 — 주장이 코드와 맞는지 확인하는 것도 네 일이다):
%s
"""


def main():
    cases_path, out_dir = sys.argv[1], sys.argv[2]
    schema = sys.argv[3] if len(sys.argv) > 3 else "../finding-schema.json"
    role = sys.argv[4] if len(sys.argv) > 4 else "contract"
    allow = ROLE_SAFE.get(role, SAFE)

    cases, errs = load(cases_path)
    if errs:
        print("⛔ 케이스 파일에 문제가 있다 — **아무것도 펼치지 않았다**:")
        for e in errs:
            print("   %s" % e)
        return 1
    if not cases:
        print("케이스가 없다: %s" % cases_path)
        return 1

    os.makedirs(out_dir, exist_ok=True)
    manifest = []
    for c in cases:
        safe = dict((k, c[k]) for k in allow if k in c)
        p = os.path.join(out_dir, c["id"] + ".prompt.txt")
        with io.open(p, "w", encoding="utf-8") as f:
            f.write(PROMPT % {
                "schema": schema,
                "diff": safe["diff"] if safe["diff"].endswith("\n") else safe["diff"] + "\n",
                "briefing": BRIEF % safe["briefing"] if safe.get("briefing") else "",
            })
        manifest.append({"id": c["id"], "prompt": p,
                         "result": os.path.join(out_dir, c["id"] + ".json")})

    # ⚠ 이름 앞의 `_` 는 장식이 아니다 — 결과 파일과 **섞이지 않게** 하는 것이다.
    #   `manifest.json` 이었을 때 진행 상황을 `ls *.json | wc -l` 로 세다 +1 을 얻어
    #   16건을 17건으로 읽고 아직 안 끝난 실행을 채점했다(첫 실측에서 실제로 밟았다).
    mp = os.path.join(out_dir, "_manifest.json")
    with io.open(mp, "w", encoding="utf-8") as f:
        f.write(json.dumps(manifest, ensure_ascii=False, indent=2))

    nd = sum(1 for c in cases if c.get("defect"))
    nb = sum(1 for c in cases if c.get("briefing"))
    print("펼침 %d건 (결함 %d · 대조군 %d) → %s" % (len(cases), nd, len(cases) - nd, out_dir))
    print("역할 %s — 나가는 필드: %s%s"
          % (role, ", ".join(allow),
             ("  (브리핑 %d건 **제외**)" % nb) if nb and "briefing" not in allow else ""))
    print("매니페스트: %s" % mp)
    print()
    print("각 프롬프트를 리뷰어에게 주고 산출 JSON 을 <id>.json 으로 같은 디렉토리에 저장한 뒤:")
    print("  bash %s score %s %s <리뷰어이름>"
          % (os.path.join(os.path.dirname(os.path.abspath(__file__)), "eval.sh"),
             cases_path, out_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
