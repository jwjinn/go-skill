# 스테이지 좌표 — fan-out 통신 게이트 개편 직전 (2026-09-16)

사용자 지시: 「지금 go 스킬을 현 상태를 staging 해줘. 수틀리면 돌아가게」

| 키 | 값 | 비고 |
|---|---|---|
| `TAG` | `stage/before-fanout-comm-2026-09-16` | HEAD `8ba6f18` 에 annotated · **원격 push 완료** |
| `GO_SKILL_HEAD` | `8ba6f18` | `feat(go-fanout): 플러그인으로 포장한다` |
| 미커밋(남의 작업) | `plugins/go-tester/tester/controlgroup.sh`(수정) · `plugins/go-tester/tester/pageheader_mutate.py`(추적 안 됨) | 태그에 **들어 있지 않다.** 아래 두 파일이 사본이다 |
| 패치 | `docs/stage/2026-09-16-uncommitted-go-tester.patch` | `git apply` 로 복원 |
| 사본 | `docs/stage/2026-09-16-untracked-pageheader_mutate.py` | 원 자리로 `cp` |
| 심링크 | `~/.claude/skills/{go-review,go-tester,go-fanout}` → 이 레포의 `plugins/<이름>` | 이번 작업은 심링크를 건드리지 않는다 |
| fabrix 쪽 | `추가기능개선` 워크트리 `999605ac`(go-fanout 수동 훅 등록 제거) | 이번 작업은 fabrix 를 건드리지 않는다. 되돌릴 일이 있으면 그 커밋을 revert |

## 되돌리는 법

```bash
# 코드 — revert 로 (⛔ reset 아님 · 이 레포군은 히스토리를 지우지 않는다)
git -C ~/개발/go-skill log --oneline stage/before-fanout-comm-2026-09-16..HEAD   # 무엇이 그 뒤에 들어갔나
git -C ~/개발/go-skill revert --no-edit stage/before-fanout-comm-2026-09-16..HEAD

# 미커밋 둘 — 그때도 미커밋이었으므로 미커밋으로 되돌린다
git -C ~/개발/go-skill apply docs/stage/2026-09-16-uncommitted-go-tester.patch
cp docs/stage/2026-09-16-untracked-pageheader_mutate.py plugins/go-tester/tester/pageheader_mutate.py
```

심링크는 그대로이므로 revert 만 하면 다음 세션부터 이전 동작이다(훅 스크립트는 호출 때 읽힌다 ·
`hooks.json` 등록만 세션 시작에 읽힌다).

## 변경 이력

- 2026-09-16 생성. 이 자리에서 시작하는 작업: 「fan-out 통신·배치·정리를 구조로 막는다」 —
  계획은 이 디렉토리의 `plan-fanout-comm-2026-09-16.md` 다. 전용 워크트리를 만들었다가
  사용자 지시(「지금 세션에서 하자」)로 되돌렸다 — 플레인 워크트리·브랜치 삭제 완료.
- 2026-09-16 오후 · 계획 정본이 이 디렉토리를 떠났다. P-U(계획 파일 고유화)로 계획마다 디렉토리가
  생겼으므로, 이 작업의 계획은 이제 fabrix 워크트리의
  `.claude/plans/20260916-fanout-comm/plan.md` 하나다(여기 있던 사본은 지웠다 — 정본이 둘이면 어긋난다).
- 2026-09-16 오후 · P0-4 가 태그 **뒤** main 에 들어갔다(`5b29ada` · 채택 흔적에서 Bash 재지향 제거).
  되돌릴 때 `revert stage/before-fanout-comm-2026-09-16..HEAD` 가 그것도 포함한다.
