# -*- coding: utf-8 -*-
"""_config.test.py — 로컬 모델 리뷰어 **자격 게이트**의 대조군.

# 왜 있나 (2026-09-17)

`seats` 에 `local`(로컬 모델)을 앉힐 수 있게 하면서, **재지 않은 모델이 리뷰어 자리에 앉는 것**을
막아야 한다. 재지 않은 모델을 앉히면 「리뷰가 있는데 아무것도 못 잡는 상태」가 되고, 그것은
리뷰가 없는 것보다 나쁘다 — **있다고 믿기 때문이다.**

사용자 지시(2026-09-17): 「로컬 모델의 경우에는 모델 마다의 성능 차이가 있으니, 이 모델을
리뷰로 사용하기 전에 **특정 기준 이상인지를 먼저 선행해서 판단을 하는 프로세스**가 있어야
할 거 같고」.

# 이 스위트가 지키는 것 하나

**모르면 닫는다(fail-closed).** 자격 기록이 없거나·미달이거나·낡았거나·깨졌으면 그 자리를
`none` 으로 바꾼다. ⭐ 대조군은 ⑧이다 — **게이트 호출을 지우면 ①이 붉어져야 한다.**
그러지 않으면 이 테스트는 근거가 아니라 장식이다.

⚠ 낡음 판정은 **케이스 파일의 내용 해시**로 한다. `mtime` 이 아니다 — 체크아웃만 해도
mtime 이 바뀌어서 「낡았다」가 거짓으로 뜬다.

실행: `python3 review/_config.test.py`   (판정: 0 통과 · 1 실패)
"""
import io
import json
import os
import shutil
import sys
import tempfile

SELF = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SELF)

import _config  # noqa: E402

PASS = 0
FAIL = 0


def chk(label, got, want):
    global PASS, FAIL
    if got == want:
        print("  ok   %s" % label)
        PASS += 1
    else:
        print("  FAIL %s  → got=%r want=%r" % (label, got, want))
        FAIL += 1


def chk_truthy(label, got):
    global PASS, FAIL
    if got:
        print("  ok   %s" % label)
        PASS += 1
    else:
        print("  FAIL %s  → 비어 있다(%r)" % (label, got))
        FAIL += 1


def make_project(qualified_record=None, raw_record=None, cases_text="CASE-A\n"):
    """가짜 프로젝트를 만든다. 반환: (root, cases_path)."""
    root = tempfile.mkdtemp(prefix="cfgtest-")
    rv = os.path.join(root, ".claude", "review")
    os.makedirs(rv)
    cases = os.path.join(rv, "eval", "cases")
    os.makedirs(cases)
    cpath = os.path.join(cases, "project.jsonl")
    io.open(cpath, "w", encoding="utf-8").write(cases_text)
    if raw_record is not None:
        io.open(os.path.join(rv, "local-qualified.json"), "w", encoding="utf-8").write(raw_record)
    elif qualified_record is not None:
        json.dump(qualified_record, io.open(os.path.join(rv, "local-qualified.json"), "w",
                                            encoding="utf-8"), ensure_ascii=False)
    return root, cpath


def record(root, cases_path, qualified=True, model="qwen3-coder-next"):
    """지금 케이스 파일과 **같은 해시**를 갖는 기록을 만든다."""
    return {
        "measured_at": "2026-09-17T10:00:00+09:00",
        "model": model,
        "endpoint": "http://example.invalid/v1",
        "cases_hash": _config.cases_hash(root),
        "recall": 0.72,
        "false_positive": 0.55,
        "unmeasured": 0,
        "qualified": qualified,
        "why": "테스트 픽스처",
    }


def run_gate(root, seats):
    """게이트를 부른다. 반환: (seats, note)."""
    return _config.gate_local_qualification(dict(seats), root)


print("=== 자격 게이트 (local 자리) ===")

# ── ① 기록이 없으면 자리가 비고 사유가 나온다 ───────────────────────────────
root, cpath = make_project()
try:
    seats, note = run_gate(root, {"contract": "claude", "blind": "local", "merger": "claude"})
    chk("① 기록 없음 → blind 자리가 none", seats.get("blind"), "none")
    chk("① 다른 자리는 그대로", (seats.get("contract"), seats.get("merger")), ("claude", "claude"))
    chk_truthy("① 사유가 비어 있지 않다", note)
finally:
    shutil.rmtree(root, ignore_errors=True)

