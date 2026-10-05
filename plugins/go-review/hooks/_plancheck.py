#!/usr/bin/env python3
"""_plancheck.py — 초안이 **승인받을 만한 모양인가**를 기계로 잰다(2026-10-05).

# 왜 있나

사용자 지시(2026-10-05): 「스킬안에 플랜들이 제대로 되었는지 확인을 하는 것도 있지 않나?
지금같은 것들은 막고 싶은데」 · 「리뷰까지 끝나고 리뷰로 수정을 하고 나서 원래 계획대로 되었는지를
판단하는 것도 넣어야할까?」

그날 한 세션에서 세 가지가 동시에 새었다.
  ① 요구가 대화 수십 개에 흩어져 있었는데 초안을 **모델의 기억**으로 모아 썼다 → 「전 화면 UI/UX」가 빠졌다.
  ② 이틀 전 계획에서 「현행 유지」로 닫힌 항목을 확인하지 않고 다시 넣었다.
  ③ 열린 결정이 있는데 모델이 Skill 도구로 `/go` 를 스스로 불렀다(UserPromptSubmit 훅은 사람이 친
     `/go` 에만 걸리므로 그 경로에는 아무 검사도 없었다 — 그 구멍은 `go-skill-gate.sh` 가 막는다).
  그리고 계획 끝의 「최종 실측 검증」이 그날 사용자가 정한 규칙인데도 초안에 단계로 들어가지 않았다.

이 스크립트는 그중 **초안이 담아야 하는 것** 셋을 잰다.
  reqtrace  — `## 요구 추적` 표가 `추적 시작:` 이후의 **사람이 쓴 발화를 전부** 받는가
  decisions — `## 이전 결정 대조` 절이 같은 저장소의 다른 계획을 **전부** 들여다봤다고 말하는가
  vstage    — `## V` 절(리뷰 반영 뒤 최종 검증)에 독립 검증자와 수용 기준 충족표가 있는가

# 판정 규약(이 플러그인의 다른 검사와 같다)

  rc 0 — 통과 · rc 1 — 위반(무엇이 빠졌는지 출력) · rc 2 — **잴 수 없다**(입력이 없거나 깨졌다).
  ⚠ rc 2 는 「통과」가 아니다. 호출부가 그것을 통과로 읽으면 이 검사가 조용히 꺼진다
    (이 저장소가 여러 번 밟은 「초록은 돌았다가 아니라 실패하지 않았다」).

# ⚠ 「사람이 쓴 발화」의 정의 — 두 모양이 있다(2026-10-05 실측)

  · 턴 첫 메시지: `type:"user"` · `toolUseResult` 없음 · `isMeta` 아님 · 내용에 `tool_result` 없음
  · **작업 중에 보낸 메시지**: `type:"attachment"` · `attachment.type == "queued_command"` ·
    `origin.kind == "human"` · `commandMode == "prompt"`
  ⚠⚠ 기존 게이트들의 판별은 앞의 것만 본다. 그날 한 세션의 사람 발화 가운데 작업 중 메시지가
    **183줄**이었고(같은 기록의 사람 user 줄 293줄), 요구의 상당수가 거기 있었다. 앞의 것만 세면
    추적표가 그 요구들을 빼도 통과한다.
  ⚠ 하네스가 주입한 글(작업 알림 · 다른 에이전트 보고 · 압축 요약 · 스킬 본문)은 사람 발화가 아니다.
"""
import argparse
import glob
import json
import os
import re
import sys

# 하네스가 user 줄로 주입하는 글의 머리. 사람이 쓴 것이 아니다.
_INJECTED = (
    "<task-notification", "<agent-message", "Another Claude session", "[SYSTEM NOTIFICATION",
    "<system-reminder>", "This session is being continued", "(Re-invocation of",
    "Base directory for this skill", "<local-command", "Caveat:", "[Request interrupted",
)
# 짧은 응답(「응」·「진행」·「좋아」)은 요구가 아니다. 이 길이(정규화 뒤 글자 수) 미만은 세지 않는다.
SHORT = 8
# 추적표 인용 칸이 이 길이 미만이면 **너무 흔해서** 아무 발화나 덮는다 — 인용으로 인정하지 않는다.
MIN_QUOTE = 6

