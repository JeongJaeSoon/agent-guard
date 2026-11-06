# unknown lifecycle event 검증 범위

일곱 실제 공개 payload의 Claude `hooks/hooks.json`과 Codex `hooks.json`을 모두
다시 읽었다. 14개 manifest의 SHA-256, 등록 이벤트 및 명시적 CLI 명령 목록은
`unknown-event-inspection.json`에 보존했다.

배포본은 등록된 이벤트마다 `hook-pre-tool`, `hook-post-tool`, `hook-stop`,
`hook-session-start`, `hook-user-prompt` 등 명시적 명령을 연결한다. 일부 셸
wrapper는 plugin binary를 찾는 resolver이지만, 입력에서 lifecycle event를
읽어 route를 선택하는 범용 event router가 아니다. 존재하지 않는
`FutureLifecycleEvent` CLI route를 추가하거나, 기존 PreToolUse 명령에 이름만
바꾼 payload를 주고 실제 새 이벤트 처리 증명이라고 하지 않았다.

따라서 실제 host의 unknown lifecycle event dispatch는 모든 버전에서 **N/A:
검증하지 않음**이다. 로컬에는 Claude 명령이 없고 `/opt/codex/bin/codex` CLI는
있지만, 이 실험에서 Claude/Codex 앱의 plugin 등록·모델 tool dispatch 세션을
구성하거나 실제 새 lifecycle event를 발생시킨 것은 아니다. Codex CLI가
있다는 사실을 해당 host event가 검증됐다는 뜻으로 사용하지 않는다.

기존 고정 corpus의 이름 `unknown-event`와 성능 원시 자료는 바꾸지 않는다.
그 사례는 `tool_name: future_tool`을 `hook-pre-tool`에 주는 **unknown tool
입력의 pass-through**이며, 위 실제 lifecycle event 시험과 구분해 설명한다.
