---
description: 테스트를 로컬 모델에 붙은 별도 에이전트에 위임한다 — 작성·실행·대조군 증명까지
---

테스트 작업을 **별도 `claude` 프로세스**에 넘긴다. 그 프로세스는 로컬 모델에 붙어 있고,
네 문맥에는 **결과 JSON 하나만** 돌아온다 — 테스트 파일 본문도 실행 로그도 들어오지 않는다.
그것이 토큰을 아끼는 지점이다.

## 0. 먼저 — 쓸 수 있나

```bash
TT=~/.claude/skills/go-tester      # 심링크. 없으면 ~/.claude/plugins/.../go-tester
python3 "$TT/tester/_config.py"
```

`TESTER_ENABLED=0` 이면 **위임하지 않는다.** 사유를 그대로 사용자에게 말하고 네가 직접 테스트를
쓴다. 사유는 넷 중 하나다:

| 사유 | 뜻 | 네가 할 일 |
|---|---|---|
| `no_endpoint` | 이 프로젝트에 엔드포인트 설정이 없다 | 직접 쓴다. 쓰고 싶으면 `.claude/tester/config.json` 안내 |
| `disabled` | 구성에서 `off` | 직접 쓴다. 되돌리려면 `enabled` 를 `ask` 로 |
| `not_opted_in` | 사용자가 아직 「쓴다」고 답하지 않았다 | 직접 쓴다. `/go` 가 계획 착수 때 묻는다 |
| `opted_out` · `optin_for_other_plan` | 답이 「안 쓴다」이거나 다른 계획의 기록이다 | 직접 쓴다 |

⚠ **기본은 안 쓰는 것이다.** 이것이 기능 결함이 아니라 설계다(사용자 지시 2026-09-15).
「왜 안 되지」를 고치려 하지 말고 사유를 전하라.

## 1. 지시서를 쓴다

지시서 파일 하나가 위임의 전부다. 자식은 **프로젝트 문서를 볼 수 없다**(`--setting-sources ""`
라서 `CLAUDE.md` 가 로드되지 않는다 — 실측). 그러니 프로젝트 관례를 네가 지시서에 담아라:

- 어떤 함수·모듈의 무엇을 잠그고 싶은가
- 게이트 명령 전문(`go test ./... -count=1` · `VITE_MOCK=on npx vitest run` 처럼 플래그까지)
- 이 레포의 테스트 관례(테이블 주도 · 어느 assertion · 어디에 두나)
- 건드리면 안 되는 것

```bash
cat > /tmp/task.txt <<'EOF'
Write tests for ClampQuota in backend/internal/platform/quota/clamp.go.
Cover: below min, above max, inside range, inverted range (max < min).
Follow the table-driven style used by the neighbouring *_test.go files.
EOF
```

## 2. 부른다

```bash
bash "$TT/tester/tester.sh" \
  --task /tmp/task.txt \
  --mode full \
  --gate 'go test ./... -count=1' \
  --cwd "$CLAUDE_PROJECT_DIR" \
  --out /tmp/tester-result.json
```

`--mode` 셋: `run`(실행·판독만) · `write`(작성) · `full`(작성 + 대조군 증명).
**기본은 `full` 이고 그것을 낮추지 마라** — 대조군이 없으면 그 테스트가 무엇을 지키는지 아무도
모른다. 작업이 대조군을 못 만드는 성격이면(예: 기존 테스트 실행만) `run` 을 쓴다.

## 3. 종료코드를 읽는다

| rc | 뜻 | 네가 할 일 |
|---|---|---|
| 0 | 정상 | 결과 JSON 을 읽고 커밋 메시지에 대조군 수를 인용한다 |
| 70 | 쓸 수 없다 | **직접 쓴다.** 사유를 종료 보고 ⑦에 남긴다 |
| 65 | 산출이 무효 | 한 번 더 부르지 말고 직접 쓴다. 보존된 자식 산출 경로가 사유에 있다 |
| 66 | 테스트 파일 밖을 고쳤다 | ⛔ 그 산출을 믿지 마라. 직접 쓰고 이 사실을 보고한다 |
| 67 | 대조군이 0건 | 그 테스트는 근거가 아니다. 직접 대조군을 돌리거나 다시 시킨다 |
| 68 | 부모 계획 파일이 훼손됐다 | ⛔ 통제가 깨진 것이다. 원본은 복원됐다. 사용자에게 **반드시** 말하라 |

⚠ **`| tail` 뒤에서 rc 를 읽지 마라.** 파이프가 종료코드를 삼킨다 — 이 레포군이 양방향으로
밟은 함정이다(`| tail` 은 실패를 통과로, `pipefail`+`grep -q` 는 성공을 실패로 만든다).

## 4. 결과를 어떻게 쓰나

```json
{ "passed": 4, "failed": 0,
  "tests_written": [{"file": "...", "locks": "빈 범위에 max 를 돌려준다"}],
  "control_group": [{"test": "...", "mutation": "비교 뒤집기", "went_red": true}],
  "notes": "..." }
```

- `locks` 가 「동작을 검증한다」처럼 무엇에나 해당하면 그 테스트는 약하다. 다시 시켜라.
- `went_red` 가 `false` 인 항목은 **그 주장이 증명되지 않았다**는 뜻이다. 커밋 메시지에
  「대조군 N건」을 적을 때 그것을 빼고 세라.
- `notes` 가 비어 있으면 「전부 검증했다」는 주장이다. 긴 작업에서 그것은 대개 거짓이다 —
  한 번 의심해 보라.

## 5. 기록

호출마다 원장(`.claude/tester/tester.jsonl`)에 한 줄이 쌓인다. 종료 보고 ④ 「검증」에
그 수를 인용하라: 위임 N회 · 로컬 토큰 X · 폴백 M회(사유) · 대조군 발화 K.
