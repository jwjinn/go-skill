#!/usr/bin/env python3
"""PageHeader.tsx 변이 스크립트 — pageGuide 조회가 한 렌더에 두 번 일어나게 만든다.

목적: PageGuideParagraph 이 자기 안에서 pageGuide(page) 를 호출하도록 바꾸고,
PageHeader 가 guide 를 넘기지 않도록 해서, 안내가 있는 화면에서 조회가 두 번 일어나게 한다.

변이 전:
  export function PageGuideParagraph({ page, guide }: { page: Page; guide: PageGuide }) {
    return (<p>...</p>);
  }
  ...
  {guide && <PageGuideParagraph page={page} guide={guide} />}

변이 후:
  export function PageGuideParagraph({ page }: { page: Page }) {
    const guide = pageGuide(page);
    return (<p>...</p>);
  }
  ...
  {guide && <PageGuideParagraph page={page} />}
"""

import sys
import re


def mutate(content: str) -> str:
    # 1. PageGuideParagraph 시그니처를 { page }: { page: Page } 로 바꾸고
    #    함수 본문에 const guide = pageGuide(page); 를 추가한다.
    #    { page, guide }: { page: Page; guide: PageGuide } 를 { page }: { page: Page } 로 바꾸고
    #    PageGuideParagraph 함수의 return 위에만 const guide = pageGuide(page); 를 추가한다.
    content = content.replace(
        '{ page, guide }: { page: Page; guide: PageGuide }',
        '{ page }: { page: Page }'
    )
    # PageGuideParagraph 함수의 return 위에만 const guide = pageGuide(page); 를 추가
    # PageGuideParagraph 함수는 export function PageGuideParagraph로 시작하고,
    # PageHeader는 export default function PageHeader로 시작한다.
    lines = content.split('\n')
    in_pageguide_paragraph = False
    modified_lines = []
    for i, line in enumerate(lines):
        if 'export function PageGuideParagraph' in line:
            in_pageguide_paragraph = True
        elif 'export default function PageHeader' in line:
            in_pageguide_paragraph = False

        # PageGuideParagraph 함수 안에서 return 위에만 추가
        if in_pageguide_paragraph and line.strip() == 'return (':
            modified_lines.append('  const guide = pageGuide(page);')

        modified_lines.append(line)
    content = '\n'.join(modified_lines)

    # 2. PageGuideParagraph 호출에서 guide={guide} 를 제거한다.
    content = content.replace(
        '<PageGuideParagraph page={page} guide={guide} />',
        '<PageGuideParagraph page={page} />'
    )

    return content


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: pageheader_mutate.py <file>", file=sys.stderr)
        return 64

    filepath = sys.argv[1]

    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    mutated = mutate(content)

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(mutated)

    return 0


if __name__ == "__main__":
    sys.exit(main())