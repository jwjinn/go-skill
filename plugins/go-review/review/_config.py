# -*- coding: utf-8 -*-
"""리뷰 구성을 해석해 **이번 라운드에 누구를 어디에 앉힐지** 출력한다.

⭐ 왜 파일인가: 구성을 스킬 파일(`commands/*.md`)에 박으면 플러그인 업데이트에 덮이고,
   프로젝트마다 다른 예산을 표현할 수 없다. 구성은 데이터이지 지시문이 아니다.

⚠ 이 스크립트는 **판단하지 않는다** — 설정을 읽어 해석하고, 그 선택의 대가를 함께 말한다.
  무엇을 고를지는 사람이 `config.json` 에서 정한다.
"""
import io
import json
import os
import shutil
import sys

PRESETS = {
    # ⭐ P1 은 「Claude 로 되돌리는 자리」다 — P2 가 잘 안 되면 여기로 돌아온다.
    "P1": {"contract": "claude", "blind": "claude", "cross": "codex", "merger": "claude"},
    # ⭐ P2 기본(2026-09-02 사용자 결정) — 리뷰를 통째로 codex 에 맡기고 Claude 는 구현·반영만.
    #    근거·잃는 것은 config.json 의 「_왜 P2 가 기본인가」에 있다.
    "P2": {"contract": "codex",  "blind": "codex",  "cross": "none",  "merger": "codex"},
    "P3": {"contract": "none",   "blind": "codex",  "cross": "none",  "merger": "codex"},
    # ⚠ 병합만 Claude 로 되돌리는 중간 단계 — P2 의 오탐이 감당 안 될 때 첫 후퇴선이다.
    "P2c": {"contract": "codex", "blind": "codex",  "cross": "none",  "merger": "claude"},
}

# 자리 → (산출 파일 이름, 무엇을 받나)
SEAT_INFO = {
    "contract": ("contract", "브리핑 전부 + diff", "요구 충족·목표 이탈·**주장이 사실인가**"),
    "blind":    ("blind",    "diff **만**",        "이 코드에 무엇이 잘못됐나(편향 0)"),
    "cross":    ("cross",    "목표 1문단 + diff",  "다른 계열의 눈"),
}


def load(path):
    if not os.path.exists(path):
        return {}
    try:
        return json.load(io.open(path, encoding="utf-8"))
    except Exception as e:
        sys.stderr.write("⚠ config.json 파싱 실패 — 기본(P1)으로 진행한다: %s\n" % e)
        return {}


def resolve_config_path(argv):
    """구성 파일을 **프로젝트 우선**으로 찾는다 — 인자 > 프로젝트 > 플러그인 기본.

    ⭐ 플러그인으로 배포되면 정본이 둘이 될 수 있는 자리다. 우선순위를 한 곳에서
      정하고 **어느 파일을 읽었는지 출력**한다 — 프로젝트 설정이 없는데 있는 것처럼
      보이면 「왜 내 설정이 안 먹나」를 아무도 못 찾는다(정직 공백).
    """
    if len(argv) > 1:
        return argv[1], "인자"
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    proj = os.path.join(root, ".claude", "review", "config.json")
    if os.path.exists(proj):
        return proj, "프로젝트"
    return os.path.join(here, "config.default.json"), "플러그인 기본"


def codex_available():
    """codex 를 실제로 쓸 수 있나. ⚠ 테스트가 흔들 수 있게 env 로 덮을 수 있다."""
    forced = os.environ.get("CLAUDE_REVIEW_FORCE_NO_CODEX")
    if forced and forced not in ("0", "false", ""):
        return False
    return shutil.which("codex") is not None