_PUNCT = re.compile(r"[\s\"'`“”‘’「」『』()（）\[\]{}<>.,;:!?~·…\-_/\\|*#=+^%$@&]+")


def norm(s):
    return _PUNCT.sub("", s or "").lower()


def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for x in content:
            if not isinstance(x, dict):
                continue
            if x.get("type") == "tool_result":
                return None  # 도구 결과를 실은 user 줄 — 사람 발화가 아니다
            if x.get("type") == "text":
                parts.append(x.get("text") or "")
        return "\n".join(parts)
    return None


def _origin_kind(o):
    if isinstance(o, dict):
        return o.get("kind")
    if isinstance(o, str):
        m = re.search(r"kind'?\"?\s*:\s*'?\"?(\w+)", o)
        return m.group(1) if m else None
    return None


def humans(transcript, since=None):
    """사람이 쓴 발화 [(ts, text)] — 시간순 · 중복 제거."""
    out, seen = [], set()
    with open(transcript, encoding="utf-8") as f:
        for line in f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            ts = d.get("timestamp") or ""
            text, key = None, None
            tur = d.get("toolUseResult")
            if d.get("type") == "user" and isinstance(tur, dict) and isinstance(tur.get("answers"), dict):
                # ⭐ 질문 도구에 **직접 입력한 답**도 사람 발화다(2026-10-05 실측 — 「A와 B를 같이 하고 싶네…」가
                #   도구 결과로만 기록돼 요구에서 빠질 뻔했다). 선택지 이름을 그대로 고른 답은 결정이지
                #   새 요구가 아니므로 빼고, 선택지에 없는 글만 센다.
                labels = set()
                for q in tur.get("questions") or []:
                    for o in (q.get("options") or []) if isinstance(q, dict) else []:
                        if isinstance(o, dict) and o.get("label"):
                            labels.add(o["label"].strip())
                for qi, (qtext, ans) in enumerate(tur["answers"].items()):
                    if isinstance(ans, str) and ans.strip() and ans.strip() not in labels:
                        k = (d.get("uuid"), qi)
                        if k not in seen and (not since or ts >= since):
                            seen.add(k)
                            out.append((ts, ans))
                continue
            if d.get("type") == "user" and "toolUseResult" not in d and d.get("isMeta") is not True:
                text = _text_of((d.get("message") or {}).get("content"))
                key = d.get("uuid")
                if text is not None:
                    m = re.search(r"<command-name>(.*?)</command-name>", text, re.S)
                    if m:  # 슬래시 명령 — 인자만 요구로 본다(명령 이름은 승인·호출이다)
                        a = re.search(r"<command-args>(.*?)</command-args>", text, re.S)
                        text = (a.group(1) if a else "").strip()
            elif d.get("type") == "attachment":
                a = d.get("attachment") or {}
                if (a.get("type") == "queued_command" and _origin_kind(a.get("origin")) == "human"
                        and (a.get("commandMode") or "prompt") == "prompt"):
                    # ⚠ 이미지를 붙인 메시지는 prompt 가 문자열이 아니라 블록 목록이다(2026-10-05 실측)
                    text = _text_of(a.get("prompt")) or ""
                    key = a.get("source_uuid") or d.get("uuid")
                    ts = a.get("timestamp") or ts
            if not text:
                continue
            t = text.lstrip()
            if t.startswith(_INJECTED):
                continue
            if since and ts and ts < since:
                continue
            k = key or (ts, norm(text)[:60])
            if k in seen:
                continue
            seen.add(k)
            out.append((ts, text))
    out.sort(key=lambda x: x[0])
    return out


def section(md, title_re):
    """`## <제목>` 절 본문(다음 `## ` 까지). 없으면 None."""
    lines = md.splitlines()
    for i, ln in enumerate(lines):
        if re.match(r"^##\s*" + title_re, ln):
            body = []
            for ln2 in lines[i + 1:]:
                if re.match(r"^##\s", ln2):
                    break
                body.append(ln2)
            return "\n".join(body)
    return None


def table_rows(body):
    rows = []
    for ln in body.splitlines():
        s = ln.strip()
        if not s.startswith("|") or re.match(r"^\|\s*:?-{2,}", s):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        rows.append(cells)
    return rows[1:] if rows else rows  # 첫 줄은 머리


