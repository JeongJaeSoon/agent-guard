## Unreleased

### Deprecated

- CLI가 `AGENT_GUARD_BIN_DIR`를 비공개 gitleaks 디렉터리로 읽는 동작. 이 이름은 설치기(`bootstrap.sh`)와 `agent-guard update`에서 공개 링크 디렉터리(기본 `~/.local/bin`)를 뜻하고, 그 뜻은 그대로입니다. gitleaks 디렉터리는 `AGENT_GUARD_GITLEAKS_BIN_DIR`(기본 `~/.agent-guard/bin`)로 정하세요.
  - 폐기 기간의 동작: `AGENT_GUARD_GITLEAKS_BIN_DIR` 없이 `AGENT_GUARD_BIN_DIR`만 있고 그 안에 gitleaks가 있으면 지금처럼 그 gitleaks를 쓰고, `setup --install`도 그곳에 설치합니다. 이때 SessionStart, `setup`·`doctor`, `scan-staged`·`scan-working-tree`·`scan-path`가 옮기라는 알림을 냅니다. 알림은 설정 이름만 적고 값(경로)은 적지 않습니다. 그 안에 gitleaks가 없으면 이 이름은 gitleaks 디렉터리를 정하지 않으므로 `setup --install`·`--install-gitleaks-helper`가 `~/.agent-guard/bin`에 설치하고, 그렇게 바뀌었다고 알립니다. 두 이름이 모두 있으면 지금처럼 `AGENT_GUARD_GITLEAKS_BIN_DIR`를 씁니다. `bootstrap.sh` 끝의 `setup`은 이 이름을 넘겨받지 않습니다.
  - 없애는 조건: 이 알림이 처음 들어간 릴리스 뒤로 minor 릴리스 2번과 30일이 모두 지난 뒤(둘 중 늦은 쪽). 그 릴리스의 CHANGELOG "Removed"에 적습니다.

[REDACTED]