def demote_without_codex(preset, seats):
    """⛔ **codex 가 없으면 preset 을 P1 로 내린다** (2026-09-07 사용자 결정).

    > 「그냥 **codex가 없으면 리뷰를 claude에게 시킬게.**」

    ⭐ 왜 스크립트인가: 종전에는 지시문(review-loop.md)에 「⚠ codex 가 없으면 P1 으로
      내려라」 한 줄이 있었다. 그것은 **규율**이고, 빠뜨리면 기본 preset(P2)의 전 자리가
      codex 라 **리뷰가 0회**가 된다 — fail-open 방향이라 규율로 두면 안 되는 자리다
      (이 체인이 잡으려는 부류 그 자체다: 「게이트가 조용히 무장해제」).

    ⚠ 자리 중 **하나라도** codex 면 내린다. 일부만 비우면 「교차검증이 성립하지 않는다」
      경고만 뜨고 그 라운드는 리뷰어가 하나뿐인 채로 돈다.
    ⚠⚠ custom 구성도 같이 내린다 — 사람이 손으로 짰어도 codex 가 없으면 못 돈다.
    """
    uses_codex = any(v == "codex" for v in seats.values())
    if not uses_codex:
        return preset, seats, None
    note = (
        "⛔ **codex 를 찾지 못해 preset 을 %s → P1 로 내렸다**(claude 계약검증·무편향·병합).\n"
        "   근거: codex 자리를 그대로 두면 그 자리는 **아무도 리뷰하지 않는다** — 기본 preset 은\n"
        "   전 자리가 codex 라 최악의 경우 리뷰가 0회가 된다(fail-open).\n"
        "   ⚠ 교차 모델 검증층이 이 라운드에는 **없다**. 보고에 그 사실을 적어라.\n"
        "   codex 를 설치했는데 이 문구가 보이면 PATH 를 확인하라." % preset
    )
    down = dict(PRESETS["P1"])
    # ⛔⛔ **P1 도 교차 자리가 codex 다** — 그것을 그대로 두면 내려놓고도 그 자리는 안 돈다
    #   (내 첫 판이 실제로 그랬다: 출력이 「cross codex」였다). 없는 도구를 가리키는 구성은
    #   구성이 아니라 거짓이므로, 그 자리를 **비운다**.
    #   ⚠ 그러면 리뷰 자리가 둘이라 아래 「교차검증이 성립하지 않는다」 경고는 뜨지 않고,
    #     대신 「사슬이 전부 claude」 경고가 뜬다 — 그것이 이 상황의 정확한 사실이다.
    down = dict((k, ("none" if v == "codex" else v)) for k, v in down.items())
    return "P1", down, note


def cases_hash(project_root):
    """이 프로젝트의 평가 케이스 파일들의 **내용 해시**.

    ⭐ 왜 내용 해시인가: `mtime` 으로 낡음을 판정하면 **체크아웃만 해도** 「낡았다」가 뜬다.
      자격이 낡았다는 것은 「무엇으로 쟀는지가 바뀌었다」는 뜻이고, 그것은 파일의 **내용**이다.

    ⚠ 케이스 파일이 하나도 없으면 `None` 을 돌린다 — 그때는 해시를 맞출 수 없으므로
      자격을 인정하지 않는다(모르면 닫는다).
    """
    import glob
    import hashlib
    pats = [os.path.join(project_root, ".claude", "review", "eval", "cases", "*.jsonl"),
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "eval", "cases", "*.jsonl")]
    files = []
    for p in pats:
        files += sorted(glob.glob(p))
    if not files:
        return None
    h = hashlib.sha256()
    for f in files:
        try:
            h.update(io.open(f, "rb").read())
        except Exception:
            return None
    return h.hexdigest()[:16]


def gate_local_qualification(seats, project_root):
    """`local` 자리에 **자격을 통과한 모델만** 앉힌다 (2026-09-17 · fail-closed).

    사용자 지시: 「로컬 모델의 경우에는 모델 마다의 성능 차이가 있으니, 이 모델을 리뷰로
    사용하기 전에 **특정 기준 이상인지를 먼저 선행해서 판단을 하는 프로세스**가 있어야」.

    ⛔ **왜 스크립트인가.** 이것을 지시문의 규율로 두면 빠뜨렸을 때 아무도 모른다 —
      codex 부재 폴백이 정확히 그 이유로 `review-loop.md` 에서 여기로 옮겨 왔다
      (`demote_without_codex` 주석 참조). 자격 게이트는 같은 부류의 자리다.

    ⭐ **닫는 쪽이 기본이다.** 기록이 없거나·미달이거나·낡았거나·읽을 수 없으면 그 자리를
      `none` 으로 바꾼다. 「리뷰어가 있는데 아무것도 못 잡는 상태」는 리뷰가 없는 것보다
      나쁘다 — 있다고 믿기 때문이다.

    반환: (seats, note) — note 는 바꾼 것이 없으면 `None`.
    """
    if not any(v == "local" for v in seats.values()):
        return seats, None

    rec_path = os.path.join(project_root, ".claude", "review", "local-qualified.json")
    why = None
    rec = None
    if not os.path.exists(rec_path):
        why = "자격 기록이 없다(%s)" % rec_path
    else:
        try:
            rec = json.load(io.open(rec_path, encoding="utf-8"))
        except Exception as e:
            why = "자격 기록을 읽지 못했다(%s) — 모르면 닫는다" % e

    if rec is not None and why is None:
        if not rec.get("qualified"):
            why = "자격 미달이다(qualified=false · %s)" % (rec.get("why") or "사유 없음")
        else:
            now = cases_hash(project_root)
            if now is None:
                why = "평가 케이스 파일을 찾지 못해 자격의 유효 범위를 맞출 수 없다"
            elif rec.get("cases_hash") != now:
                why = ("자격이 낡았다 — 잰 케이스(%s) ≠ 지금 케이스(%s). 다시 재라"
                       % (rec.get("cases_hash"), now))

    if why is None:
        return seats, None

    changed = [k for k, v in seats.items() if v == "local"]
    seats = dict((k, ("none" if v == "local" else v)) for k, v in seats.items())
    note = (
        "⛔ **로컬 모델 자리를 비웠다**(%s) — %s\n"
        "   근거: 재지 않은 모델을 리뷰어로 앉히면 「리뷰가 있는데 아무것도 못 잡는 상태」가\n"
        "   되고, 그것은 리뷰가 없는 것보다 나쁘다(있다고 믿기 때문이다).\n"
        "   ⭐ 재는 법: `review/eval/` 로 재고 그 결과를 `.claude/review/local-qualified.json`\n"
        "      에 남겨라(qualified·cases_hash 포함). 낡음 판정은 **케이스 내용 해시**다."
        % (", ".join(changed), why)
    )
    return seats, note


