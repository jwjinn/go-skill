#!/usr/bin/env bash
# go-precheck.sh — UserPromptSubmit 훅. `/go` 를 계획 없이 쓰는 것을 잡는다.
#
# 왜 필요한가:
#   `/go` 는 "방금 제시한 계획을 승인한다" 로 시작한다 — **계획이 있다는 전제**다.
#   그 전제가 깨진 채로 돌면 모델이 승인받지 않은 계획을 **지어내서** 착수한다.
#   그러면 목표 계약이 기억에서 재구성되는데, 재구성된 목표는 이미 드리프트한 목표다.
#   리뷰 단계의 `scope_verdict` 도 대조할 원본이 없어 성립하지 않는다.
#
# ⚠ **차단하지 않는다.** UserPromptSubmit 의 exit 2 는 프롬프트를 **지운다** — 사용자가 친 글이
#   사라지는 것은 오탐 비용이 너무 크다(규칙: 거부는 확실한 것에만).
#   대신 문맥에 사실을 넣어 `/go` 본문의 지시(초안이 없으면 멈춰라)가 확실히 발동하게 한다.
#
# ⚠⚠ **탐지 실패는 침묵이다.** 슬래시 명령이 프롬프트에 어떤 모양으로 실리는지는 하네스 빌드에
#   따라 다를 수 있다(실측: 내장 명령은 `<command-name>/x</command-name>` 로 래핑된다).
#   못 알아보면 아무 말도 하지 않는다 — 이 훅은 **보조 그물**이고, 본체는 `/go` 안의 지시다.
#   (그래서 오탐이 0 이다: 못 보면 조용하고, 보면 사실만 말한다)
#
# stdin : UserPromptSubmit JSON(prompt·session_id…)
# stdout: 평문 → Claude 의 문맥에 주입된다
# 항상 exit 0.
set -u

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

prompt=$(printf '%s' "$input" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get("prompt") or d.get("user_prompt") or "")
' 2>/dev/null) || exit 0
[ -n "$prompt" ] || exit 0

# `/go` 호출인가 — 원문(`/go …`)과 래핑(`<command-name>/go</command-name>`) 둘 다 본다.
# ⚠ `/goal` 같은 다른 명령에 걸리지 않게 경계를 명시한다.
# ⚠⚠ 플러그인으로 로드되면 이름이 `/go-review:go` 다(래핑은 `<command-name>/go-review:go</command-name>`).
#   2026-09-16 실측: 그 표기를 안 봐서 이 훅이 실사용에서 **한 번도 발화하지 않았다** —
#   결정 선행(G9)·병렬 배치·Q-T 안내가 전부 조용히 빠졌다(대조군은 옛 표기 `/go` 만 잠갔다).
case "$prompt" in
  /go|/go\ *|"/go"$'\n'*) ;;
  /go-review:go|/go-review:go\ *|"/go-review:go"$'\n'*) ;;
  *"<command-name>/go</command-name>"*) ;;
  *"<command-name>/go-review:go</command-name>"*) ;;
  *) exit 0 ;;
esac

# ⭐ 경로·소유자 파싱은 **공용 함수**를 쓴다(`_planpath.sh`). 세 훅이 각자 하면 갈라지고,
#   실제로 갈라져서 owner 파싱 한쪽만 고친 채로 다른 쪽이 계속 오진했다(정본이 둘).
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/_planpath.sh" 2>/dev/null || exit 0
base=$(plan_base) || exit 0
draft="${CLAUDE_PLAN_DRAFT_FILE:-$base/plan-draft.md}"

# 초안이 있고 **최근**인가. 오래된 초안은 지금 승인하는 계획이 아니다.
max_age=${CLAUDE_PLAN_DRAFT_MAX_AGE_H:-12}
fresh=0
if [ -f "$draft" ]; then
  mt=$(stat -f %m "$draft" 2>/dev/null || stat -c %Y "$draft" 2>/dev/null)
  case "${mt:-x}" in ''|*[!0-9]*) mt='' ;; esac
  if [ -n "$mt" ]; then
    now=$(date +%s 2>/dev/null || printf '0')
    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    if [ "$now" -gt 0 ] && [ "$(( (now - mt) / 3600 ))" -le "$max_age" ]; then fresh=1; fi
  else
    fresh=1   # mtime 을 못 구하면 있는 것으로 본다(모른다고 잔소리하지 않는다)
  fi