_ID = re.compile(r"\b([A-Z][A-Za-z]?\d+(?:-\d+[a-z]?)?|Q-[A-Za-z0-9]+)\b")
_NO_ITEM = ("범위 밖", "질문", "답변", "닫힌 결정", "확인만", "정보", "이미 끝남", "반영됨")


def check_reqtrace(draft_md, transcript):
    body = section(draft_md, r"요구 추적")
    if body is None:
        return 1, ["⛔ `## 요구 추적` 절이 없다 — 사용자 발화마다 「인용 | 분류 | 대응 항목」 한 줄씩(plan.md §6-d)"]
    m = re.search(r"추적 시작\s*[:：]\s*(\S+)", body)
    if not m:
        return 1, ["⛔ `## 요구 추적` 에 `추적 시작: <ISO 시각>` 줄이 없다 — 어디서부터의 발화를 대조할지 정해야 잴 수 있다"]
    since = m.group(1)
    if not transcript or not os.path.isfile(transcript):
        return 2, [f"⚠ 대화 기록을 읽을 수 없다({transcript or '경로 없음'}) — 요구 추적을 **재지 못했다**(통과가 아니다)"]
    msgs = humans(transcript, since)
    rows = table_rows(body)
    quotes = []
    bad_rows = []
    item_ids = set(re.findall(r"^\s*[-*+]\s+\[.\]\s+(\S+)", draft_md, re.M))
    for cells in rows:
        q = norm(cells[0] if cells else "")
        if len(q) >= MIN_QUOTE:
            quotes.append(q)
        resp = cells[-1] if cells else ""
        ids = [x for x in _ID.findall(resp)]
        known = [x for x in ids if any(t.startswith(x) or t.rstrip(".:") == x for t in item_ids)]
        if not ids and not any(w in resp for w in _NO_ITEM):
            bad_rows.append(f"대응 칸이 비었거나 항목이 아니다: {(cells[0] if cells else '')[:40]}")
        elif ids and not known and not any(w in resp for w in _NO_ITEM):
            bad_rows.append(f"대응 항목 {','.join(ids)} 가 초안의 체크박스에 없다: {(cells[0] if cells else '')[:40]}")
    uncovered, short = [], 0
    for ts, text in msgs:
        n = norm(text)
        if len(n) < SHORT:
            short += 1
            continue
        if not any(q in n for q in quotes):
            uncovered.append((ts, text))
    out = [f"요구 추적: 추적 시작 {since} · 사람 발화 {len(msgs)}건(짧은 응답 {short}건 제외) · 표 {len(rows)}행 · 덮이지 않은 발화 {len(uncovered)}건"]
    for ts, text in uncovered[:20]:
        one = " ".join(text.split())[:90]
        out.append(f"   · {ts[:19]} 「{one}」")
    if len(uncovered) > 20:
        out.append(f"   · … 외 {len(uncovered) - 20}건")
    for b in bad_rows[:10]:
        out.append(f"   ⚠ {b}")
    if not msgs:
        return 2, out + ["⚠ 추적 시작 이후 사람 발화가 0건 — 시각이 틀렸거나 기록 형식이 바뀌었다(탐지기부터 의심하라)"]
    return (0 if not uncovered and not bad_rows else 1), out


def _plan_dirs(base, exclude_dir):
    out = []
    for d in sorted(glob.glob(os.path.join(base, "plans", "*"))):
        if not os.path.isdir(d) or os.path.abspath(d) == os.path.abspath(exclude_dir or ""):
            continue
        if any(os.path.isfile(os.path.join(d, n)) for n in ("plan.md", "draft.md")):
            out.append(d)
    return out


_CLOSE_WORDS = ("현행 유지", "빼", "제외", "하지 않", "안 한다", "범위 밖", "보류", "철회", "기각")


