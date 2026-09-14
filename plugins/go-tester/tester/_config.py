# -*- coding: utf-8 -*-
"""테스트 에이전트 구성을 해석해 **이번 호출에서 켤 수 있나**를 출력한다.

⭐ 왜 파일인가: 구성을 지시문(`commands/*.md`)에 박으면 플러그인 업데이트에 덮이고,
   프로젝트마다 다른 엔드포인트를 표현할 수 없다. 구성은 데이터이지 지시문이 아니다.

⚠ 이 스크립트는 **판단하지 않는다** — 설정을 읽어 해석하고, 그 선택의 대가를 함께 말한다.
  무엇을 고를지는 사람이 `config.json` 과 「쓴다/안 쓴다」 답으로 정한다.

⭐⭐ 기본은 **안 쓴다**(fail-closed). `enabled=ask` 인데 옵트인 기록이 없으면 `ENABLED=0` 이고,
   그 상태에서 tester.sh 는 프록시조차 띄우지 않는다. 「묻지 않고 지나가는 경로」가
   켜지는 쪽으로 열리면 「기본은 안 씀」이 거짓이 된다.
"""
import io
import json
import os
import shlex
import sys

# ⚠ 파이썬 3.6+ 어디서든 돌아야 한다(러너 python3 가 3.9 인 곳이 있다).
#   f-string 은 3.6+ 이므로 쓰지 않는다 — 이 레포군의 다른 스크립트와 같은 규약이다.

DEFAULT_NAME = "config.default.json"


def load(path):
    if not os.path.exists(path):
        return {}
    try:
        return json.load(io.open(path, encoding="utf-8"))
    except Exception as e:
        sys.stderr.write("⚠ config 파싱 실패 — 기본값으로 진행한다: %s\n" % e)
        return {}


def resolve_config_path(argv):
    """구성 파일을 **프로젝트 우선**으로 찾는다 — 인자 > 프로젝트 > 플러그인 기본.

    ⭐ 어느 파일을 읽었는지 **출력한다.** 프로젝트 설정이 없는데 있는 것처럼 보이면
      「왜 내 설정이 안 먹나」를 아무도 못 찾는다(정직 공백).
    """
    if len(argv) > 1 and argv[1]:
        return argv[1], "인자"
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    proj = os.path.join(root, ".claude", "tester", "config.json")
    if os.path.exists(proj):
        return proj, "프로젝트"
    return os.path.join(here, DEFAULT_NAME), "플러그인 기본"


def strip_comments(cfg):
    """`_` 로 시작하는 키는 주석이다 — 해석에서 뺀다."""
    return dict((k, v) for k, v in cfg.items() if not k.startswith("_"))


