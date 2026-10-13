#!/usr/bin/env python3
"""codex 가 지금 어느 계정으로 로그인했는지 보여 주고, 허용 도메인을 주면 맞는지 판정한다.

`codex login status` 는 「Logged in using ChatGPT」만 출력하고 계정을 보여 주지 않는다. 그래서
`$CODEX_HOME/auth.json`(없으면 `~/.codex/auth.json`)의 id_token 에서 이메일을 읽는다.

사용:  codex-account.py                 지금 계정을 출력한다
       codex-account.py <허용 도메인>   예) codex-account.py example.com
종료:  0 확인됨(허용 도메인을 줬으면 일치) · 1 허용 도메인과 다름 · 2 확인할 수 없음(로그인 안 됨 · API 키 로그인 · 파일 없음)
대조군: codex-account.py --selftest
"""
import base64
import json
import os
import sys
import tempfile


def account(home):
    try:
        with open(os.path.join(home, "auth.json"), encoding="utf-8") as f:
            token = json.load(f).get("tokens", {}).get("id_token", "")
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        email = json.loads(base64.urlsafe_b64decode(payload)).get("email", "")
    except Exception:
        return None
    return email.lower() if "@" in email else None


def check(allowed, home):
    got = account(home)
    if got is None:
        print("codex 계정을 확인할 수 없다(로그인 안 됨 · API 키 로그인 · auth.json 없음): " + home)
        return 2
    if not allowed:
        print(f"codex 계정: {got}")
        return 0
    want = allowed.lstrip("@").lower()
    print(f"codex 계정: {got} (허용 도메인: {want})")
    return 0 if got.rsplit("@", 1)[-1] == want else 1


def selftest():
    def fake(email):
        d = tempfile.mkdtemp()
        claims = base64.urlsafe_b64encode(json.dumps({"email": email}).encode()).decode().rstrip("=")
        with open(os.path.join(d, "auth.json"), "w", encoding="utf-8") as f:
            json.dump({"tokens": {"id_token": f"h.{claims}.s"}}, f)
        return d
    assert check("example.com", fake("a@example.com")) == 0
    assert check("@Example.com", fake("a@example.com")) == 0
    assert check("example.com", fake("a@gmail.com")) == 1
    assert check("example.com", fake("a@notexample.com")) == 1
    assert check("example.com", tempfile.mkdtemp()) == 2
    assert check(None, fake("a@gmail.com")) == 0
    assert check(None, tempfile.mkdtemp()) == 2
    print("selftest ok")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    if len(sys.argv) > 2:
        print(__doc__)
        sys.exit(2)
    home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    sys.exit(check(sys.argv[1] if len(sys.argv) == 2 else None, home))
