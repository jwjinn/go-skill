# go-fanout

`go-review` 체인을 **여러 워커에 fan-out** 한다. 파일 집합이 겹치지 않는 작업 N개를 각자의
워크트리에 띄우고, 각 워커가 자기 세션 안에서 계획 승인 → 구현 → 교차 리뷰 1회 → 반영 → PR
까지 완주하게 한 뒤, 코디네이터가 결과를 거두어 **합본 리뷰 하나**를 돌린다.

사람은 앞(협의문)과 뒤(최종 보고)에만 있다.

> 절차의 정본은 [skills/fanout/SKILL.md](skills/fanout/SKILL.md) 다. 이 파일은 설치와 구성만 말한다.

## 설치

```
/plugin marketplace add jwjinn/go-skill
/plugin install go-fanout@jwjinn-go-skill
```

⛔ **Orca 런타임이 필요하다.** 워커를 Orca 오케스트레이션으로 띄우므로 `orca` 명령이 없으면
이 플러그인은 아무것도 하지 못한다.

```bash
orca status --json        # ready 인가
```

⚠ 훅은 `orca` 가 없으면 **조용히 통과한다.** orca 를 안 쓰는 세션을 멈춰 세우지 않기 위해서다.
그 대가로 「안 깔렸다」와 「깔렸는데 할 일이 없다」가 같은 침묵으로 보인다 — 위 한 줄이 그것을 가른다.

⚠ `go-review` 와 **같은 방식으로** 설치해라(둘 다 마켓플레이스이거나 둘 다 심링크).
셋은 서로를 형제 자리에서 찾는다. 하나만 다른 자리에 있으면 그 하나가 형제를 못 찾는다.

## 무엇이 붙나

| 이벤트 | 훅 | 하는 일 | 막나 |
|---|---|---|---|
| 턴 종료 | `hooks/worker-question-gate.sh` | 워커가 답을 기다리는 `question` 이 남았으면 거부한다 | **예** |
| 턴 종료 | `hooks/wave-close-gate.sh` | 파도가 끝났는데 자원을 회수하지 않았으면 거부한다 | **예** |

`hooks/hooks.json` 이 등록한다. **프로젝트 `settings.json` 에 손으로 넣지 마라** — 2026-09-16
포장 전에는 「복사해 설치한다」였고, 실제로 사본이 생겨 정본이 갈릴 자리가 됐다. 사본은 워커
워크트리로 그대로 퍼진다.

두 게이트가 공유하는 원칙:

- **이 세션이 관여한 run 만 본다.** 판별은 transcript 의 도구 호출 입력과 도구 결과다.
  모델이 산문에 인용한 run 번호는 세지 않는다 — 한 번 막힌 세션이 그것을 답변에 적으면
  자기 출력이 자기 근거가 된다.
- **워커 세션에서는 아예 돌지 않는다.** 터미널 핸들로 가른다. 워커는 코디네이터 문맥이 없어
  남의 질문을 풀 수단이 없다.
- **코디네이터가 닫을 수 없는 자원은 미회수로 세지 않는다.** `worker-release` 가 구조적으로
  못 닫는 셋이다 — `external_terminal` · `user_takeover` · `identity_unproven`.
- 훅 고장·판정 불가는 통과한다. 세션당 상한이 있다.

## 스크립트

```bash
bash scripts/wave-close.sh --run <run_id> --base <ref> [--marker <날짜>]   # 재기만 한다
bash scripts/wave-close.sh … --apply                                      # 통과하면 회수까지
bash scripts/cleanup.sh --run <run_id>                                    # 후보 표(기본 dry-run)
python3 scripts/_crossing.py <base ref> <워크트리…>                        # 파일 집합 교차
```

되돌릴 수 없는 일(회수·삭제)은 `--apply` 를 줘야 일어난다. 재는 것은 전부 자동이고, PR 머지와
배포는 사람 몫이다. 그 경계를 옮기지 마라.

## 대조군

```bash
bash hooks/wave-close-gate.test.sh        # 31검사
bash hooks/worker-question-gate.test.sh   # 20검사
bash scripts/cleanup.test.sh              # 27검사
```

각 스위트에 사보타주가 들어 있다. 회수 판정을 지우면 다 치운 파도도 막히고, 세션 스코프를
지우면 남의 파도로 막힌다 — 보호를 깨서 실제로 붉어지는 것을 본 뒤에야 그 검사가 근거가 된다.