fi

if [ "$fresh" -eq 1 ]; then
  boxes=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[.\]' "$draft" 2>/dev/null || printf '0')
  case "$boxes" in ''|*[!0-9]*) boxes=0 ;; esac
  printf '[/go 사전 확인] 계획 초안 있음: %s (체크박스 %s개)\n' "$draft" "$boxes"
  if [ "$boxes" -eq 0 ]; then
    printf '⚠ 그런데 체크박스가 0개다 — 단계를 `- [ ] 항목` 으로 적지 않으면 완주 게이트가 판정하지 못한다.\n'
  fi
  grep -q '^##[[:space:]]*목표 계약' "$draft" 2>/dev/null \
    || printf '⚠ 초안에 「## 목표 계약」 절이 없다 — 원 요청·수용 기준·범위 밖이 없으면 「범위를 벗어났는가」를 판정할 근거가 없다.\n'

  # ── ⭐ 병렬 배치·자원 회수(2026-09-13) ────────────────────────────────────────
  # 사용자 지시: 「요구조건을 받고 무엇을 병렬 에이전트로 하는지를 정하고 … 종료가 되면 자원을
  # 회수하는 것도 포함해서. 플랜에 무엇을 병렬로 할지를 이미 다 정해두는 거야」(plan.md §6-c).
  # 실측: 2026-09-13 에 회수를 맨 끝에만 두었더니 터미널 15개·워크트리 13개가 밤새 살았다.
  # ⚠ 이 훅은 알리기만 한다 — 「단독 — <이유>」 한 줄도 절이 있는 것으로 본다(그것도 판정이다).
  if grep -qE '^##[[:space:]]*병렬 배치' "$draft" 2>/dev/null; then
    workers=$(grep -cE '^\|[[:space:]]*W[0-9]+[[:space:]]*\|' "$draft" 2>/dev/null || printf '0')
    case "$workers" in ''|*[!0-9]*) workers=0 ;; esac
    if [ "$workers" -gt 0 ]; then
      if grep -qE '^##[[:space:]]*C[[:space:]]*[—-][[:space:]]*자원 회수' "$draft" 2>/dev/null; then
        printf '✅ 병렬 배치 절(워커 행 %s개) + 자원 회수 절 있음 — 파도 끝 release 가 계획의 항목이다.\n' "$workers"
      else
        printf '⚠ 병렬 배치 절(워커 행 %s개)은 있는데 「## C — 자원 회수」 절이 없다 — 파도 끝 worker-release·cleanup 이 계획에 없으면 워커가 밤새 산다(2026-09-13 실측 15개). go.md §3-c 의 두 줄을 넣어라.\n' "$workers"
      fi
    else
      printf '✅ 병렬 배치 절 있음(워커 행 0 — 「단독」으로 판정한 것으로 본다).\n'
    fi
  elif [ "$boxes" -ge 4 ]; then
    printf '⚠ 초안에 「## 병렬 배치」 절이 없다(체크박스 %s개) — 병렬로 갈지 단독으로 갈지는 계획 단계의 판정이다. 단독이면 그 절에 「단독 — <이유>」 한 줄을 적어라(plan.md §6-c).\n' "$boxes"
  fi

  # ── ⭐ 결정 선행 게이트(G9 · 2026-09-03) ────────────────────────────────────────
  # 사용자 지시: 「플랜을 보고 질문을 해야 한다 · 사용자가 목업처럼 선택을 해야 한다면, go 를 돌릴 때
  # **먼저 다 정하고** 돌릴 수 있게」. 승인된 계획 안에 「사용자 답을 기다리는 지점」이 남으면 둘 중
  # 하나가 된다 — 거기서 끊기거나, 모델이 대신 정한다(드리프트). 그래서 초안의 「## 결정 필요(승인 전)」
  # 절을 읽어 **열린 항목이 있으면 착수 전에 묻고 닫으라**고 말한다(go.md §0-c 가 절차).
  # ⚠ 차단은 하지 않는다(이 훅의 규약). 사실을 세어 넣고, 본체는 go.md 의 지시다.
  dec=$(plan_decision_block "$draft")
  if [ -n "$dec" ]; then
    d_open=$(plan_decision_count "$dec" open)
    d_done=$(plan_decision_count "$dec" done)
    case "$d_open" in ''|*[!0-9]*) d_open=0 ;; esac
    case "$d_done" in ''|*[!0-9]*) d_done=0 ;; esac
    if [ "$d_open" -gt 0 ]; then
      printf '⛔ **결정 필요(승인 전) 절에 열린 항목 %s건**(닫힘 %s건) — go.md §0-c: **착수하지 마라.**\n' "$d_open" "$d_done"
      plan_decision_lines "$dec" | sed -e 's/^[[:space:]]*//' | cut -c1-110 | sed -e 's/^/   · /' | head -12
      total_open=$(plan_decision_lines "$dec" | grep -c . 2>/dev/null || printf '0')
      case "$total_open" in ''|*[!0-9]*) total_open=0 ;; esac
      [ "$total_open" -gt 12 ] && printf '   … 외 %s건\n' "$((total_open - 12))"
      printf '   질문은 AskUserQuestion 으로 **한 자리에서** 묻고(4문항씩), 선행 산출물(목업 등)은 **만들어 제시해 선택**을 받아라.\n'
      printf '   전부 닫힌 뒤에만 plan-active.md 로 옮긴다 — 승인된 계획 안에 사용자 정지가 남으면 거기서 끊기거나 네가 대신 정하게 된다.\n'
      exit 0
    fi
    if [ "$d_done" -gt 0 ]; then
      printf '✅ 결정 필요(승인 전) 절: 전부 닫힘(%s건) — 계획 안에 사용자 정지가 없다.\n' "$d_done"
    else
      # ⚠⚠ **0 을 「없음」으로 단언하지 않는다.** 열림도 닫힘도 0 이면 「물을 것이 없다」와
      #   「형식이 안 맞아 못 읽었다」가 구분되지 않는다 — 후자를 전자로 읽으면 미결 결정을
      #   안은 채 착수한다(2026-09-03 리뷰가 지목: 「0 이 나오면 탐지기부터 의심하라」).
      printf '⚠ 결정 필요(승인 전) 절은 있는데 **열림·닫힘 어느 것도 세지 못했다**(둘 다 0).\n'
      printf '   「물을 것이 없다」인지 **형식이 안 맞아 못 읽은 것**인지 네가 그 절을 직접 읽고 판단해라.\n'
      printf '   인식하는 표기: `- [ ]`/`- [x]` 체크박스 · 표의 **마지막 열**이 열림/⏳ 또는 닫힘/✅.\n'
    fi
  else
    # 절이 없다 — 「물을 것이 없다」와 「안 적었다」를 가르지 못하므로 후보를 세어 알린다(경고 · 차단 아님)
    cand=$(grep -cE '\[질문\]|\[선택\]|\[선행 산출물\]|사용자[[:space:]]*(결정|선택|확인|답)|AskUserQuestion|고른다|골라|물어|확인 후|\?[[:space:]]*$' "$draft" 2>/dev/null || printf '0')
    case "$cand" in ''|*[!0-9]*) cand=0 ;; esac
    printf '⚠ 초안에 「## 결정 필요(승인 전)」 절이 없다 — 결정 후보로 보이는 줄 **%s건**. go.md §0-c: 초안을 스캔해 사용자 질문·선택·선행 산출물을 그 절로 모아라. 물을 것이 정말 없으면 절을 만들고 「없음」이라 적어라(없다는 것도 판정이다).\n' "$cand"
  fi

  # ── ⭐ 테스트 에이전트 축(2026-09-15) ──────────────────────────────────────
  #
  # 사용자 지시: 「default 는 로컬 모델을 안 쓰는 거고 … 명시적으로 쓴다고 하면 쓴다」
  #              「플랜을 만들고 플랜을 돌릴때 명시적으로 물어보는 프로세스가 있어야겠는데」
  #
  # ⚠ 이 축은 **차단하지 않는다.** 묻지 않고 지나가면 tester.sh 가 rc 70 으로 닫히므로
  #   안전한 쪽으로 실패한다. 알릴 가치가 있는 것은 「물어야 하는데 항목이 없다」와
  #   「남의 계획 옵트인이 남아 있다」 둘이다.
  t_root="$(dirname -- "$base")"
  tt="$HOME/.claude/skills/go-tester"
  [ -d "$tt" ] || tt=""
  if [ -n "$tt" ] && [ -f "$tt/tester/_config.py" ]; then
    t_mode=$(CLAUDE_PROJECT_DIR="$t_root" python3 "$tt/tester/_config.py" 2>/dev/null | grep -E '^TESTER_MODE=' | head -1 | cut -d= -f2- | tr -d "'")
    case "$t_mode" in
      ask)
        if grep -qE '^[-*][[:space:]]*\[[ xX]\][[:space:]]*Q-T|Q-T[[:space:]]*\[질문\]|테스트 에이전트' "$draft" 2>/dev/null; then
          printf '✅ 테스트 에이전트 항목(Q-T)이 초안에 있다 — `/go` 가 §0-d 에서 heartbeat 를 다시 돌리고 재확인한다.\n'
        else
          printf '⚠ go-tester 가 `ask` 인데 초안에 **테스트 에이전트 항목(Q-T)이 없다** — plan.md §6-b 의 Q-T 를 보라.\n'
          printf '   항목이 없으면 `/go` 가 §0-d 에서 처음 묻게 되고, 그 자리가 곧 착수 중 정지다.\n'
          printf '   물을 필요가 없다고 판단했으면 그 사실을 한 줄로 적어라(안 적은 것과 다르다).\n'
        fi
        ;;
      on|off)
        printf '✅ go-tester 는 이 프로젝트에서 `%s` 로 고정돼 있다 — 묻지 않는다(사람이 이미 정했다).\n' "$t_mode"
        ;;
    esac
    # 옵트인 잔재 — 다른 계획의 기록이 남아 있으면 알린다.
    optin="$base/tester/opt-in.json"
    if [ -f "$optin" ]; then
      rec=$(python3 -c 'import io,json,sys
try: print((json.load(io.open(sys.argv[1],encoding="utf-8")).get("plan_file") or ""))
except Exception: print("")' "$optin" 2>/dev/null)
      if [ -n "$rec" ] && [ "$rec" != "$base/plan-active.md" ]; then
        printf '⚠ 옵트인 기록이 **다른 계획**을 가리킨다(%s) — 이 계획에는 안 먹는다(rc 70). 새로 물어 새로 써라.\n' "$rec"
      else
        printf '⚠ 옵트인 기록이 이미 있다(%s) — 앞 계획의 잔재면 지워라. 자원 회수(go.md §3-c C3)가 그 일이다.\n' "$optin"
      fi
    fi
  fi

  printf '이 초안을 **그대로** plan-active.md 로 옮겨라. 여기서 계획을 다시 쓰지 마라 — 승인된 것은 이 초안이다.\n'
  exit 0
fi

# ── 경로 ① — 초안은 없지만 **이 워크트리의 plan-active.md** 가 이미 있으면 채택이다 ──────
# ⚠ 이것이 없으면 「기존 계획을 재사용할 수 없다」가 된다(2026-09-02 다른 세션 자가평가
#   결함 3). 250줄 계획을 손에 들고도 `/go` 가 착수를 거부하고, 사람이 §0-b 를 손으로
#   대신하게 된다 — 스킬이 하는 일 중 유일하게 사람이 대신한 부분이었다.
plan="${CLAUDE_PLAN_FILE:-$base/plan-active.md}"
if [ -f "$plan" ]; then
  left=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\[[^xX]\]' "$plan" 2>/dev/null || printf '0')
  case "$left" in ''|*[!0-9]*) left=0 ;; esac
  if [ "$left" -gt 0 ]; then
    owner=$(plan_owner_of "$plan")
    printf '[/go 사전 확인] ⭐ 초안은 없지만 **기존 계획**이 있다: %s (미완료 %s개)\n' "$plan" "$left"
    if [ -n "$owner" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "$owner" != "$CLAUDE_PROJECT_DIR" ]; then
      printf '⚠⚠ 그런데 머리말의 작업 위치가 다르다 — **다른 세션의 계획일 수 있다.**\n'
      printf '   계획: %s / 지금: %s\n' "$owner" "$CLAUDE_PROJECT_DIR"
      printf '   덮어쓰지도 끼워 넣지도 마라. 사용자에게 그 사실과 선택지를 말해라(go.md §0).\n'
      exit 0
    fi
    printf '→ go.md **§0-b 경로 ①**(채택)로 가라. 본문을 다시 쓰지 마라 — 실측 근거가 사라진다.\n'
    grep -qE '^[[:space:]]*(작업 위치|Work dir)[[:space:]]*:' "$plan" 2>/dev/null \
      || printf '⚠ `작업 위치` 머리말이 없다 — 한 줄 추가해라(없으면 Stop 훅이 남의 계획을 진단하지 못한다).\n'
    grep -q '^##[[:space:]]*목표 계약' "$plan" 2>/dev/null \
      || printf '⚠ 「## 목표 계약」 절이 없다 — 원 요청 인용·수용 기준·범위 밖을 추가해라.\n'
    grep -qE '^##[[:space:]]*R[[:space:]]*—' "$plan" 2>/dev/null \
      || printf '⚠ 「## R — 리뷰」 항목이 없다 — 맨 끝에 두 줄 추가해라(§3). 없으면 리뷰 축이 무장되지 않는다.\n'
    exit 0
  fi
