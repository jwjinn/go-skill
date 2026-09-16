# -*- coding: utf-8 -*-
"""go-coder 구성을 해석해 **이번 호출에서 켤 수 있나**를 출력한다.

형제인 `go-tester/tester/_config.py` 와 같은 모양이고, 다른 것은 셋이다:

  ① 옵트인 파일이 `.claude/coder/opt-in.json` 으로 **따로**다. 구현 위임은 테스트 위임보다
     큰 결정이라 한 번의 「쓴다」로 둘이 같이 켜지면 사람이 무엇에 답했는지 모르게 된다.
  ② 엔드포인트·모델 대신 **codex 프로파일**을 본다. 이 위임의 근거가 된 벤치마크가
     codex 경로에서 측정됐고, `model_catalog_json` 주입 효과는 그 경로 고유다.
  ③ 프로파일이 비어 있으면 **기본값을 지어내지 않는다.** 없는 프로파일로 codex 를 부르면
     base config 로 조용히 돌아 상용 모델에 청구된다 — 조용한 실패 중 가장 비싼 부류다.

⚠ 이 스크립트는 **판단하지 않는다.** 설정을 읽어 해석하고 그 선택의 대가를 함께 말한다.
⭐⭐ 기본은 **안 쓴다**(fail-closed). `enabled=ask` 인데 옵트인 기록이 없으면 `ENABLED=0` 이고,
   그 상태에서 coder.sh 는 codex 를 부르지도 않는다.
"""
import hashlib
import io
import json
import os
import shlex
import sys

# ⚠ 파이썬 3.6+ 어디서든 돌아야 한다(러너 python3 가 3.9 인 곳이 있다). f-string 을 쓰지 않는다.

DEFAULT_NAME = "config.default.json"


def load(path):
    if not os.path.exists(path):
        return {}
    try:
        return json.load(io.open(path, encoding="utf-8"))
    except Exception as e:
        sys.stderr.write("⚠ config 파싱 실패 — 기본값으로 진행한다: %s\n" % e)
        return {}


def resolve_config_path(argv, here):
    """구성 파일을 **프로젝트 우선**으로 찾는다 — 인자 > 프로젝트 > 플러그인 기본.

    ⭐ 어느 파일을 읽었는지 **출력한다.** 프로젝트 설정이 없는데 있는 것처럼 보이면
       사람이 엉뚱한 파일을 고치게 된다.
    """
    if len(argv) > 1 and argv[1]:
        return argv[1], "인자"
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    proj = os.path.join(root, ".claude", "coder", "config.json")
    if os.path.exists(proj):
        return proj, "프로젝트"
    return os.path.join(here, DEFAULT_NAME), "플러그인 기본"


def plan_fingerprint(plan_file):
    """계획 파일 **내용**의 해시. 경로가 아니라 내용에 묶는 이유는 그 경로가 상수이기 때문이다.

    ⚠ 첫 판은 경로로 묶었는데 모든 계획이 같은 경로를 공유해서, 앞 계획의 기록이 남으면
      묻지 않고 켜졌다. 내용 해시면 계획이 바뀌는 순간 무효가 된다.
    """
    if not plan_file or not os.path.exists(plan_file):
        return ""
    try:
        with open(plan_file, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:16]
    except Exception:
        return ""


def optin_state(project_root, plan_file):
    """(켤 수 있나, 사유)."""
    p = os.path.join(project_root, ".claude", "coder", "opt-in.json")
    if not os.path.exists(p):
        return False, ("not_opted_in(옵트인 기록 없음 — `/go` **§0-e** 가 묻고 기록한다. "
                       "그 절을 건너뛰면 여기서 영원히 닫힌다)")
    try:
        d = json.load(io.open(p, encoding="utf-8"))
    except Exception as e:
        return False, "optin_unreadable(%s)" % e
    if (d.get("answer") or "") != "use":
        return False, "optin_declined(기록된 답이 「쓴다」가 아니다)"
    recorded_path = d.get("plan_file") or ""
    if not recorded_path:
        return False, "optin_without_plan(기록에 plan_file 이 없다 — 어느 계획의 답인지 알 수 없다)"
    if os.path.abspath(recorded_path) != os.path.abspath(plan_file or ""):
        return False, "optin_for_other_plan(기록=%s)" % recorded_path
    recorded_fp = d.get("plan_fingerprint") or ""
    if not recorded_fp:
        return False, ("optin_without_fingerprint(기록에 plan_fingerprint 가 없다 — "
                       "그 경로는 모든 계획이 공유하는 상수라 경로만으로는 구분되지 않는다)")
    now_fp = plan_fingerprint(plan_file)
    if now_fp and recorded_fp != now_fp:
        return False, ("optin_stale(계획이 그 답 이후로 바뀌었다 — 기록 %s ≠ 지금 %s. "
                       "다시 물어라)" % (recorded_fp, now_fp))
    return True, "opted_in"


