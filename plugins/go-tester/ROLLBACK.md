# 롤백 좌표 — 테스트 에이전트 도입 직전의 상태 (2026-09-15)

사용자 지시: 「성능이 잘 안되면, 롤백할 수 있게 지금 상태도 기억을 하면 좋겠네」

`rollback.sh` 가 이 파일을 **읽어서** 복원한다. 값을 손으로 고치지 마라 — 고치면 롤백이
엉뚱한 자리로 되돌린다. 좌표가 바뀌었으면 그 사실과 날짜를 아래 「변경 이력」에 적어라.

## 좌표

| 키 | 값 | 비고 |
|---|---|---|
| `SYMLINK_PATH` | `~/.claude/skills/go-review` | 전역 스킬 자동 로드 지점 |
| `SYMLINK_TARGET_BEFORE` | `/Users/woojin/개발/go-review/plugins/go-review` | 도입 전 대상 |
| `SYMLINK_TARGET_AFTER` | `/Users/woojin/개발/go-skill/plugins/go-review` | P0-4 이후 대상(정본) |
| `TAG` | `pre-tester-2026-09-15` | 세 레포 공통 |
| `GO_REVIEW_HEAD` | `4de6fd2` | 로컬 `~/개발/go-review` · ⚠ **원격 없음**(실측 2026-09-15) |
| `GO_SKILL_HEAD` | `8cb0066` | `~/개발/go-skill` · 원격 `jwjinn/go-skill` · 태그 push 완료 |
| `FABRIX_HEAD` | `f9d262ae` | 워크트리 `go-스킬-로컬-모델-호출` · 로컬 태그만 |
| `NEW_PATHS` | `~/.config/go-skill/` · `<프로젝트>/.claude/tester/` | 도입 전 **둘 다 없었다** ⇒ 삭제가 곧 원상 |
| `FABRIX_CLAUDE_MD_GOREVIEW_MENTIONS` | 9 | P0-4 가 go-skill 로 갱신한다 |

⚠ `GO_REVIEW_HEAD` 의 원격이 없다는 것이 이 표에서 가장 중요한 줄이다. 도입 전에 심링크는
**원격이 사라진 로컬 사본**을 가리키고 있었고, 그래서 그 상태로 되돌리는 것은 「안전한 과거」가
아니라 「고아 사본으로 되돌아가는 것」이다. 3층 롤백(코드)을 쓸 때 이 점을 알고 써라.

## 되돌리는 세 층

1. **즉시(설정)** — `<프로젝트>/.claude/tester/opt-in.json` 삭제(이 계획만) 또는
   `.claude/tester/config.json` 의 `enabled: off`(프로젝트 전체 · 묻지도 않는다). 코드 변경 0.
   ⚠ 기본값이 「안 씀」이라 아무 조치가 없어도 다음 계획부터는 다시 묻는다.
2. **체인(심링크)** — `bash scripts/rollback.sh --apply`:
   심링크를 `SYMLINK_TARGET_BEFORE` 로 복원 · 프록시 stop · 세마포어·임시 워크트리 회수 ·
   프로젝트 config `enabled: off`. go-skill 에 들어간 코드는 남지만 아무도 부르지 않는다.
3. **코드(태그)** — 세 레포를 `TAG` 기준으로 `git revert`(⛔ `reset` 이 아니다 — 이 레포군의
   squash 재사용 금지와 같은 이유로 히스토리를 지우지 않는다) ·
   `~/개발/go-review-archived-2026-09-15` 를 `~/개발/go-review` 로 rename 복원.

## 롤백 판정 기준

원장 `tester.jsonl` 에서 계산한다. 기준값은 **첫 실사용(P3-3·P3-4) 뒤에 적는다** —
그 전에는 「미측정」이고, 미측정을 「양호」로 읽지 마라.

| 축 | 계산 | 기준값 |
|---|---|---|
| 폴백률 | rc 70 / 전체 호출 | 미측정 |
| 산출 거부율 | (rc 65 + 66 + 67) / 전체 호출 | 미측정 |
| 대조군 미발화 | `went_red == false` 건수 | 미측정 |
| 사람이 지운 테스트 | 리뷰에서 기각된 `tests_written` 수 | 미측정 |
| p95 초 | 호출 소요의 95분위 | 미측정 |

어느 하나가 첫 실사용 값의 2배를 넘으면 1층부터 밟는다.

## 변경 이력

- 2026-09-15 신설(P0-0). `jwjinn/go-review` 원격 부재를 같은 날 실측해 반영.
