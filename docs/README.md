# docs

| 파일 | 무엇 |
|---|---|
| `go-review-workflow.pdf` | 공유용 2장 요약 — 전체 흐름·집행 지점(1장) · 리뷰 루프 내부(2장) |
| `go-review-workflow.html` | 그 PDF 의 **원본**. 고쳐서 다시 뽑는다(아래) |

PDF 만 두면 낡았을 때 고칠 수단이 없다. 원본을 같이 둔다.

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --no-pdf-header-footer \
  --print-to-pdf=docs/go-review-workflow.pdf \
  "file://$PWD/docs/go-review-workflow.html"
```

⚠ 2장에 딱 맞춰 놓았다 — 내용을 늘리면 3장이 된다. 확인은 페이지 수를 세어라
(`pdftoppm -png -r 78 docs/go-review-workflow.pdf /tmp/pg` 로 눈으로도 봐라).
⚠ 문서의 수치는 실측이지만 표본이 얇다(라운드 1 · N=1). 라운드가 쌓이면 `review/measure.sh`
로 다시 재고 이 문서를 고쳐라 — 숫자를 그대로 인용하지 마라.
