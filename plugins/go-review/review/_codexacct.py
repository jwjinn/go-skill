# -*- coding: utf-8 -*-
"""리뷰에 쓸 codex 계정이 **허용된 계정인가**를 판정한다 (2026-09-18 · fail-closed).

사용자 지시(2026-09-18): 「codex 계정이 둘인데 `jwjinn@gmail.com` 은 개인 계정이라
**codex 리뷰에 절대 사용하게 하지 마라.** 회사 계정 `@maymust.com` 에서만 쓰게 해 달라.」

⭐ 왜 스크립트인가: 「회사 계정으로 로그인한 뒤에 돌려라」를 지시문에 적어 두면 그것은
  규율이고, 빠뜨렸을 때 **아무 표시 없이** 개인 계정으로 리뷰가 돈다. 산출물이 똑같아
  보이므로 사람은 알아차릴 수 없다. codex 부재 폴백과 로컬 모델 자격 게이트가 정확히
  같은 이유로 지시문에서 이 디렉토리로 옮겨 왔다(`_config.py` 의 두 함수 주석 참조).

⭐⭐ 판정 방향이 이 모듈의 본체다 — **허용을 확인했을 때만 연다.** 파일이 없거나·API 키
  모드라 이메일을 알 수 없거나·토큰을 파싱하지 못하거나·도메인이 다르면 전부 닫는다.
  「계정을 확인하지 못했다」와 「허용 계정이다」는 다른 사실이고, 앞의 것을 통과시키면
  게이트가 통째로 없는 것과 같아진다.

⚠ 계정의 정본은 `CODEX_HOME` 이다. Orca 는 계정마다 다른 홈을 주고
  (`~/Library/Application Support/orca/codex-accounts/<uuid>/home`), 그 변수가 없는 셸은
  `~/.codex` 로 떨어진다 — 2026-09-18 실측에서 그 둘이 서로 다른 계정이었다.

⚠⚠ 도메인 비교에는 `@` 를 포함시킨다. `endswith("maymust.com")` 만 보면
  `attacker-maymust.com` 도 통과한다(대조군이 그 경로를 잡는다).

정책이 어디서 오나 (앞의 것이 이긴다):
  ① env `CLAUDE_REVIEW_CODEX_DOMAINS` — 콤마로 나눈 도메인 목록. 기기 단위 정책
  ② 리뷰 구성 `config.json` 의 `codex_account_domains` 배열 — 레포 단위 정책
  ③ 둘 다 없으면 **가리지 않는다**. 이 플러그인은 공용이라 남의 기기를 막지 않는다
⚠ `CLAUDE_REVIEW_CODEX_ACCOUNT_GATE=off` 는 사람이 명시적으로 끄는 스위치다.
  값이 정확히 `off` 일 때만 꺼진다(`1`·`true` 같은 값은 끄는 것으로 보지 않는다 —
  스위치 값이 여럿이면 「껐다고 생각했는데 켜져 있다」가 생긴다).
"""
import base64
import io
import json
import os

ENV_DOMAINS = "CLAUDE_REVIEW_CODEX_DOMAINS"
ENV_GATE = "CLAUDE_REVIEW_CODEX_ACCOUNT_GATE"
CFG_KEY = "codex_account_domains"


def codex_home():
    """codex 가 실제로 읽을 홈 디렉토리."""
    h = (os.environ.get("CODEX_HOME") or "").strip()
    return h if h else os.path.join(os.path.expanduser("~"), ".codex")


def _jwt_email(token):
    """JWT 페이로드에서 `email` 클레임만 꺼낸다. 서명은 검증하지 않는다.

    ⚠ 서명을 안 보는 것이 여기서는 문제가 되지 않는다 — 이 토큰은 **codex 자신이 방금
      저장한 자기 자격증명**이고, 우리가 막으려는 것은 위조가 아니라 「사람이 계정을
      바꿔 놓은 줄 모르고 리뷰를 돌리는 것」이다.
    """
    if not isinstance(token, str) or token.count(".") < 2:
        return None
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")).decode("utf-8"))
    except Exception:
        return None
    if not isinstance(claims, dict):
        return None
    email = claims.get("email")
    if not isinstance(email, str) or not email.strip():
        return None
    return email.strip().lower()