def main():
    cfg_path, cfg_src = resolve_config_path(sys.argv)
    cfg = load(cfg_path)

    preset = cfg.get("preset") or "P1"
    if preset == "custom":
        seats = dict((k, v) for k, v in (cfg.get("seats") or {}).items() if not k.startswith("_"))
    else:
        seats = dict(PRESETS.get(preset, PRESETS["P1"]))
    # ⭐ codex 부재는 **구성 해석의 일부**다(지시문의 규율이 아니다 — demote_without_codex 근거).
    demote_note = None
    if not codex_available():
        preset, seats, demote_note = demote_without_codex(preset, seats)
    # ⭐ 로컬 모델 자격도 **구성 해석의 일부**다 — 같은 이유로 여기 둔다(지시문 규율이 아니다).
    proj_root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    seats, local_note = gate_local_qualification(seats, proj_root)
    models = cfg.get("models") or {}
    mc = (models.get("claude") or "").strip()
    mx = (models.get("codex") or "").strip()

    print("리뷰 구성 — preset **%s**%s" % (preset, "" if preset in PRESETS or preset == "custom"
                                          else "  ⚠ 모르는 preset 이라 P1 로 진행한다"))
    print("구성 파일 — %s: %s" % (cfg_src, cfg_path))
    if demote_note:
        print()
        print(demote_note)
    if local_note:
        print()
        print(local_note)
    if cfg_src == "플러그인 기본":
        print("  ⭐ 이 프로젝트 전용으로 바꾸려면 `.claude/review/config.json` 에 복사해 고쳐라")
        print("     (플러그인 파일을 고치면 다음 업데이트에 덮인다).")
    print()
    active = []
    for seat in ("contract", "blind", "cross"):
        who = seats.get(seat, "none")
        if who == "none":
            print("  %-9s —          (이 자리는 비운다)" % seat)
            continue
        name, gets, asks = SEAT_INFO[seat]
        out = "%s-%s" % (who, name) if who == "codex" and seat != "cross" else \
              ("codex" if who == "codex" else "claude-%s" % name)
        active.append((seat, who, out))
        model = mx if who == "codex" else mc
        print("  %-9s %-7s → $ROUND/%-18s %s" % (seat, who, out + ".json", gets))
        print("            %s%s" % (asks, ("  · 모델 %s" % model) if model else ""))
    merger = seats.get("merger", "claude")
    print("  %-9s %-7s → $ROUND/merged.json    검증·기각(합치기가 아니다)" % ("merger", merger))
    print()

    if len(active) < 2:
        print("⚠⚠ 리뷰 자리가 %d개다 — **교차검증이 성립하지 않는다.**" % len(active))
        print("   합의 신호가 없으므로 모든 발견이 단독이고 전부 병합자 확인 대상이 된다.")
        print()
    # ⭐ 경고의 축을 「병합자가 claude 인가」에서 **「사슬에 다른 모델 계열이 있는가」**로 바꿨다
    #   (2026-09-02). 전자는 기본 구성을 고장처럼 보이게 하고, 실제 위험을 지목하지도 못한다 —
    #   위험은 병합자의 정체가 아니라 **어디에도 교차 검증층이 없는 것**이다.
    chain = [w for _, w, _ in active] + ([merger] if merger != "none" else [])
    if chain and len(set(chain)) == 1:
        only = chain[0]
        print("⚠ 리뷰 사슬이 전부 **%s** 다 — 교차 모델 검증층이 없다." % only)
        if only == "codex":
            print("   측정된 대가 둘: ① 같은 케이스 17건에서 Claude blind 오탐 **0/5** 대 codex **3/5**")
            print("   ② 실측 합의 실패 1건 — codex 두 자리가 **합의한 blocker 가 오탐**이었다.")
            print("   ⭐ 같은 계열끼리의 합의는 「독립 동의」가 아니다 — 합의를 검증으로 읽지 마라.")
            print("   ⭐⭐ 이 구성의 안전장치는 **사람 판정**이다: 라운드마다 verdict.sh 로 라벨을")
            print("      채워라. 안 채우면 이 결정이 옳았는지 재는 수단이 없다.")
            print("   되돌리려면: `.claude/review/config.json` 의 preset 을 **P2c**(병합만 claude) 또는 **P1** 로.")
        else:
            print("   자기 리뷰에 가까워진다 — 측정 서열은 신선 문맥 28.6% > 자기 리뷰 24.6% 다.")
            # ⭐ 반대 방향의 실측이 하나 있다(2026-09-16). 경고를 지우지 않고 **조건을 덧붙인다** —
            #   반증 데이터 하나로 규약을 뒤집지 않되, 있는 것을 숨기지도 않는다.
            #   ⚠ 이것과 codex 쪽 「합의 실패 1건」은 **정확히 반대 방향이고 둘 다 표본 1** 이다.
            print("   ⭐ 다만 실사용 보고 하나(2026-09-16): 전부 claude 인 사슬에서 셋이 **독립적으로")
            print("      같은 blocker 를 짚었고**(대조군으로 실증) contract 자리가 거짓 반영 둘을 잡았다.")
            print("      ⚠ 표본 1이고 codex 쪽 「합의 실패 1건」과 반대 방향이다 — 어느 쪽도 일반화하지 마라.")
            print("      말할 수 있는 것: 교차 계열이 없다고 사슬이 쓸모없어지지는 않는다.")
            # ⚠ 안내가 **지금 가능한 것**을 말해야 한다 — codex 가 없는데 「codex 를 앉혀라」는
            #   할 수 없는 일을 시키는 것이다(위에서 그 이유로 내려온 경우가 그렇다).
            if demote_note:
                print("   ⭐ 이 라운드는 **codex 부재로 내려온 구성**이다 — 되돌리려면 codex 를 설치하라.")
            else:
                print("   교차 자리에 codex 를 앉히는 것을 고려하라(preset P1).")
        print()
    if all(w == "codex" for _, w, _ in active) and active and merger == "claude":
        print("⚠ 리뷰어가 전부 codex 이고 병합자만 claude 다 — 문헌이 권고하는 방향이지만")
        print("   (Claude→Codex +18.1pp) 병합자가 더 많이 기각해야 하므로 **병합 비용이 늘 수 있다.**")
        print()
    if any(w == "codex" for _, w, _ in active) and "blind" in [s for s, w, _ in active if w == "codex"]:
        print("⚠ codex 를 「브리핑 없이」 앉히는 조건(blind 자리)은 표본이 얇다 — 라운드를 쌓아라.")
        print()

    # `_dedup.py` 가 집계하려면 이 이름들을 알아야 한다 — 그대로 넘길 수 있게 출력한다.
    names = ",".join(o for _, _, o in active)
    print("_dedup.py 에 넘길 자리 이름:")
    print("  CLAUDE_REVIEW_REVIEWERS=%s" % names)
    # ⭐ 모델도 **그대로 export 할 수 있는 형태로** 내보낸다(2026-09-09).
    #   종전에는 자리 설명 뒤에 「· 모델 X」라고 산문으로만 붙였고, 실제로 `-m` 을 붙이는 것은
    #   실행자의 규율이었다 — 빠뜨리면 config 에 적힌 모델이 **조용히 무시된다**(「정본이 있는데
    #   아무도 안 쓴다」 부류). 값이 비면 줄 자체를 내지 않는다: 빈 export 를 내면 호출 블록의
    #   `${VAR:+-m $VAR}` 가 의미를 잃고, 「기본을 쓴다」와 「빈 모델을 지정했다」가 섞인다.
    if mx:
        print("  CLAUDE_REVIEW_CODEX_MODEL=%s" % mx)
    if mc:
        print("  CLAUDE_REVIEW_CLAUDE_MODEL=%s" % mc)
    print()
    print("split_lines(=_scope.py 상한): %s" % (cfg.get("split_lines") or 2000))
    return 0


if __name__ == "__main__":
    sys.exit(main())