# ── ② 미달이면 같다 ─────────────────────────────────────────────────────────
root, cpath = make_project()
try:
    rec = record(root, cpath, qualified=False)
    json.dump(rec, io.open(os.path.join(root, ".claude", "review", "local-qualified.json"), "w",
                           encoding="utf-8"), ensure_ascii=False)
    seats, note = run_gate(root, {"blind": "local"})
    chk("② qualified=false → none", seats.get("blind"), "none")
    chk_truthy("② 사유가 비어 있지 않다", note)
finally:
    shutil.rmtree(root, ignore_errors=True)

# ── ③ 합격이면 자리가 유지된다 ──────────────────────────────────────────────
root, cpath = make_project()
try:
    rec = record(root, cpath, qualified=True)
    json.dump(rec, io.open(os.path.join(root, ".claude", "review", "local-qualified.json"), "w",
                           encoding="utf-8"), ensure_ascii=False)
    seats, note = run_gate(root, {"blind": "local", "contract": "claude"})
    chk("③ qualified=true · 해시 일치 → local 유지", seats.get("blind"), "local")
    chk("③ 그때는 사유가 없다", note, None)
finally:
    shutil.rmtree(root, ignore_errors=True)

# ── ④ 낡으면(케이스가 바뀌었으면) 비운다 ───────────────────────────────────
root, cpath = make_project()
try:
    rec = record(root, cpath, qualified=True)
    json.dump(rec, io.open(os.path.join(root, ".claude", "review", "local-qualified.json"), "w",
                           encoding="utf-8"), ensure_ascii=False)
    # 케이스 파일을 바꾼다 → 해시가 달라진다
    io.open(cpath, "a", encoding="utf-8").write("CASE-B\n")
    seats, note = run_gate(root, {"blind": "local"})
    chk("④ 케이스가 바뀌면 none", seats.get("blind"), "none")
    chk_truthy("④ 사유가 비어 있지 않다", note)
finally:
    shutil.rmtree(root, ignore_errors=True)

# ── ⑤ 깨진 JSON 은 비운다(모르면 닫는다) ────────────────────────────────────
root, cpath = make_project(raw_record="{이건 JSON 이 아니다")
try:
    seats, note = run_gate(root, {"blind": "local"})
    chk("⑤ 깨진 JSON → none", seats.get("blind"), "none")
    chk_truthy("⑤ 사유가 비어 있지 않다", note)
finally:
    shutil.rmtree(root, ignore_errors=True)

# ── ⑥ local 자리가 없으면 아무 일도 하지 않는다 ────────────────────────────
root, cpath = make_project()
try:
    before = {"contract": "claude", "blind": "codex", "cross": "none", "merger": "claude"}
    seats, note = run_gate(root, before)
    chk("⑥ local 자리 0개 → seats 무변경", seats, before)
    chk("⑥ 그때는 사유가 없다", note, None)
finally:
    shutil.rmtree(root, ignore_errors=True)

# ── ⑦ 케이스 파일이 아예 없어도 판정이 난다(기록이 있어도 닫는다) ──────────
root = tempfile.mkdtemp(prefix="cfgtest-")
try:
    rv = os.path.join(root, ".claude", "review")
    os.makedirs(rv)
    json.dump({"qualified": True, "cases_hash": "무엇이든"},
              io.open(os.path.join(rv, "local-qualified.json"), "w", encoding="utf-8"),
              ensure_ascii=False)
    seats, note = run_gate(root, {"blind": "local"})
    chk("⑦ 케이스 파일 부재 → none(해시를 맞출 수 없다)", seats.get("blind"), "none")
finally:
    shutil.rmtree(root, ignore_errors=True)

# ── ⑧ ⭐⭐ 대조군 — **`main()` 이 게이트를 실제로 부르는가** ─────────────────────
#
# ⚠⚠ 첫 판의 ⑧은 **항진명제**였다. 바로 위에서 리터럴로 만든 dict 의 값을 확인하는 것이라
#    피검 코드가 관여하지 않았고, `main()` 의 게이트 호출 한 줄을 지워도 8축 전부 초록이었다
#    (2026-09-17 리뷰가 잡았고 실제로 사보타주해서 재현했다 — rc 0).
#    ⭐ 머리말이 「그러지 않으면 이 테스트는 근거가 아니라 장식이다」라고 적은 그 상태였다.
#    ⇒ 이제 **`main()` 을 실제로 돌려** 배선을 잰다. 게이트 호출을 지우면 이 축이 붉어진다.
print("=== ⑧ 대조군 — main() 이 게이트를 부르는가 ===")
root, cpath = make_project()
try:
    rv = os.path.join(root, ".claude", "review")
    io.open(os.path.join(rv, "config.json"), "w", encoding="utf-8").write(
        '{"preset":"custom","seats":{"contract":"claude","blind":"local","cross":"none","merger":"claude"}}')
    # 자격 기록은 **없다** — main() 이 게이트를 부르면 blind 자리가 비어야 한다.
    import subprocess
    env = dict(os.environ)
    env["CLAUDE_PROJECT_DIR"] = root
    out = subprocess.run([sys.executable, os.path.join(SELF, "_config.py"),
                          os.path.join(rv, "config.json")],
                         capture_output=True, text=True, env=env).stdout
    chk("⑧ main() 출력에 게이트 사유가 있다", "로컬 모델 자리를 비웠다" in out, True)
    chk("⑧ blind 자리가 비어 있다고 표기된다", "blind" in out and "이 자리는 비운다" in out, True)
    chk("⑧ REVIEWERS 에 local 이 실리지 않는다", "local-blind" not in out, True)
