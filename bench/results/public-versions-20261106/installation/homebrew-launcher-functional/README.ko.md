# 실제 Homebrew launcher의 native/fused 호출 확인

실제 설치된 `/workspace/agb/bin/agent-guard`를 통해 합성 API_KEY가 있는 post-tool 출력을 Claude/Codex 각각 기본/fused 경로로 1회씩 실행했다. 고정 기대값은 API_KEY 값만 `[REDACTED]`로 바뀌고 clean 문자열·숫자42·boolean false를 보존하는 객체다. host별 envelope를 독립 해석한 결과 4회 모두 이 기대값과 정확히 같았다.

공개381 native helper와 실제 Homebrew nested libexec helper는 `cmp`와 SHA256으로 동일함을 확인했다. SHA256은 `ffbe52a07f07ea6f4447f1218627b946288d1d2eab134128b74927c09358c200`이다. 기본 경로는 `AGENT_GUARD_RUST_CORE_BIN`을 지정하지 않았으며 설치된 core의 자동 탐색으로 `redact-v1`을 정확히1회 실행했다. fused는 동일 Brew core의 prepare 경로만 지정하여 `prepare-v1`1회와 기본 자동 탐색 `redact-v1`1회를 실행했다. 모든 native exec와 종료는0이었다.

`strace -f -e trace=process`만 사용했다. open/read/write 전체 trace나 성능 표본은 수집하지 않았다. prefix·lab·소스는 실제 ro bind mount, 결과만 rw였음을 mountinfo로 검증했고 product 파일 전체 hash도 전후 동일했다. HOME/XDG/TMPDIR은 각 호출의 새 state 아래에 격리했다. 공식 scanner 고정, baseline gitleaks/deny-bash 정책, 동일 deny-read bytes, PII/audit/release check off를 사용했다.

초기 trace parser는 Codex default의 execve가 unfinished/resumed 두 줄로 나뉘는 것을 처리하지 못해1건을 도구 실패로 분류했다. 해당 JSON·completion 및 이전 하네스는 그대로 보존했다. 같은 PID의 resumed=0을 해석하도록 parser만 수정했고 다른 PID의 성공으로 실패를 덮을 수 없는 negative fixture도 검증했다. 실제 호출·원시 stdout/stderr/trace는 재실행하거나 수정하지 않았다. 변경 이유는 `instrumentation-change.json`에 있다.

이 결과는 경로 선택의 n=1 기능 증거다. 실제 Homebrew wrapper의 비계측 시작 지연·CPU·메모리 성능은 여전히 N/A이며 기존 Homebrew cached 설치 비용 또는 다른 CLI runtime 표본과 합치지 않는다. 재현 도구는 상위 `check_homebrew_launcher.py`, 원시는 `results.json/CSV`, `process.strace`와 `raw-manifest.json`에 있다.