def past_decisions(base, exclude_dir):
    """다른 계획들의 닫힌 결정·범위 밖 줄 {slug: [줄]}"""
    res = {}
    for d in _plan_dirs(base, exclude_dir):
        f = os.path.join(d, "plan.md") if os.path.isfile(os.path.join(d, "plan.md")) else os.path.join(d, "draft.md")
        try:
            md = open(f, encoding="utf-8").read()
        except Exception:
            continue
        lines = []
        dec = section(md, r"결정 필요") or ""
        for ln in dec.splitlines():
            if re.match(r"^\s*[-*+]\s+\[[xX]\]", ln) or re.search(r"\|\s*(닫힘|✅)", ln):
                lines.append(ln.strip())
        for ln in md.splitlines():
            if ln.startswith("범위 밖") or (any(w in ln for w in _CLOSE_WORDS) and re.match(r"^\s*[-*+]\s", ln)):
                if ln.strip() not in lines:
                    lines.append(ln.strip())
        res[os.path.basename(d)] = lines
    return res


def check_decisions(draft_md, base, draft_path, show=False):
    own = os.path.dirname(os.path.abspath(draft_path)) if draft_path else ""
    pd = past_decisions(base, own)
    body = section(draft_md, r"이전 결정 대조")
    out = [f"이전 결정 대조: 같은 저장소의 다른 계획 {len(pd)}개"]
    if show:
        for slug, lines in pd.items():
            out.append(f"── {slug} ({len(lines)}줄)")
            out += [f"   {ln[:160]}" for ln in lines[:40]]
    if not pd:
        return 0, out + ["✅ 대조할 다른 계획이 없다"]
    if body is None:
        return 1, out + ["⛔ `## 이전 결정 대조` 절이 없다 — 다른 계획의 닫힌 결정·범위 밖과 이 초안이 부딪히는지 적어라(plan.md §6-e · 목록은 `_plancheck.py decisions --show`)"]
    missing = [s for s in pd if s not in body]
    if missing:
        return 1, out + ["⛔ 이 계획들을 대조했다는 기록이 없다: " + ", ".join(missing)]
    return 0, out + ["✅ 다른 계획을 전부 대조했다고 적혀 있다(내용의 옳고 그름은 리뷰·사람이 본다)"]


def check_vstage(draft_md):
    body = section(draft_md, r"V\b")
    if body is None:
        return 1, ["⛔ `## V — 최종 검증` 절이 없다 — 리뷰 반영 뒤 「원래 계획대로 됐나」를 누가 재는지가 계획에 없다(plan.md §6-f)"]
    boxes = [ln for ln in body.splitlines() if re.match(r"^\s*[-*+]\s+\[.\]", ln)]
    need = {"독립 검증": any("독립" in b for b in boxes), "수용 기준 충족표": any("수용 기준" in b for b in boxes)}
    miss = [k for k, v in need.items() if not v]
    if miss:
        return 1, [f"⛔ `## V` 절에 빠진 항목: {', '.join(miss)} (체크박스 {len(boxes)}개)"]
    return 0, [f"✅ `## V` 절: 체크박스 {len(boxes)}개 · 독립 검증 · 수용 기준 충족표 있음"]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["humans", "reqtrace", "decisions", "vstage", "all"])
    ap.add_argument("--draft")
    ap.add_argument("--transcript")
    ap.add_argument("--base")
    ap.add_argument("--since")
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "humans":
        if not a.transcript or not os.path.isfile(a.transcript):
            print("⚠ 대화 기록 없음"); return 2
        for ts, t in humans(a.transcript, a.since):
            print(f"{ts[:19]}\t{' '.join(t.split())[:160]}")
        return 0
    if not a.draft or not os.path.isfile(a.draft):
        print(f"⚠ 초안을 읽을 수 없다({a.draft}) — 재지 못했다"); return 2
    md = open(a.draft, encoding="utf-8").read()
    base = a.base or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(a.draft))))
    results = []
    if a.cmd in ("reqtrace", "all"):
        results.append(check_reqtrace(md, a.transcript))
    if a.cmd in ("decisions", "all"):
        results.append(check_decisions(md, base, a.draft, a.show))
    if a.cmd in ("vstage", "all"):
        results.append(check_vstage(md))
    rc = 0
    for r, lines in results:
        print("\n".join(lines))
        rc = max(rc, r) if not (rc == 1 and r == 2) else rc
    # rc 우선순위: 위반(1) > 잴 수 없음(2) > 통과(0) — 위반이 하나라도 있으면 그것을 먼저 말한다
    if any(r == 1 for r, _ in results):
        rc = 1
    elif any(r == 2 for r, _ in results):
        rc = 2
    return rc


if __name__ == "__main__":
    sys.exit(main())