finally:
    shutil.rmtree(root, ignore_errors=True)

print()

# ── ⑨ ⭐⭐ 비-dict 기록은 전부 닫는다 (2026-09-17 리뷰가 잡은 자리) ─────────────
#
# ⚠⚠ 첫 판이 fail-closed 가 **아니었다.** 기록이 JSON `null` 이면 `json.load` 가 예외 없이
#    `None` 을 돌려 「읽었고 문제 없다」로 빠져나갔고(자리 유지 · 사유 없음), `[]` 면
#    `rec.get` 이 AttributeError 로 `_config.py` 를 통째로 죽였다.
#    ⭐ 원인은 **판정의 방향**이었다 — 「why 가 있으면 닫는다」로 쓰면 예상 못 한 입력이 전부
#    통과한다. 지금은 「합격을 확인했을 때만 연다」로 뒤집었고, 이 축이 그것을 잠근다.
print("=== ⑨ 비-dict 기록 (null · [] · false · 문자열) ===")
for raw, label in [("null", "null"), ("[]", "빈 배열"), ("false", "false"), ('"ok"', "문자열")]:
    root, cpath = make_project(raw_record=raw)
    try:
        seats, note = run_gate(root, {"blind": "local"})
        chk("⑨ %s 기록 → none" % label, seats.get("blind"), "none")
        chk_truthy("⑨ %s 사유가 있다" % label, note)
    except Exception as e:
        chk("⑨ %s 기록 → 예외 없이 판정해야 한다" % label, "예외:%s" % type(e).__name__, "none")
    finally:
        shutil.rmtree(root, ignore_errors=True)

# ── ⑩ ⭐⭐ 자격은 **응시자(모델)** 에도 묶인다 (2026-09-17 리뷰 둘이 함께 지적) ───
#
# ⚠⚠ 첫 판은 케이스 해시만 봤다 — 로컬 엔드포인트가 다른(더 약한) 모델을 서빙하도록 바뀌어도
#    자격이 그대로 유효했다. 그것이 사용자 요청(「모델마다 성능 차이가 있으니 기준 이상인지
#    먼저 판단」)이 막으려던 바로 그 상태다. 시험지가 같아도 **응시자가 다르면 다시 재야 한다.**
print("=== ⑩ 잰 모델 ≠ 쓸 모델이면 닫는다 ===")
root, cpath = make_project()
try:
    rec = record(root, cpath, qualified=True, model="qwen3-coder-next")
    json.dump(rec, io.open(os.path.join(root, ".claude", "review", "local-qualified.json"), "w",
                           encoding="utf-8"), ensure_ascii=False)
    seats, note = _config.gate_local_qualification({"blind": "local"}, root, "qwen3-coder-next")
    chk("⑩ 같은 모델이면 자리가 남는다", seats.get("blind"), "local")
    seats, note = _config.gate_local_qualification({"blind": "local"}, root, "다른-모델-3b")
    chk("⑩ 다른 모델이면 none", seats.get("blind"), "none")
    chk_truthy("⑩ 사유에 두 모델이 다 나온다", note and "qwen3-coder-next" in note and "다른-모델-3b" in note)
    # ⚠ 구성이 비어 있으면(모델을 모르면) 대조를 건너뛴다 — 그 사실을 이 축이 고정한다.
    seats, note = _config.gate_local_qualification({"blind": "local"}, root, "")
    chk("⑩ 쓸 모델을 모르면 대조하지 않는다(다른 축은 그대로)", seats.get("blind"), "local")
finally:
    shutil.rmtree(root, ignore_errors=True)

print()
print("pass=%d fail=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