fi

# ⭐ 없다고 말하기 전에 **다른 워크트리**를 훑는다(2026-09-03 실측): 세션 프로젝트와 코드
#   워크트리가 다르면 계획이 「훅이 보는 곳」에 없다. 그때 「계획이 없다」와 「다른 데 있다」를
#   같은 문장으로 말하면 사용자는 「다 닫았구나」로 읽고, 게이트가 꺼진 채 12단계가 돈다.
#   ⚠ 알리기만 한다 — 자동 채택은 하지 않는다(워크트리를 나눈 이유가 있을 수 있다).
others=$(plan_other_worktrees "$base" 2>/dev/null)
if [ -n "$others" ]; then
  printf '[/go 사전 확인] ⚠ 이 프로젝트에는 계획이 없지만 **다른 워크트리에 있다**:\n'
  printf '%s\n' "$others" | while IFS='|' read -r f n; do
    printf '   %s (미완료 %s개)\n' "$f" "$n"
  done
  printf '   ⚠ 자동으로 쓰지 않는다 — 워크트리를 나눈 이유가 있을 수 있다. 사용자에게 확인해라:\n'
  printf '     그 계획을 이어갈 것이면 `CLAUDE_PLAN_FILE=<위 경로>` 로 세션을 띄우거나, 그 워크트리에서 돌려라.\n'
  # ⚠ 여기서 `exit 0` 하지 않는다(2026-09-03 리뷰가 지목) — 그러면 아래 「승인할 계획이 없다」가
  #   통째로 삼켜져 모델이 계획을 지어내고 착수할 수 있다. 둘 다 사실이므로 둘 다 말한다.
fi

cat <<'MSG'
[/go 사전 확인] ⛔ **승인할 계획이 없다**(plan-draft.md 부재/12시간 초과 · plan-active.md 미완료 0개).

`/go` 는 「방금 제시한 계획을 승인한다」로 시작한다 — 승인할 계획이 없으면 그 전제가 깨진다.
이 상태에서 계획을 **지어내서 착수하지 마라.** 지어낸 목표 계약은 이미 드리프트한 목표이고,
리뷰 단계의 범위 판정도 대조할 원본이 없어 성립하지 않는다.

지금 할 일 — 둘 중 하나:
  ① 사용자에게 `/plan <요구사항>` 을 먼저 돌리라고 말하고 **멈춰라**.
  ② 사용자가 **직전 메시지에서** 계획을 직접 서술해 그것을 승인하는 경우라면,
     그 계획을 초안 형식(목표 계약 + 체크박스)으로 `.claude/plan-draft.md` 에 먼저 적어
     사용자가 무엇이 승인됐는지 볼 수 있게 하고, 계획 파일에
     `계획 출처: 대화 중 제시(사용자 서술)` 를 남겨라.
MSG
exit 0