def which(cmd):
    for d in (os.environ.get("PATH") or "").split(os.pathsep):
        p = os.path.join(d, cmd)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return ""


def profile_path(name):
    """`~/.codex/<이름>.config.toml` 의 경로. 이름이 비면 빈 문자열."""
    if not name:
        return ""
    home = os.path.expanduser("~")
    return os.path.join(home, ".codex", "%s.config.toml" % name)


def q(v):
    return shlex.quote(str(v))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    path, origin = resolve_config_path(sys.argv, here)
    base = load(os.path.join(here, DEFAULT_NAME))
    cfg = dict(base)
    if os.path.abspath(path) != os.path.abspath(os.path.join(here, DEFAULT_NAME)):
        cfg.update(load(path))

    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    plan_file = os.environ.get("CLAUDE_PLAN_FILE") or os.path.join(root, ".claude", "plan-active.md")

    mode = (cfg.get("enabled") or "ask").strip().lower()
    if mode not in ("on", "off", "ask"):
        mode = "ask"

    profile = (cfg.get("profile") or "").strip()
    ppath = profile_path(profile)
    codex = which("codex")

    enabled = False
    if mode == "off":
        why = "disabled(구성에서 off 로 명시했다)"
    elif not codex:
        why = "no_codex(PATH 에 codex 가 없다 — 이 위임은 codex 경로에서만 근거가 있다)"
    elif not profile:
        why = ("no_profile(config 의 profile 이 비어 있다 — 기본값을 지어내지 않는다. "
               "없는 프로파일로 부르면 codex 가 base config 로 조용히 돌아 상용 모델에 청구된다)")
    elif not os.path.exists(ppath):
        why = "profile_missing(%s 가 없다)" % ppath
    elif mode == "on":
        enabled, why = True, "enabled(구성에서 on 으로 명시했다)"
    else:
        enabled, why = optin_state(root, plan_file)

    print("# go-coder 구성")
    print("#   읽은 파일: %s (%s)" % (path, origin))
    print("#   enabled=%s · 이번 호출: %s — %s" % (mode, "켬" if enabled else "끔", why))
    if mode == "ask" and not enabled and codex and profile and os.path.exists(ppath):
        print("#   ⭐ 켜려면 `/go` **§0-e** 가 사용자에게 물어 .claude/coder/opt-in.json 을 써야 한다.")
        print("#      ⚠ 그 절을 건너뛰면 사용자가 「쓴다」고 답해도 켤 방법이 없다.")
    print("")
    print("CODER_ENABLED=%s" % (1 if enabled else 0))
    print("CODER_MODE=%s" % mode)
    print("CODER_REASON=%s" % q(why))
    print("CODER_PROFILE=%s" % q(profile))
    print("CODER_PROFILE_PATH=%s" % q(ppath))
    print("CODER_CODEX=%s" % q(codex))
    print("CODER_TIMEOUT=%s" % int(cfg.get("timeout") or 900))
    print("CODER_GATE_TIMEOUT=%s" % int(cfg.get("gate_timeout") or 600))
    print("CODER_MAX_FILES=%s" % int(cfg.get("max_files") or 2))
    print("CODER_LEDGER=%s" % q(cfg.get("ledger") or ".claude/coder/coder.jsonl"))
    print("CODER_PLAN_FILE=%s" % q(plan_file))
    print("CODER_PLAN_FINGERPRINT=%s" % q(plan_fingerprint(plan_file)))


if __name__ == "__main__":
    main()