def active_account(home=None):
    """(이메일, 못 읽은 사유) — 확정하지 못하면 이메일이 `None` 이고 사유가 채워진다."""
    home = home or codex_home()
    path = os.path.join(home, "auth.json")
    if not os.path.exists(path):
        return None, "로그인 기록이 없다: %s" % path
    try:
        data = json.load(io.open(path, encoding="utf-8"))
    except Exception as e:
        return None, "auth.json 을 읽지 못했다(%s): %s" % (path, e)
    if not isinstance(data, dict):
        return None, "auth.json 의 형식이 예상과 다르다: %s" % path
    if data.get("OPENAI_API_KEY"):
        return None, "API 키 모드라 어느 계정인지 확인할 수 없다: %s" % path
    tokens = data.get("tokens")
    if not isinstance(tokens, dict):
        return None, "ChatGPT 토큰이 없다: %s" % path
    email = _jwt_email(tokens.get("id_token"))
    if not email:
        return None, "id_token 에서 이메일을 읽지 못했다: %s" % path
    return email, ""


def allowed_domains(cfg=None):
    """허용 도메인 목록(소문자·`@` 없음). 비어 있으면 「가리지 않는다」는 뜻이다."""
    raw = (os.environ.get(ENV_DOMAINS) or "").strip()
    if not raw and isinstance(cfg, dict):
        v = cfg.get(CFG_KEY)
        if isinstance(v, list):
            raw = ",".join([str(x) for x in v])
        elif isinstance(v, str):
            raw = v
    out = []
    for d in raw.split(","):
        d = d.strip().lower().lstrip("@")
        if d and d not in out:
            out.append(d)
    return out


def gate_is_off():
    return (os.environ.get(ENV_GATE) or "").strip().lower() == "off"


def check(cfg=None, home=None):
    """(ok, 사유) — ⭐ 허용을 **확인했을 때만** True 다.

    사유는 ok 가 True 면 확인된 이메일(또는 빈 문자열), False 면 왜 닫았는지다.
    """
    if gate_is_off():
        return True, "계정 게이트가 꺼져 있다(%s=off)" % ENV_GATE
    doms = allowed_domains(cfg)
    if not doms:
        return True, ""
    email, why = active_account(home)
    if not email:
        return False, "codex 계정을 확인하지 못했다 — %s (허용 도메인: %s)" % (why, ", ".join(doms))
    for d in doms:
        if email.endswith("@" + d):
            return True, email
    return False, "허용되지 않은 codex 계정이다: %s (허용 도메인: %s)" % (email, ", ".join(doms))


def _load_project_cfg():
    """리뷰 구성 파일을 `_config.py` 와 **같은 규칙으로** 찾는다(정본을 둘로 두지 않는다)."""
    import sys
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        import _config
        path, _src = _config.resolve_config_path([sys.argv[0]])
        return _config.load(path)
    except Exception:
        return {}


if __name__ == "__main__":
    import sys
    ok, why = check(_load_project_cfg())
    if ok:
        print("codex 계정 — %s" % (why or "가리지 않는다(허용 도메인 정책이 없다)"))
        sys.exit(0)
    print("⛔ %s" % why, file=sys.stderr)
    print("   홈: %s" % codex_home(), file=sys.stderr)
    print("   고치는 법: 허용 계정으로 `codex login` 하거나, CODEX_HOME 을 그 계정의", file=sys.stderr)
    print("   홈으로 맞춰라. 정책 자체를 바꾸려면 %s 또는 config.json 의 %s 를 고쳐라."
          % (ENV_DOMAINS, CFG_KEY), file=sys.stderr)
    sys.exit(1)