def merged(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    base = strip_comments(load(os.path.join(here, DEFAULT_NAME)))
    path, origin = resolve_config_path(argv)
    if os.path.abspath(path) != os.path.abspath(os.path.join(here, DEFAULT_NAME)):
        base.update(strip_comments(load(path)))
    return base, path, origin


def optin_state(cfg, project_root, plan_file):
    """옵트인 기록을 읽어 **이 계획에 대해** 켜졌는지 판정한다.

    ⭐ 계획 파일 경로에 묶는 이유: 옵트인이 다음 계획으로 조용히 이어지면
      「기본은 안 씀」이 거짓이 된다. 사용자는 계획마다 답한다.

    반환: (켜졌나, 사유)
    """
    p = os.path.join(project_root, ".claude", "tester", "opt-in.json")
    if not os.path.exists(p):
        return False, "not_opted_in(옵트인 기록 없음 — `/go` 가 「쓴다」 답을 받으면 쓴다)"
    try:
        d = json.load(io.open(p, encoding="utf-8"))
    except Exception as e:
        return False, "optin_unreadable(%s)" % e
    if d.get("answer") != "use":
        return False, "opted_out(기록된 답: %s)" % d.get("answer")
    recorded = d.get("plan_file") or ""
    if plan_file and recorded and os.path.abspath(recorded) != os.path.abspath(plan_file):
        # ⚠ 다른 계획의 옵트인이다. 이어 쓰지 않는다.
        return False, "optin_for_other_plan(기록=%s)" % recorded
    return True, "opted_in(heartbeat %s)" % (d.get("heartbeat_at") or "시각 미기록")


def main():
    cfg, path, origin = merged(sys.argv)
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    plan_file = os.environ.get("CLAUDE_PLAN_FILE") or os.path.join(root, ".claude", "plan-active.md")

    enabled = str(cfg.get("enabled", "ask")).strip().lower()
    if enabled not in ("ask", "on", "off"):
        sys.stderr.write("⚠ enabled 값이 ask|on|off 가 아니다(%r) — ask 로 본다.\n" % enabled)
        enabled = "ask"

    endpoint = (cfg.get("endpoint") or "").strip()
    model = (cfg.get("model") or "").strip()

    if enabled == "off":
        on, why = False, "disabled(구성에서 off)"
    elif not endpoint or not model:
        # ⚠ 「엔드포인트를 모른다」와 「꺼졌다」는 다르다 — 사유를 갈라서 말한다.
        on, why = False, "no_endpoint(config 의 endpoint·model 이 비어 있다)"
    elif enabled == "on":
        on, why = True, "always_on(구성에서 on — 묻지 않는다)"
    else:
        on, why = optin_state(cfg, root, plan_file)

    print("# 테스트 에이전트 구성")
    print("#   읽은 파일: %s (%s)" % (path, origin))
    print("#   enabled=%s · 이번 호출: %s — %s" % (enabled, "켬" if on else "끔", why))
    if enabled == "ask" and not on and endpoint and model:
        print("#   ⭐ 켜려면 `/go` 가 heartbeat 를 돌리고 사용자에게 물어 opt-in.json 을 써야 한다.")
    print("")
    # ⚠ 값은 **셸 안전하게 인용**해서 내보낸다. 사유 문자열에 괄호·공백·한국어가 들어가는데,
    #   인용하지 않으면 호출자의 `eval` 이 `syntax error near unexpected token '('` 로 죽는다.
    #   실측으로 밟았다(2026-09-15) — 그리고 그 실패는 조용했다: eval 이 죽어도 스크립트는
    #   계속 돌아 사유가 빈 채로 보고됐다. 값의 형태를 호출자가 감당하게 두면 안 된다.
    def q(v):
        return shlex.quote(str(v))

    print("TESTER_ENABLED=%d" % (1 if on else 0))
    print("TESTER_MODE=%s" % q(enabled))
    print("TESTER_REASON=%s" % q(why))
    print("TESTER_ENDPOINT=%s" % q(endpoint))
    print("TESTER_MODEL=%s" % q(model))
    print("TESTER_PROXY_PORT=%s" % q(cfg.get("proxy_port", 4141)))
    print("TESTER_PROXY_KEY=%s" % q(cfg.get("proxy_master_key", "sk-go-tester-local")))
    print("TESTER_MAX_CONCURRENCY=%s" % q(cfg.get("max_concurrency", 4)))
    print("TESTER_TIMEOUT=%s" % q(cfg.get("timeout_sec", 900)))
    print("TESTER_PROBE_TIMEOUT=%s" % q(cfg.get("probe_timeout_sec", 15)))
    print("TESTER_LEDGER=%s" % q(cfg.get("ledger", ".claude/tester/tester.jsonl")))
    print("TESTER_TOOLS=%s" % q(cfg.get("tools", "Read,Write,Edit,Bash,Glob,Grep")))
    pats = cfg.get("test_path_patterns") or []
    print("TESTER_TEST_PATTERNS=%s" % q("|".join(pats)))
    print("TESTER_PLAN_FILE=%s" % q(plan_file))


if __name__ == "__main__":
    main()
