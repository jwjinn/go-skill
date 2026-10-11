---
name: go
description: 옛 go-review 체인의 /go 자리를 안내한다. 체인은 2026-10-10 에 내렸고, 계획은 plan mode 가, 리뷰는 /code-review 와 /codex:review 가 맡는다. 사용자가 /go 를 직접 입력했을 때만 쓴다.
disable-model-invocation: true
---

사용자가 손에 익은 대로 `/go` 를 입력했다. go-review 체인은 2026-10-10 에 내려갔으므로 아래 안내를 그대로 전하고, 다른 작업은 시작하지 마라.

> `/go` 는 더 이상 없습니다. 계획은 Shift+Tab 으로 plan mode 에 들어가 세우고 승인합니다. 계획에 `- [ ]` 체크박스를 두면 plan-gate 가 완주를 지킵니다. 리뷰는 `/code-review` 를 돌린 다음 `/codex:review --model gpt-6.1-sol --base origin/main` 을 돌립니다.

인자가 있었다면(`$ARGUMENTS`) 안내 뒤에 그 내용을 한 줄로 되돌려 주어, 사용자가 plan mode 에서 그대로 붙여 넣을 수 있게 하라.
