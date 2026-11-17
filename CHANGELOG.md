## Unreleased

- perf(hook): 진단 로그를 끈 상태(`AGENT_GUARD_LOG_MODE=off`)의 Bash PreToolUse가 프로세스를 약 350번에서 약 105번만 fork합니다. 이 모드는 보호 경로 검사용 합친 정규식을 호출마다 새로 만드는데(#488), deny 목록 항목 60개 × 모드 2개의 정규식을 각각 명령 치환 두 겹(`$(deny_path_command_regex …)` 안의 `$(deny_path_regex_fragment …)`)으로 만들어서 깨끗한 명령 하나에 서브셸 약 240개가 들었습니다. 프로그램은 하나도 실행하지 않는 fork가 전체의 약 70%였습니다. 같은 경로에서 낱말마다 서브셸 하나(`env_exception_literal_shell_token`), 명령 이름마다 서브셸과 `tr` 파이프(`bash_strip_exclusion_operands`), 미리 읽어 둔 입력 필드마다 서브셸 하나(`json_value`)도 들었습니다.
  - 동작 변경: 판정과 출력은 바뀌지 않습니다. 정규식 생성 함수는 값을 출력 대신 변수로 돌려주고, 합친 파일은 모드마다 서브셸 하나 안에서 씁니다. 파일 내용은 바이트 단위로 같습니다. 영문자·숫자·`._+-`로만 된 명령 이름은 지울 따옴표가 없으므로 `tr`을 건너뛰고, 미리 읽어 둔 필드는 명령 치환과 같은 값(끝 줄바꿈 제거)을 변수로 받습니다. 그 밖의 경우는 지금 경로를 그대로 탑니다. 테스트 fixture와 `tests/run.sh`의 hook 입력 806개를 Claude·Codex × 로그 켬·끔 × infra open·closed 8가지 설정에서 v3.11.6과 비교해 종료 코드·stdout·stderr 차이 0건을 확인했습니다. 이 머신에서 측정한 결과(31쌍 중앙값, CPU user+sys): 로그 끔·스텁 스캐너에서 `printf 'build passed'` fork 365번 → 117번, CPU 700ms → 550ms(-21%), `ls -la src`·`git status`·두 명령 파이프라인은 fork 약 355번 → 105번, CPU -29%. gitleaks 8.30.1에서는 같은 명령들의 CPU가 6~12% 줄었습니다. 로그 켬(캐시가 데워진 상태)은 fork 약 10번, CPU 0~6% 줄었고, Read·Edit·Write·PostToolUse·UserPromptSubmit은 fork 0~3번 차이로 CPU 차이가 측정 잡음 안입니다.

## v3.11.7 - 2026-11-18

- fix(bash): 명령이 파일로 열지 않는 데이터 속 보호 파일 이름 때문에 Bash 명령이 `bash_protected_path_text_match`로 막히던 오탐을 고칩니다. `sed -n '/secrets.json/,+5p' types.d.ts`, `sed -n '1,50p' f | grep -n secrets.json`, `cat > note.md <<EOF` 본문의 `$obj.env`, `echo 'const m = obj.env;' > note.md`가 막혔습니다. 차단 메시지도 걸린 규칙과 대신 쓸 도구를 알려 줍니다. (#494, #496)
  - 동작 변경: (1) sed 스크립트의 줄 번호·`$`·`/re/` 주소와 범위(`+N`·`~N` 포함), `p`·`d`·`=`·`q` 명령을 받아 주소 정규식을 검사에서 뺍니다. `w`·`r`·`e`, `!` 부정, 플래그 붙은 주소, `-i`·`-f`는 지금처럼 막습니다. (2) 플래그가 `-nErsuz`뿐이고 스크립트가 줄 번호 출력(`1,50p`, 한 번의 `-e` 포함)뿐인 `sed`는 뒤 구간의 grep 패턴 예외를 막지 않습니다. sed의 파일 피연산자는 그대로 검사합니다. (3) 따옴표 없는 구분자 heredoc 본문에 `$NAME`·`${NAME}` 단순 참조만 있으면 쓰기 전용 본문으로 인정합니다. 명령 치환·백틱·산술·첨자·그 밖의 `${...}`·백슬래시는 지금처럼 막습니다. (4) 명령 전체가 `echo`나 `printf` 하나와 리다이렉트 하나뿐이면 작은따옴표 인자 글을 데이터로 봅니다. 리다이렉트 대상, 파이프·`;`·치환·glob이 있는 줄, 따옴표 없는 보호 단어는 지금처럼 막습니다. (5) deny 패턴 차단이 `matched deny-bash-patterns line N (<파일>)`로 걸린 줄을 보이고 다른 형태로 재시도하지 말라고 안내하며, 보호 경로 차단은 Read·Edit·Write 도구를 쓰라고 안내합니다. 계속 막는 것: 인터프리터 프로그램(`python3 - <<'EOF'`) 본문의 보호 파일 이름(문자열인지 여는 경로인지 글로 구분할 수 없음), `X=$(… printenv NAME)`. 알려진 잔여: 비밀 이름 환경 변수 값을 파일에 쓰는 명령(#497), `git -C <경로> commit -m` 메시지 예외 누락(#500).
  - 사용자가 할 일: 없습니다.
  - 운영자가 할 일: 없습니다.

## v3.11.6 - 2026-11-17

- fix(bash): 인터프리터 heredoc 본문의 런타임 전역 이름을 `.env*` 파일로 읽던 오탐을 고칩니다. 명령에 `<<`가 있으면 런타임 전역 예외(`process.env.X` 등)를 통째로 건너뛰었기 때문에, `node <<'EOF'`나 `python3 - <<EOF` 본문의 `process.env.ROUTE`가 `*.env.*`에 걸렸습니다. (#487)
  - 동작 변경: `<<`가 있는 명령은 줄 단위로 읽고, 그 줄에 인터프리터 하나만 있는 heredoc(`node <<'EOF'`, `python3 - <<EOF`, `bun run -`, `deno run -`)의 본문에서만 런타임 전역 이름을 경로로 읽지 않습니다. 문자열 리터럴 안의 이름, 이름과 `/`가 같은 줄에 있는 경우, 문자열이 닫히지 않은 줄, 따옴표 없는 구분자 본문의 `$(`·백틱, 다른 형태의 heredoc, 본문 밖의 이름, 같은 이름의 실제 파일이 있는 경우는 지금처럼 막습니다.
  - 사용자가 할 일: 없습니다.
  - 운영자가 할 일: 없습니다.
- fix(bash): 작은따옴표로 감싼 프로그램 단어 안의 정규식 글을 셸 glob으로 읽던 오탐을 고칩니다. `python3 -c`, `node -e`, jq 필터, awk 프로그램 안의 `id[_a-z]*`, `id_*`, `/id_r?a/`가 shell-expanded 검사에서 `id_rsa`로 펼쳐질 수 있는 glob으로 읽혔습니다. (#487)
  - 동작 변경: 프로그램 단어 전체의 `[ ] * ?`를 shell-expanded 검사용 사본에서만 글자로 읽습니다. literal 검사는 원문을 그대로 읽습니다. 조건이 있습니다. python·node는 같은 줄 앞에 파이프가 없어야 하고, awk는 `getline`·`ARGV`·명령 파이프가 없어야 합니다. 어느 프로그램이든 `open`, `File`이 든 이름(`FileIO`, `GzipFile`, `readFileSync` 등), `readdir`, `Glob`을 쓰지 않아야 하고, 출력은 `wc`·`head`·`sort`·`grep` 같은 텍스트 필터로만 가야 합니다. `cat ~/.ssh/id[_r]*`, `jq . ~/.ssh/id[_r]*`, `awk 1 id[_r]*`처럼 프로그램 밖의 glob 피연산자는 그대로 막습니다. 알려진 한계 두 가지가 있습니다. jq 필터에서 `(` 바로 뒤에 필드 접근이 오는 형태(`select(.name | test("id[_a-z]*"))`)는 아직 막힙니다(#491). `polars.read_csv("d/id_[a-z]*")`처럼 패턴 인자를 스스로 펼치는 서드파티 reader는 이 예외로 통과합니다(#492).
  - 사용자가 할 일: 없습니다. #491의 형태가 막히면 `.["name"]`이나 `(.name)`으로 쓰면 됩니다.
  - 운영자가 할 일: 없습니다.
- ci(native): Native redactor contracts 시간 제한을 25분으로 올린다 (#490)

## v3.11.5 - 2026-11-17

- perf(bash): 진단 로그를 끈 상태(`AGENT_GUARD_LOG_MODE=off`)의 Bash PreToolUse가 보호 경로 검사에서 deny 목록 항목마다 grep을 따로 띄우지 않습니다. 합친 정규식 파일은 상태 디렉터리에만 두었기 때문에, 상태 디렉터리가 없는 off 모드에서는 한 번도 쓰이지 않았습니다. 그래서 `printf 'build passed'` 같은 깨끗한 명령 하나에 항목 60개 × 검사 4번 = grep 240번과 정규식 생성용 서브셸 약 1,000개가 들었고, nightly 성능 측정의 `pre-bash-clean`(homebrew, off)이 v3.7.0 기준 5%를 다시 넘었습니다. (#477, #488)
  - 동작 변경: 상태 디렉터리가 없으면 합친 정규식을 그 호출의 비공개 실행 디렉터리(`mktemp -d`로 만든 mode 700 디렉터리, 종료할 때 함께 지움)에 모드마다 한 번 만들고, 같은 호출의 모든 검사가 그 파일을 씁니다. 판정은 바뀌지 않습니다. 합친 파일은 "어느 항목과도 맞지 않음"일 때만 믿습니다. 맞는 줄이 있거나, grep이 실패하거나, 파일이 항목 수만큼 완성되지 않았거나, 실행 디렉터리가 없거나 심볼릭 링크이거나 쓸 수 없으면 지금처럼 항목별 검사가 판정합니다. 상태 디렉터리를 쓰는 로그 켬 모드의 캐시(이름에 든 식별자, 오래된 파일 정리)는 그대로입니다. 이 머신에서 측정한 결과(40쌍 중앙값, CPU user+sys): 깨끗한 Bash PreToolUse 한 번의 grep이 242번에서 10번, fork가 약 1,090번에서 약 380번으로 줄었고, CPU는 v3.7.0보다 gitleaks 8.30.1로 25~27%, 스텁 스캐너로 43~45% 적습니다(변경 전에는 각각 +1~4%, +4~7%). CI 성능 게이트 통과 여부는 performance workflow에서 확인해야 합니다.
  - 사용자가 할 일: 없습니다.
  - 운영자가 할 일: 없습니다.
- feat(doctor): `agent-guard doctor`가 오래된 셸 연동을 알려 줍니다. v3.9.0 전에 `setup-shell`을 실행한 `~/.zshrc`·`~/.bashrc`에는 marker 사이에 resolver 전체(약 155줄)가 그대로 남아 있고, `~/.agent-guard/shell-init.sh`(`--no-command-wrapping`이면 `shell-init-no-wrapping.sh`)는 `setup-shell`을 실행한 시점의 resolver 사본이라 이후 resolver 수정이 반영되지 않는데, 지금까지는 어느 쪽도 알려 주지 않았습니다. (#482)
  - 동작 변경: `setup-shell`이 쓰는 resolver 파일의 첫 줄이 `# agent-guard shell-init bootstrap v1 (managed by agent-guard setup-shell; rerun it to regenerate)` 형식 줄로 바뀝니다. `doctor`는 `~/.zshrc`나 `~/.bashrc`에 v3.9 이전 인라인 블록이 있거나, resolver 파일에 형식 줄이 없거나 더 오래된 형식 줄이 있으면 `shell integration:`으로 시작하는 안내 줄을 출력합니다. 안내만 하므로 종료 코드는 바뀌지 않고, 어떤 파일도 고치지 않습니다. 현재 형태면 아무것도 출력하지 않습니다. SessionStart 출력(모델 context)과 `setup` 출력은 바뀌지 않고, 예전 블록과 파일도 지금처럼 로드됩니다. `--rc`로 고른 rc 파일은 확인하지 않습니다.
  - 사용자가 할 일: `doctor`가 안내하면 안내된 `agent-guard setup-shell` 명령(플러그인 설치는 `/agent-guard:setup-shell`)을 다시 실행합니다. rc 블록은 한 줄로 바뀌고 resolver 파일은 새로 써집니다. 그 뒤 셸과 그 셸에서 띄운 세션을 다시 시작합니다.
  - 운영자가 할 일: 없습니다.
- fix(shell-init): `setup-shell --no-command-wrapping`로 설치한 셸 연동이 아무것도 불러오지 못하던 문제를 고칩니다. `shell-init --no-command-wrapping`이 snippet을 다 출력하고도 종료 코드 1로 끝나서, `~/.agent-guard/shell-init-no-wrapping.sh`가 그 결과를 "불러올 것 없음"으로 읽고 버렸습니다. 그래서 opt-out으로 설치한 셸에는 `agx`도, SessionStart가 확인하는 버전 표시도 없었습니다. (#482)
  - 동작 변경: `shell-init --no-command-wrapping`이 종료 코드 0으로 끝나고, opt-out rc를 불러온 셸에 `agx`와 nudge, 버전 표시가 생깁니다. 명령 wrapper(`cat`·`env` 등 감싸기)는 여전히 만들지 않습니다. 기본 설치(`setup-shell`)가 출력하는 내용은 바뀌지 않습니다.
  - 사용자가 할 일: `--no-command-wrapping`으로 설치했다면 업데이트 뒤 새 셸을 엽니다. rc와 resolver 파일을 다시 쓸 필요는 없습니다.
  - 운영자가 할 일: 없습니다.
- refactor(hooks): 플러그인 hook 명령마다 들어 있던 약 2.2 KB inline resolver와 infrastructure-failure 정책을 플러그인에 함께 실리는 `hooks/launch.sh` 하나로 옮겼습니다. 이제 Claude·Codex hook 명령은 이벤트마다 subcommand만 다른 약 500바이트 한 줄입니다(`sh -c 'r=${PLUGIN_ROOT:-}; [ -n "$r" ] && for q in "$r" "${r%/*}/current" "${r%/*}"/[0-9]*.[0-9]*.[0-9]*; do [ -f "$q/hooks/launch.sh" ] && exec sh "$q/hooks/launch.sh" codex hook-stop "$r"; done; ...'`, Claude는 `CLAUDE_PLUGIN_ROOT`와 `claude`). Claude Code가 차단 이유 앞에 붙여 보여 주던 2 KB 명령(#294)도 이 한 줄로 줄어듭니다. (#482)
  - 동작 변경: host가 고른 완전한 버전 디렉터리 우선, 세션 중 삭제된 디렉터리의 `current`·가장 높은 완전한 semver 형제 복구, 존재하지만 불완전한 디렉터리에 형제를 대신 쓰지 않는 규칙, closed의 매번 이유 출력, open의 세션당 한 번 경고, `AGENT_GUARD_HOOK_HOST` 고정, stdin 전달은 그대로 launcher가 지킵니다. 달라지는 점은 셋뿐입니다. (1) launcher를 어디에서도 찾지 못하면(plugin-root 변수가 없거나 캐시 전체가 사라진 경우) 명령 줄 자체의 fallback이 open 모드에서 세션당 한 번이 아니라 호출마다 경고합니다. closed는 전처럼 매번 이유와 함께 exit 2입니다. (2) 세션 중 디렉터리가 삭제됐을 때 launcher가 없는 이전 버전 형제로는 복구하지 않습니다(다운그레이드와 세션 중 삭제가 겹칠 때만 해당). (3) 경고 marker 디렉터리 기본값이 CLI와 같은 `${TMPDIR:-/tmp}/agent-guard-warnings-$(id -u)`가 되고 umask 077로 만들어집니다. dash처럼 `$UID`가 없는 셸에서는 지금까지 모든 계정이 `agent-guard-warnings-user`를 함께 썼으므로, 업데이트 직후 경고가 한 번 더 보일 수 있습니다.
  - 사용자가 할 일: Codex 사용자는 업데이트 뒤 agent-guard hook을 한 번 다시 신뢰해야 합니다. 검토할 명령은 이제 위의 짧은 launcher 한 줄이며, `agent-guard doctor`가 다시 신뢰가 필요한 상태와 절차를 알려 줍니다. 앞으로 resolver 수정은 `hooks/launch.sh`에만 들어가므로 hook 명령 문구는 바뀌지 않습니다(Codex는 플러그인 내용으로도 신뢰하므로 플러그인 업데이트마다 다시 신뢰하는 것은 그대로입니다). Claude Code 사용자는 할 일이 없습니다.
  - 운영자가 할 일: 없습니다.

## v3.11.4 - 2026-11-17

- fix(bash): 검증 메모를 남기는 Bash 명령의 본문에 `` `@next/env` `` 같은 백틱 글이 있으면, `env`를 실행하는 명령 치환으로 읽는 deny 줄(`deny-bash-patterns.txt` 19번째 줄) 때문에 "blocked risky shell command by deny pattern"으로 막히던 오탐을 고칩니다. 작은따옴표 단어와 따옴표로 감싼 delimiter의 here-document 본문 안에서는 셸이 `` `…` ``·`$(…)`를 치환하지 않습니다. deny 목록 자체는 바꾸지 않았습니다. (94S-1712, #485)
  - 동작 변경: deny 패턴 검사 전에, 셸이 글자 그대로 넘기고 그 글을 데이터로만 다루는 명령이 받는 백틱과 `$(`의 `$`만 `_`로 바꿔 읽습니다(나머지 글자는 그대로 검사합니다). 대상은 두 가지입니다. (1) `<<'EOF'`·`<<"EOF"`·`<<-'EOF'` here-document 본문 중, 보호 경로 검사가 이미 데이터로 인정하는 모양(본문을 쓰기만 하는 `cat`·`tee`, stdin에서 본문을 읽는 `gh pr|issue … --body-file -`·`git commit -F -`)이고, 같은 명령의 다른 구간이 inert 명령 목록(`echo`·`cat`·`grep` 등)이나 `mkdir`·`git`뿐일 때. (2) here-document가 없는 줄의 작은따옴표 단어 중, 줄의 모든 명령이 메시지 값 예외와 같은 inert 목록에 있고 리다이렉션·그룹·서브셸·백그라운드·대입 접두사·`$'…'`·큰따옴표 안 치환이 없을 때. 다시 토큰화해 바뀐 것이 그 글자뿐임을 확인하지 못하면 원문을 그대로 검사합니다. 계속 막히는 것: 큰따옴표 안(`echo "…"`)과 따옴표 없는 delimiter(`<<EOF`) 본문의 백틱, `env`·`printenv`·`` echo `env` ``·`echo $(env)`·`cat .env`, 본문이나 인자를 실행할 수 있는 `sh`·`bash -s`·`sudo sh`·`ssh host`·`python3 -`·`xargs sh -c`가 읽는 here-document, `cat <<'EOF' | sh`, 쓴 파일을 같은 명령에서 다시 실행하는 경우, 앞에서 `cat`을 함수·alias·`PATH`로 바꾸는 경우, `sh -c '…'`·`bash -c`·`eval`·`ssh host '…'`·`xargs`·`trap`·`watch`·`find -exec`·`su -c`·`docker exec`·`git config alias`·`awk`·`perl -e`가 받는 작은따옴표 인자, `echo '…' | sh`, `echo '…' > x.sh`, here-document 뒤 줄의 실제 명령. 분류하지 않아 계속 막히는 모양: `<<\EOF`·`<<E'O'F` delimiter, 한 줄의 here-document 둘, 끝 줄이 없는 본문, here-string `<<<`, 명령 치환 안의 here-document, `printf`처럼 inert 목록에 없는 명령의 인자, here-document와 작은따옴표 인자가 같은 명령에 함께 있는 경우.
  - 사용자가 할 일: 없습니다. 위 모양이 아닌 곳에 백틱 글을 넣어야 하면 `gh … --body-file -`에 `<<'EOF'` here-document로 본문을 넘기세요.
  - 운영자가 할 일: 없습니다.
- fix(scan): `git push --force-with-lease=agent-access-team-only:<커밋 SHA>` 처럼 브랜치 이름에 `access`·`token` 같은 키워드가 든 force-with-lease 기대값의 커밋 SHA를 generic-api-key가 비밀값으로 잡아, Bash PreToolUse 검사가 명령을 막고 UserPromptSubmit 검사가 보고문을 버리던 문제를 고칩니다. (#478)
  - 동작 변경: gitleaks.toml에 generic-api-key만 대상으로 하는 줄 단위 예외를 추가했습니다. 줄이 `--force-with-lease=<ref>:<소문자 hex 40자 또는 64자>` 하나를 갖고, 그 뒤가 공백이나 줄 끝일 때만 면제합니다. `<ref>`는 영문자·숫자·`._/@+-`만 허용합니다. 같은 줄의 나머지에서는 generic-api-key의 구분자 `=`, `:`, `>`, `,`, `|`, `?` 뒤에 공백·따옴표·백틱이 오고, 그 뒤가 토큰 문자(`[\w.=+/-]`) 9자 이하이거나 토큰 문자가 아닌 문자여야 합니다. 그래서 `git add -A && git commit -m "fix(scope): tighten, then check" && git push --force-with-lease=...`처럼 커밋 메시지의 콜론·쉼표 뒤에 짧은 낱말만 오는 한 줄 명령은 이제 통과합니다. 구분자 뒤에 값 길이(10자 이상)의 토큰 문자열이 오면 줄 전체가 면제되지 않아 두 값 모두 계속 막힙니다. 예: `api_token=<hex>`, 메시지 안의 `token: <hex>`, 뒤따르는 `curl -H "X-Api-Key: <hex>"`. 콜론이나 쉼표 바로 뒤에 10자 이상 붙은 낱말(`docs: restructure-readme`)이나 같은 줄의 두 번째 lease가 있으면 계속 막히니, 메시지를 줄이거나 커밋과 푸시를 줄을 나눠 실행해야 합니다. 41자 이상 hex, 대문자 hex, 따옴표로 감싼 값, 값 뒤에 토큰 문자가 붙은 경우, git이 받지 않는 `--force-with-lease <ref>:<sha>` 두 인자 표기, 다른 옵션은 면제하지 않습니다. `access_token: <hex>`, `api_token=<hex>`, `ACCESS_KEY="<hex>"` 같은 키워드 대입과 접두사 없는 `access-token:<hex>`는 계속 막힙니다. 벤더 규칙은 바뀌지 않습니다.
  - 사용자가 할 일: 없습니다.
  - 운영자가 할 일: 없습니다.
- fix(bash): Bash 명령의 `curl -u 이름:비밀번호`·`--user 이름:비밀번호`를 deny 패턴으로 막고, 따옴표로 감싼 URL scheme(`git clone "https"://…`)과 따옴표·백슬래시로 쪼갠 명령 이름(`c'u'rl`, `"sec"urity`, `s'ecurity'`)도 같은 deny 줄로 막습니다. 셸은 실행 전에 따옴표를 지우므로, 원문 글만 보던 패턴이 놓치던 우회입니다. (#470)
  - 동작 변경: `-u`/`--user` 값에 `:` 뒤 비밀번호가 있으면 막습니다(`-uuser:pw`, `--user=user:pw`, `-su user:pw`, 빈 사용자 `-u :pw`, 따옴표 값, `-u "$U:$P"` 같은 변수 쌍 포함). 이름만 주는 `-u user`(비밀번호를 대화형으로 받음), 빈 비밀번호 `-u user:`·`-u :`, 쌍 전체를 변수 하나로 주는 `-u "$CREDS"`는 통과합니다. deny 패턴은 원문 글에 더해 따옴표를 지운 사본도 검사합니다. 사본에서 따옴표를 지우는 단어는 여러 조각으로 쪼갠 단어와 명령 자리의 따옴표 단어뿐이고, 따옴표 안에 공백·줄바꿈·`;`·`|`·`&`·`(`·`)`·`<`·`>`·백틱이 있으면 그대로 둡니다. 그래서 `grep "printenv" src`, `'a|env|b'`, `echo "load the env"`, JSON 본문처럼 따옴표로 감싼 인자 하나는 이전과 같이 판정합니다. 커밋·PR 메시지 값 예외와 `ORCA_*` 변수 조회 예외는 사본에도 똑같이 적용됩니다. URL 안 비밀번호를 큰따옴표로 감싼 `https://u:"$PW"@host`도 이제 막습니다. 알려진 잔여: `$'\x63url'` 같은 ANSI-C escape, `sh -c`·변수로 명령을 나눈 경우, URL 안에서 `$(<file)`로 읽은 비밀번호, `curl --proxy-user`/`-U`, `wget --user`/`--password`(대문자 `PASSWORD` 글자가 없을 때)는 막지 않습니다. 닫히지 않은 따옴표는 글 끝에서 닫힌 것으로 읽습니다(셸은 그런 명령을 실행하지 않습니다). 따옴표로 쪼갠 단어가 그대로 deny 줄과 맞으면, 그 단어가 `echo` 인자 같은 데이터여도 막힙니다(따옴표 없이 쓴 같은 글이 이미 막히는 것과 같습니다).
  - 사용자가 할 일: curl에 basic 인증이 필요하면 `-u 이름`만 주어 비밀번호를 대화형으로 받거나, `--netrc-file`·`-K` 설정 파일을 쓰세요.
  - 운영자가 할 일: 없습니다.
- fix(bash): keychain을 읽는 `security find-generic-password`·`find-internet-password` deny 줄이 `dump-keychain` 줄과 같은 왼쪽 경계를 씁니다. 그래서 이름이 `security`로 끝나는 다른 명령(`my-security`, `mysecurity`, `my_security`)의 `find-*-password`는 더는 막지 않습니다. (#469)
  - 동작 변경: `security ...`, `/usr/bin/security ...`, 줄 처음이나 `;`·`&&`·`|`·공백 뒤의 `security find-*-password`는 이전과 같이 막습니다. 바로 앞 글자가 영문자·숫자·`_`·`.`·`-`인 경우만 다른 명령 이름의 일부로 보고 통과시킵니다.
  - 사용자가 할 일: 없습니다.
  - 운영자가 할 일: 없습니다.
- perf(bash): `printf 'build passed'`처럼 `sed` 글자가 다른 낱말 안에 들어 있을 뿐인 Bash 명령은 더는 jq·sed 필터 예외 경로를 돌지 않습니다. 이 경로의 사전 검사가 `sed`를 낱말 경계 없이 찾아서, `passed`·`used`·`closed`·`released` 같은 낱말이 있는 깨끗한 명령마다 PreToolUse가 awk를 3번 더 실행했고, nightly 성능 측정의 `pre-bash-clean`(homebrew, off)이 v3.7.0 기준 5%를 넘었습니다. (#477)
  - 동작 변경: 사전 검사가 `sed`를 온전한 이름일 때만 인정합니다(같은 함수의 `jq_names_tool`과 같은 규칙). 막는 범위는 줄지 않습니다. 사전 검사는 예외 경로로 들어갈지만 정하므로, 건너뛰면 명령 전체가 그대로 보호 경로 검사를 받습니다. 달라지는 판정은 한 가지로, #463 이후 우연히 통과하던 `j''q -r .key passed.json`(따옴표로 쪼갠 jq 이름과 `sed` 글자가 든 다른 낱말이 함께 있는 명령)이 다시 막힙니다. `sed -n 1p file`처럼 실제 sed 명령과 jq 명령의 예외는 그대로입니다.
  - 사용자가 할 일: 없습니다.
  - 운영자가 할 일: 없습니다.
- fix(redact): `client secret: must be rotated monthly`·`- password: should not be logged anywhere`처럼 비밀값 이름 뒤 콜론에 그 값을 어떻게 다루는지 설명하는 영어 문장이 오는 글을 프롬프트 가드가 더는 막지 않고, 출력 마스킹도 그 문장을 가리지 않습니다. 대입문 probe가 콜론 뒤 첫 낱말(`must`)을 비밀값으로 보던 탓입니다. (94S-1705, #481)
  - 동작 변경: 예외는 콜론 형태에서 따옴표·백틱 없이 온 값의 첫 낱말이 `must`·`should`·`shall`·`will`·`would`·`might`·`needs`·`when` 중 하나(소문자만)이고, 그 뒤로 같은 줄 끝까지 영문 소문자로만 된 낱말이 둘 이상 공백 한 칸씩(탭·연속 공백 제외) 이어질 때뿐입니다. 줄 끝의 마침표 하나와 그 뒤 공백만 떼고 판정하므로, 쉼표·세미콜론·마침표 둘 이상 같은 기호, 숫자, 대문자, 한글이 줄 안 어디에든 있으면 값은 계속 막고 가립니다. 뒤따르는 낱말은 하나씩 따로 판정해 비밀값 모양(24자 이상 소문자 연속 등)이면 값 전체를 계속 막고 가립니다. 키를 따옴표로 감싼 JSON 모양이면 예외가 아닙니다. 백틱이나 큰따옴표·작은따옴표 안 문장, `=` 대입, 목록에 없는 낱말로 시작하는 문장(`client secret: rotated monthly`), 대문자로 시작하는 `Must`, 낱말 하나뿐인 값(뒤에 `#` 주석이 붙어도), `passphrase: correct horse battery staple`(따옴표 없이와 백틱 안 모두)은 바뀌지 않습니다. 목록 낱말은 EFF large·short 단어 목록에 없는 것만 골랐지만, 원래 Diceware 목록에는 `must`·`shall`·`will`·`would`·`might`·`when`이 있습니다. 그래서 목록 낱말로 시작하고 소문자 낱말 둘 이상이 이어지는 따옴표 없는 패스프레이즈(예: `passphrase: must have more coffee`)는 이제 막히지도 가려지지도 않습니다. 같은 모양으로 줄 끝까지 가는 YAML 값도 마찬가지입니다. gitleaks 규칙은 바뀌지 않습니다.
  - 사용자가 할 일: 없습니다.
  - 운영자가 할 일: 없습니다.
- fix(bash): `command jq -r '.a.key' s.json`, `/usr/bin/jq -r .a.key s.json`처럼 `command` builtin이나 시스템 경로로 실행한 jq의 필드 선택자(`.a.key`·`.b.p8`·`.c.env`)를 deny-read 경로로 보고 막던 오탐을 고칩니다. 이슈의 `jq -r '.a.key' s.json`, `jq -r '.a.key, .b.p8, .c.env' s.json`은 #462·#464 이후 main에서 이미 통과하며, 이번에 회귀 시험으로 고정합니다. (#468)
  - 동작 변경: jq 필터 예외(필터의 필드 이름만 지우고 다른 단어는 그대로 검사)가 맨 jq뿐 아니라 옵션 없는 `command jq`와 `/usr/bin/jq`·`/bin/jq`·`/usr/local/bin/jq`·`/opt/homebrew/bin/jq`에도 적용됩니다(sed도 같은 위치 규칙). 첫 번째 비옵션 인자만 필터로 보고, `-f`가 있거나 `--arg`·`--rawfile`·`--slurpfile` 값, 그 뒤 파일 피연산자, 리다이렉션은 계속 검사하므로 `jq . .env`, `jq -r .a.key x.key`, `command jq --rawfile v x.key '.a' s.json`은 계속 막힙니다. `command -v jq`, `./jq` 같은 다른 경로의 jq, `xargs jq`, 그리고 `cat s.json && command jq '.a.key' s.json`처럼 첫 파이프라인 뒤 구간의 `command jq`·시스템 경로 jq는 바뀌지 않고 계속 막힙니다(그 위치의 맨 jq는 #464대로 예외를 받습니다).
  - 사용자가 할 일: 없습니다.
  - 운영자가 할 일: 없습니다.

## v3.11.3 - 2026-11-17

- fix(redact): `client secret: `PUT /v1/login-providers/:id/client-secret`` 처럼 비밀값 이름 뒤 콜론에 HTTP 메서드와 경로가 오는 설명문을 프롬프트 가드가 더는 막지 않고, 출력 마스킹도 그 경로를 가리지 않습니다. 대입문 probe가 백틱 안 값 전체를 비밀값으로 보던 탓입니다. (#479)
  - 동작 변경: 예외는 콜론 형태에서 따옴표 없이 또는 백틱 안에 온 값이 `GET`·`HEAD`·`POST`·`PUT`·`PATCH`·`DELETE`·`OPTIONS` 중 하나와 공백 한 칸(탭 제외), 경로이거나, 메서드 없이 세그먼트 둘 이상인 경로일 때뿐입니다. 경로 문자는 영문자·숫자·`._~:{}-`만 허용하고, 세그먼트마다 따로 판정해 비밀값 모양이거나 10자리 이상 숫자가 있으면 값 전체를 계속 막고 가립니다. `=` 대입, 큰따옴표·작은따옴표 값, 쿼리 문자열, 소문자 메서드, 메서드 없는 한 세그먼트 경로는 바뀌지 않습니다. 5자 이하로 쪼갠 짧은 세그먼트들은 비밀값 모양 검사(6자 미만 제외)에 걸리지 않으므로, 그런 모양의 낮은 엔트로피 값은 이 자리에서 막히지 않습니다. gitleaks 규칙은 바뀌지 않습니다.
  - 사용자가 할 일: 없습니다.
  - 운영자가 할 일: 없습니다.

## v3.11.2 - 2026-11-15

- fix(redact): 이름이 Secret으로 끝나는 함수나 필드 뒤에 콜론과 이슈 트래커 id가 오는 글(`- setClientSecret: ABC-123 조건을 따른다`)을 프롬프트 가드가 더는 막지 않고, 출력 마스킹도 그 id를 가리지 않습니다. 대입문 probe가 콜론 뒤 4자 넘는 값을 모두 비밀값으로 보던 탓입니다. (#471)
  - 동작 변경: 예외는 세 조건을 모두 갖춘 경우뿐입니다. 키는 `Secret` 바로 앞 글자가 소문자나 숫자인 이름입니다(`clientSecret`, `setClientSecret`; `jwtSecret`·`webhookSecret` 같은 설정 키도 해당). 값은 콜론 뒤에 따옴표 없이 또는 백틱 안에 온 대문자 이슈 id입니다. 같은 줄에서 값 뒤에 영문자나 한글 음절로 시작하는 낱말이 이어져야 합니다. 그래서 줄 끝, 쉼표 뒤 다음 키(YAML flow mapping), `#`·`//`·`;` 주석, 숫자나 기호(줄표 같은 비ASCII 기호 포함)로 시작하는 꼬리는 예외가 아닙니다. 이슈 id의 팀 키는 영문 대문자·숫자 10자 이하이고, 대문자가 하나 이상 있어야 합니다(숫자로 시작해도 됨). `-` 뒤 숫자는 0으로 시작하지 않는 6자리 이하입니다. 끝의 한국어 조사 하나(백틱 안에서는 쉼표도)는 떼고 판정합니다. `secret:`·`api_secret:`·`CLIENT_SECRET:`와 password·token·key 키, 줄 끝에서 끝나는 YAML 값, `=` 대입, JSON 문자열, 소문자나 대소문자가 섞인 값, 더 긴 숫자는 계속 막고 가립니다. gitleaks 규칙은 바뀌지 않으므로, 엔트로피가 높은 id는 gitleaks가 여전히 잡을 수 있습니다. 반대로 위 세 조건을 갖춘 자리에서는, 사람이 고른 엔트로피 낮은 `대문자 단어-숫자` 모양 값(예: 계절 이름과 연도)이 이슈 id와 모양으로 구별되지 않아 이제 막히지도 가려지지도 않습니다.
  - 사용자가 할 일: 없습니다.
  - 운영자가 할 일: 없습니다.

## v3.11.1 - 2026-11-15

v3.11.0은 릴리스 머지 뒤 main이 움직여 태그를 발행하지 못했고, 같은 내용이 이 버전에 포함된다.

- ci: native platform 워크플로를 실제로 실행하는 테스트 변경에만 PR에서 기동 (#474)
- ci: 릴리스 시 직렬 전체 테스트를 main CI 성공 확인으로 대체 (#473)
- release: v3.11.0 (#472)
- fix(mcp): Figma MCP 도구의 fileKey·file_key 파일 키를 비밀값으로 보지 않는다 (#466)
- fix(hooks): 훅마다 statusMessage 이름을 붙여 Codex /hooks의 Unnamed hook을 없앤다 (#465)
- fix(bash): grep 앞 구간 판정이 믿는 위치의 jq·sed에도 필터 예외를 적용한다 (#464)
- fix(bash): sed s 명령의 정규식을 보호 경로 검사에서 뺀다 (#463)
- feat(redact): deny-read mask 모드에서 루트 dotenv 값을 출력에서 마스킹한다 (#460)
- feat(hooks): Claude PostToolUseFailure의 실패 출력에서 secret을 찾아 마스킹되지 않았음을 알린다 (#461)
- fix(bash): jq 필터의 env 멤버 이름을 보호 경로 검사에서 뺀다 (#462)

## v3.11.0 - 2026-11-15

- fix(mcp): Figma MCP 도구의 fileKey·file_key 파일 키를 비밀값으로 보지 않는다 (#466)
- fix(hooks): 훅마다 statusMessage 이름을 붙여 Codex /hooks의 Unnamed hook을 없앤다 (#465)
- fix(bash): grep 앞 구간 판정이 믿는 위치의 jq·sed에도 필터 예외를 적용한다 (#464)
- fix(bash): sed s 명령의 정규식을 보호 경로 검사에서 뺀다 (#463)
- feat(redact): deny-read mask 모드에서 루트 dotenv 값을 출력에서 마스킹한다 (#460)
- feat(hooks): Claude PostToolUseFailure의 실패 출력에서 secret을 찾아 마스킹되지 않았음을 알린다 (#461)
- fix(bash): jq 필터의 env 멤버 이름을 보호 경로 검사에서 뺀다 (#462)

## Unreleased

- feat(hooks): Claude Code에서 도구 호출이 실패하면 `PostToolUse` 대신 `PostToolUseFailure`가 실행됩니다. Claude 플러그인 manifest와 `examples/claude/settings.project.json`이 이 event를 `PostToolUse`와 같은 matcher·20초 timeout으로 등록하고, 새 subcommand `hook-post-tool-failure`가 실패 출력(`error`)을 성공 출력 마스킹과 같은 detector로 검사합니다. (#444, #461)
  - 동작 변경: host가 이 event에 `additionalContext`만 허용하므로 실패 출력은 마스킹되지 않고 그대로 모델에 갑니다(`updatedToolOutput`, `decision: "block"`, exit 2 모두 error 글을 바꾸지 못합니다. host 쪽 요청: anthropics/claude-code#97278). secret 모양 값을 찾으면 값은 적지 않고 종류만 밝혀, 마스킹되지 않았다는 것과 그 값을 되풀이하거나 쓰지 말고 사용자에게 교체가 필요할 수 있다고 알리라는 내용을 `additionalContext`로 보냅니다. `logs export`에는 `hook-post-tool-failure` 기록이 outcome `warned`로 남습니다. 깨끗하면 아무것도 출력하지 않습니다. 검사를 못 하면 깨끗하다고 하지 않고 `AGENT_GUARD_INFRA_FAILURE_MODE=open`에서는 세션마다 한 번, `closed`에서는 매번 알립니다. 막을 수 있는 것이 없으므로 두 모드 모두 exit 0입니다. JSON 객체가 아니거나 `error`가 없는 입력은 그대로 통과합니다. `AGENT_GUARD_OUTPUT_REDACT=off`면 검사하지 않습니다. Codex manifest는 바뀌지 않습니다.
  - 사용자가 할 일: Claude Code 플러그인을 갱신하고 플러그인을 다시 읽습니다. 경고가 나오면 그 자격 증명을 교체합니다.
  - 운영자가 할 일: standalone 설정을 쓰면 `examples/claude/settings.project.json`의 `PostToolUseFailure` 항목을 settings에 더합니다.
- feat(redact): `AGENT_GUARD_DENY_READ_MODE=mask`이면 출력 마스킹이 프로젝트 루트 dotenv 파일의 값을 알려진 값으로 보고, 출력에서 그 값과 정확히 같은 부분을 모두 `[REDACTED]`로 바꿉니다. 키 이름이 일반적이고 공급자 접두사도 없는 secret(`APP_SEED=...`, 또는 같은 값이 로그 줄·argv 목록·URL 비밀번호에 그대로 나온 경우)이 그동안 마스킹을 지나가던 #98의 잔여를 줄입니다. Claude·Codex `PostToolUse`와 `agent-guard exec`/`agx`에 똑같이 적용됩니다. (#445, #460)
  - 동작 변경: 기본값 `block` 모드에서는 바뀌지 않습니다. 출력 마스킹을 위해 dotenv 파일을 열지 않으며 잔여도 그대로입니다. `mask` 모드에서는 이벤트 `cwd`(`exec`는 작업 디렉터리)와 그 Git 최상위 디렉터리 바로 아래 파일 중, 이름이 deny-read 목록에 있고 mask-file이 dotenv로 읽는 파일만 씁니다. 하위 디렉터리, symlink, `.env.example` 같은 템플릿, `.envrc`는 읽지 않습니다. 8바이트보다 짧은 값, 불리언, 숫자, 빈 값, 그리고 영문자·숫자·기타 문자 중 두 종류 이상을 섞지 않은 값(`development`·`localhost` 같은 평범한 단어)은 쓰지 않습니다. 따라서 영문자로만 된 긴 secret은 잡지 않습니다. 정확히 같은 문자열만 바꾸며 인코딩한 변형은 잡지 않습니다. 읽을 수 없거나 dotenv 부분집합 밖인 파일은 값을 내지 않고(`${VAR}` 참조·백틱·여러 줄 값이 한 줄이라도 있으면 그 파일 전체가 해당), 다른 규칙의 마스킹은 그대로 진행합니다. 값은 한 번의 실행 동안 메모리에만 두며 감사 로그·캐시·경고·오류 메시지에 쓰지 않습니다. 필터를 통과한 값은 secret으로 쓰이지 않은 곳(예: `db.example.com` 같은 호스트 이름)에서도 출력 어디서나 마스킹됩니다.
  - 사용자가 할 일: 없습니다. `mask` 모드에서 끄려면 `AGENT_GUARD_KNOWN_VALUE_REDACT=off`를 설정합니다. `AGENT_GUARD_OUTPUT_REDACT=off`도 이 기능을 끕니다. 루트 dotenv 파일 밖에 있는 secret은 여전히 잡지 않습니다.
  - 운영자가 할 일: 없습니다.
- fix(hooks): hook마다 `statusMessage` 이름을 붙여, Codex `/hooks` 화면에서 agent-guard hook 5개가 "Unnamed hook"이 아니라 `agent-guard: checking tool call`처럼 보입니다. Claude manifest의 hook 6개(`PostToolUseFailure` 포함)에도 같은 이름을 붙였고, Claude와 Codex 모두 hook이 도는 동안 이 글을 상태 표시로 보여 줍니다. - fix(hooks): hook마다 `statusMessage` 이름을 붙여, Codex `/hooks` 화면에서 agent-guard hook 5개가 "Unnamed hook"이 아니라 `agent-guard: checking tool call`처럼 보입니다. Claude manifest의 hook 6개(`PostToolUseFailure` 포함)에도 같은 이름을 붙였고, Claude와 Codex 모두 hook이 도는 동안 이 글을 상태 표시로 보여 줍니다. hook 명령·matcher·timeout은 바뀌지 않습니다. (#465)
  - 동작 변경: hook이 도는 동안 보이는 상태 글만 바뀝니다. 막기·스캔 결과와 종료 코드는 같습니다.
  - 사용자가 할 일: Codex는 hook 항목과 플러그인 내용으로 trust를 검사합니다. 그래서 hook을 직접 trust해 둔 설치는 이 버전으로 갱신하면 agent-guard hook이 모두 `modified`가 되고, 다시 trust할 때까지 실행되지 않습니다. 관리형(managed) trust로 받는 설치는 그 설정을 따릅니다. 갱신 뒤 `agent-guard doctor`를 실행하고, 안내대로 TUI의 "Hooks need review"에서 다시 trust합니다. Claude는 할 일이 없습니다. `examples/`의 hook 설정을 복사해 쓰는 독립 설치는 이름이 필요할 때 `statusMessage`를 직접 더합니다.
  - 운영자가 할 일: 없습니다.

## v3.10.0 - 2026-11-15

### 주요 변경

- feat(doctor): Codex가 `PATH`에 있으면 `agent-guard doctor`가 Codex에 agent-guard hook trust를 묻습니다. 잠깐 띄운 `codex app-server`의 `hooks/list`를 쓰므로 모델은 부르지 않습니다. Codex는 hook 항목과 플러그인 내용으로 trust를 검사하므로, `hooks.json`이 그대로여도 플러그인을 갱신하면 agent-guard hook이 모두 `modified`가 되어 실행되지 않을 수 있습니다. 이 상태를 이제 알립니다. (#458)
  - 동작 변경: agent-guard hook이 `modified`·`untrusted`(검토 필요)이거나 꺼져 있으면 `doctor`가 exit 1로 끝나고, TUI의 "Hooks need review"에서 다시 trust하는 절차를 출력합니다. 응답을 읽지 못하면 ok가 아니라 unverified로 보고하고, 이때 종료 코드는 바꾸지 않습니다. Codex용 `plugin status`·`plugin install`·`plugin update`(이미 일치하는 경우 포함)도 같은 결과를 출력하지만 종료 코드는 바꾸지 않습니다. ok는 새 Codex 프로세스가 읽는 설정의 스냅샷이며, hook 실행을 관찰한 것은 아닙니다. agent-guard는 trust를 직접 쓰지 않습니다.
  - 사용자가 할 일: 플러그인을 갱신한 뒤 `agent-guard doctor`를 실행하고, 안내가 나오면 그 절차대로 다시 trust합니다. 확인을 끄려면 `AGENT_GUARD_CODEX_TRUST_CHECK=off`를 설정합니다. 이 확인은 Codex app server를 띄우므로, 여느 Codex 시작처럼 네트워크에 접속하거나 Codex 자체 캐시를 갱신할 수 있습니다.
  - 운영자가 할 일: 없습니다. v3.9.0 노트의 "Codex hook trust를 다시 받을 필요가 없습니다"는 틀렸습니다. 플러그인 내용이 바뀌면 Codex hook을 다시 trust해야 합니다.

## v3.9.0 - 2026-11-14

### 주요 변경

- feat(shell): `setup-shell`이 shell rc에 약 155줄 블록 대신 시작·끝 마커와 한 줄 `[ ! -r ~/.agent-guard/shell-init.sh ] || . ~/.agent-guard/shell-init.sh`만 씁니다. 실행 전에 캐시 바이너리를 검증하는 resolver는 그 파일로 옮겼고 내용은 같습니다. 두 파일 모두 캐시의 `current` 링크와 캐시 기준 경로만 적으므로, 플러그인 버전이 바뀌어도 다시 쓸 필요가 없습니다. 마스킹·deny·hook 동작과 hook manifest는 바뀌지 않습니다. (#455, #456)
  - 동작 변경: `setup-shell`을 다시 실행하면 예전 블록을 같은 자리에서 새 블록으로 바꿉니다(블록 뒤의 rc 줄 순서가 유지됩니다). `--no-command-wrapping`은 `~/.agent-guard/shell-init-no-wrapping.sh`를 따로 씁니다. 파일이 없으면 rc 줄은 아무것도 하지 않고 종료 상태 0으로 끝나므로, `set -e`로 rc를 읽는 스크립트도 멈추지 않습니다. 이때 SessionStart가 "can no longer load" 안내를 보이며, 이 안내는 이제 부모 셸에서 물려받은 `AGENT_GUARD_SHELL_INIT_VERSION`이 있어도 나옵니다. 같은 계정에서 다른 설치 경로로 `setup-shell`을 실행하면 마지막 실행이 그 파일을 씁니다.
  - 사용자가 할 일: 새 블록을 원하면 `/agent-guard:setup-shell`(독립 설치는 `agent-guard setup-shell`)을 한 번 다시 실행하고 셸과 세션을 다시 시작합니다. 예전 블록도 그대로 동작합니다. 독립 설치를 지울 때는 rc 블록과 함께 `~/.agent-guard/shell-init*.sh`도 지웁니다.
  - 운영자가 할 일: 없습니다. hook manifest가 바뀌지 않으므로 Codex hook trust를 다시 받을 필요가 없습니다.
- fix(scan): 접두사가 있는 UUID 모양 key(LaunchDarkly 서버 SDK key 모양, `sdk-`와 소문자 UUID)를 shape 규칙 `agent-guard-vendor-token-shape`로 잡습니다. `sdk-` 뒤에 패키지 이름 같은 일반 단어가 오면 잡지 않습니다. (#453)
- chore(platform): Intel Mac(x86_64-apple-darwin) 지원을 끝냅니다. 마지막 지원 버전은 v3.8.2입니다. 이후 릴리스는 `agent-guard-redact-x86_64-apple-darwin` helper(archive의 `libexec/`와 별도 asset)를 배포하지 않습니다. `native-validation.json`의 targets는 3개입니다. CI는 macOS Intel 러너를 쓰지 않습니다. (#450)
  - 동작 변경: Intel Mac에서는 CLI가 native helper를 고르지 않고 셸/jq 치환기를 씁니다. hook이 막히지는 않습니다. v3.8.2에서 남은 Intel helper가 있어도 실행하지 않으며, 독립 설치 스크립트가 업데이트 때 지웁니다. 독립 설치 스크립트와 Homebrew formula(caveats)는 Intel Mac에서 설치·업데이트 때 지원 종료 안내를 보입니다.
  - 사용자가 할 일: Apple silicon Mac과 Linux는 할 일이 없습니다. Intel Mac에서 검증된 native helper를 계속 쓰려면 v3.8.2에 머무릅니다. 독립 설치는 설치 스크립트를 `AGENT_GUARD_VERSION=3.8.2`로 실행하고, 그 뒤 `agent-guard update`를 하지 않습니다. Homebrew는 v3.8.2에서 `brew pin agent-guard`를 씁니다. `AGENT_GUARD_RUST_CORE_BIN`이나 `AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN`에 Intel helper 경로를 직접 넣었다면, 업데이트 뒤 그 파일이 없어 jq 단계로 돌아가므로 설정을 지웁니다.
  - 운영자가 할 일: 다음 릴리스의 Phase 2는 main push native run의 세 플랫폼 artifact만 읽습니다. `public-native-release.yml`은 targets가 3개인 릴리스만 통과시키므로 v3.8.2 이하를 다시 검증하는 데 쓰지 않습니다.
- fix(hooks): Bash 명령의 `security dump-keychain`(옵션 유무와 관계없이)과, URL userinfo에 비밀번호가 든 명령(`scheme://user:password@host`, 사용자 이름이 비거나 비밀번호가 셸 변수여도)을 deny 패턴으로 막습니다. 비밀번호 없는 `ssh://git@host`, scp형 `git@host:repo`, URL path·query 안의 `@`, 한 단어로 붙은 JSON 안에서 URL 뒤에 오는 메일 주소, 커밋 메시지 값 안의 메일 주소와 URL은 이 패턴으로 막지 않습니다. 알려진 잔여: `postgres://postgres:postgres@localhost`처럼 로컬 기본 자격 증명 URL, 명령 글 안의 자리표시 URL, 비밀번호 변수 이름만 쓰는 대입·`export`·heredoc 줄, `https://[^:]+:[^@]+@` 같은 grep 정규식 글, 태그와 digest를 함께 쓴 컨테이너 transport 참조(`docker://alpine:3.19@sha256:…`), 큰따옴표 없이 URL 뒤에 `@`가 오는 한 단어 payload(`url=http://localhost:3000&email=a@b`)도 막힙니다. URL 안에서 비밀번호를 큰따옴표로 감싸거나 `$(<file)`로 읽으면(`https://u:"$PW"@host`) 막지 않습니다. (#449)
- fix(scan): `clientId`·`tokenRef`·`credential_ref`·`token_id`처럼 이름 끝이 `Id`·`Ref`·`_id`·`_ref`인 칸에 소문자 UUID 하나만 있으면 `generic-api-key` finding으로 보지 않습니다. Edit/Write 검사, 커밋 검사, `scan-path`, 출력 마스킹에 똑같이 적용됩니다. 접미사 앞 이름이 대소문자와 관계없이 `secret`이나 `secrets`로 끝나면(`secretId`, `secretRef`, `secret_ref`, `clientSecretRef`, `secret_id`) 이전과 같이 잡습니다. Vault AppRole과 Consul/Nomad의 secret id가 UUID이기 때문입니다. `SecretID`·`SECRET_ID`·`secret-id`, 대문자 UUID, 같은 줄의 다른 secret, 공급자 전용 UUID 규칙(Heroku, Snyk, HubSpot)도 그대로 잡습니다. 따옴표 UUID 뒤에 글자가 이어져 셸에서 더 긴 값이 되면 새 규칙 `agent-guard-reference-id-concatenation`이 잡습니다. 다만 secret이 아닌 참조 id의 셸 대입에서 따옴표 UUID 바로 뒤에 `,` `]` `}` 한 글자만 붙고 값이 끝나면, Python 여러 줄 키워드 인자와 구별할 수 없어 잡지 않습니다. (#448)

### 그 밖의 변경

- fix(tests): mktemp가 실패하면 cleanup trap 전에 시험 스크립트를 끝낸다 (#454)
- ci(perf): nightly 성능 실패 issue에 러너 CPU를 적고 latency만 오른 확정 행을 노이즈 의심으로 표시한다 (#451)
- ci(perf): 성능 측정을 main push에서 빼고 nightly·릴리스 PR에서 돌리며 nightly 실패는 issue로 알린다 (#447)
- ci(perf): 9쌍에서 넘은 케이스만 21쌍으로 확인해 러너 노이즈 실패를 줄이고 실패한 성능 job을 드러낸다 (#446)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#441)
- perf(scan): 동일 바이트의 clean 판정을 캐시해 반복 gitleaks 실행을 줄인다 (#443)
- fix(hooks): orca orchestration ask의 --question 값을 메시지 값으로 본다 (#442)
- perf(hooks): 훅 한 번마다 띄우던 jq·mktemp·보조 프로세스를 줄인다 (#440)
- fix(hooks): 변수 이름과 참조만 담은 소스 출력을 실행 후 마스킹에서 뺀다 (#439)
- fix(hooks): gh·git commit이 stdin으로 읽는 heredoc 메시지 본문을 보호 경로 매치에서 뺀다 (#438)
- fix(hooks): 메시지 값의 명령 치환을 구조적으로 판정하고 quoted heredoc 본문만 문자열로 본다 (#437)
- fix(hooks): 따옴표 안의 python 첨자를 env.* glob 오탐으로 막지 않는다 (#436)
- ci(lint): ShellCheck를 파일당 1프로세스로 실행해 메모리 피크를 낮춘다 (#435)
- fix(hooks): 차단 사유 코드를 감사 기록에 남겨 codex exec에서도 원인을 찾게 한다 (#434)
- fix(tests): audit-log 시험이 호출 위치의 Git 작업 트리에 영향받지 않게 한다 (#433)
- fix(scan): 실제 gitleaks가 없는 샤드에서 auto-wake 대조 시험을 건너뛴다 (#431)
- fix(scan): auto-wake 인박스 key의 dispatch id를 generic-api-key 오탐에서 뺀다 (#428)
- chore: 생성물·실험·계획 문서와 측정 원본을 삭제하고 재발을 막는다 (#430)
- perf(hooks): 보호 경로 정규식 컴파일 결과를 캐시해 Bash 훅 CPU를 줄인다 (#429)
- bench: 공개 7버전 실측 비교와 한국어 HTML·정확도 보고서 (#425)
- fix(hooks): 숫자만 든 브래킷이 ASCII 글자 자리를 대신하지 못하게 한다 (#422)
- fix(hooks): 소스 코드의 타입 주석과 멤버 참조를 출력 마스킹에서 뺀다 (#421)
- fix(hooks): 런타임 환경 객체 멤버 접근과 jq 보간을 보호 경로 텍스트 매치에서 뺀다 (#418)
- fix(hooks): ORCA_·CLAUDE_JOB_DIR 변수 조회를 환경 덤프 차단에서 뺀다 (#419)

## v3.8.2 - 2026-11-06

- fix(hooks): heredoc 본문과 산문 placeholder를 오탐으로 막지 않는다 (#423)
- ci: PR의 Fused contracts에서 macOS Intel 잡을 뺀다 (#417)
- fix(hooks): 마스킹된 토큰 값을 secret-like 할당으로 오인하지 않는다 (#416)
- ci: bump actions/upload-artifact from 4.6.2 to 7.0.2 (#401)
- ci: bump actions/setup-go from 6.5.0 to 7.0.0 (#400)
- ci: bump actions/download-artifact from 4.3.0 to 8.0.2 (#399)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#402)
- ci: 성능 비교를 차단 조건에서 빼고 중복 잡을 줄인다 (#415)

## v3.8.1 - 2026-11-06

- fix(hooks): 메시지 본문 오탐을 줄이고 set·$(env) 환경 출력 구멍을 막는다 (#405)
- ci: PR macOS matrix를 줄이고 전체 검증 체크를 구분한다 (#408)

## v3.8.0 - 2026-11-05

### 선택형 출력 처리 통합

- 기존 core에 JSON 문자열 추출·framing을 위한 `prepare-v1`을 추가하고, private 중간 파일과 출력 처리를 통합하는 선택형 경로를 제공합니다. 전체 재작성은 아니며 탐지·scanner·정책·PII·호스트 계약은 기존 셸에 남습니다. 기본 출력 파이프라인은 바꾸지 않습니다.
- `AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE=fused`와 검증된 절대 `AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN`을 함께 선택합니다. 소스만 있는 Git marketplace 플러그인은 기존 `AGENT_GUARD_RUST_CORE_BIN`도 같은 바이너리로 지정해 준비·치환에 공유합니다. 두 번째 helper나 Rust 컴파일러 설치는 필요하지 않습니다. helper 실패·누락은 원래 jq 단계로, 모듈 누락은 원래 파이프라인으로 복귀합니다. 선택 설정을 지우고 호스트를 재시작하면 기본 경로로 돌아갑니다.
- Claude/Codex의 기존 설치·업데이트 명령을 유지합니다. Git marketplace 설치는 같은 릴리스의 독립 사전 빌드 core를 연결할 수 있으며 호스트 캐시를 수정할 필요가 없습니다. 신뢰하는 실행 파일 재정의 계약과 체크섬 검증 방법은 [설치 안내](https://github.com/JeongJaeSoon/agent-guard/blob/v3.8.0/docs/installation.ko.md)를 참고하세요.

### 기본 경로의 수정

- 일반 문자열 출력의 framing에서 이스케이프가 없는 구간을 한 번에 처리해 긴 값의 반복 복사 비용을 줄입니다. 이스케이프가 있는 구간은 기존 상태 처리를 유지하며 제어 문자·비 UTF-8 바이트·문맥 경계·최장 일치의 독립 기대값을 검사합니다. 마스킹 범위와 scanner는 바꾸지 않습니다.
- 호스트가 절대 경로의 일반 실행 파일을 호출할 때 셸 내장 경로 처리를 사용해 시작 시 자식 프로세스 두 개를 줄입니다. 상대 경로·심볼릭 링크 체인의 기존 해석과 실제 설치 루트 선택은 유지합니다.
- 문자열 없는 상한 초과 숫자/불리언 JSON의 보수적 복귀에서 항등 변환과 큰 인자 복사를 줄입니다. 해당 ASCII 구간에만 C locale을 적용한 뒤 이전 값과 set/unset 상태를 복원합니다. 기존 327680-byte 상한, 구조·숫자 치환 기대값, 20초 조건을 유지합니다.
- 버전 확인 자식이 이미 종료됐는데 부모 처리가 지연되면 watchdog이 늦게 timeout으로 바꾸던 경합을 수정합니다. 이미 회수된 자식과 아직 회수되지 않은 zombie 상태를 구분하며, 상태 조회 실패 때는 보수적인 timeout 처리를 유지합니다. 정상 종료·실패 종료·실제 지연 자식의 전후 검사를 포함합니다. 실제로 실행 중인 scanner의 2초 제한과 open/closed 정책은 바꾸지 않습니다.
- 최초 v3.7.0 Intel 출력 불일치의 자료가 없으므로 동일 원인으로 소급 확정하지 않습니다. 후속 실제 CI에서 scanner 준비 timeout을 관측했지만, 위 경합이 모든 간헐 지연의 원인이라고 주장하지 않습니다. 공개 기준본의 진단 실패도 원시 자료에 남깁니다.

### 성능 근거와 한계

사전 실험 head `9fb3c1d`는 실제 공개 v3.7.0을 기준으로 같은 scanner·입력·설정, 실제 2CPU/1GiB/swap0에서 시작 비용 포함 9쌍 교대 측정을 수행했습니다. 두 호스트·audit 세 상태·scanner 세 종류의 378개 비교에서 독립 출력 불일치와 일반 경로 지연·CPU 5% 초과 회귀는 0이었습니다.

- stdlib 비교 빌드의 다중 문자열 목표: 지연 15.34~16.78%, CPU 13.92~15.08% 감소.
- 실제 Homebrew scanner의 같은 목표: 지연 14.07~17.05%, CPU 12.48~15.38% 감소.
- 공식 scanner의 같은 목표: 지연 2.93~5.82%, CPU 3.88~6.19% 감소. 모든 설치나 작업에 10% 개선을 주장하지 않습니다.
- Claude/Homebrew 부하 검사에서 동시 4요청 처리량은 6.02→7.34 req/s, CPU는 2.652→2.261초/8요청이었지만, 표본 RSS 합은 214.35→236.98MiB로 증가했습니다. 최대 자식 RSS와 공유 페이지를 중복 집계할 수 있는 표본 RSS 합은 구분합니다. 메모리 절감은 입증하지 않았습니다.

위 원인별 실험은 공개 redactor를 양쪽에 유지하고 prepare helper를 분리한 구성입니다. 실제 설치의 공유 core 구성도 공식/Homebrew와 audit 세 상태에서 별도로 측정하며, 독립 출력·일반 경로 회귀·Homebrew 목표 개선을 배포 관문으로 검사합니다. 숫자 fallback의 단일 진단 시간을 평균 성능으로 사용하지 않습니다. 설치 비용과 반복 사용의 손익, 실패한 후보 및 최종 설치 구성의 원시는 [상세 보고서](https://github.com/JeongJaeSoon/agent-guard/blob/codex/fused-output-evidence/bench/results/fused-output/README.ko.md)에서 구분합니다.

호환성을 깨야 할 필요성은 확인하지 못했습니다. v4.0.0을 위한 불필요한 계약 변경을 만들지 않고 선택형 기능을 v3.x에 추가합니다. 공식 scanner의 의존성 실험을 전체 설치에 적용하면 Homebrew에서 회귀하므로 scanner 일괄 교체는 계속 기각합니다.

## v3.7.1 - 2026-11-04

### 출력 복구와 진단

- jq 1.8.1처럼 깊은 JSON을 정상 종료 상태로 불완전하게 출력하는 경우, 손상된 중간 응답 대신 보존된 원본 PostToolUse 이벤트에서 복구합니다. 독립 parser가 성공하면 중첩 배열 구조를 유지하며 호스트 응답을 한 번만 출력합니다. 원본도 복구할 수 없을 때의 비밀값 없는 실패 응답은 유지합니다.
- scanner 준비 실패 경고에 `Scanner readiness: timeout.` 같은 고정 원인 코드를 추가합니다. 입력·파일 경로·scanner 원문은 포함하지 않으며 기존 시간 제한, open/closed 정책, 세션별 경고 제한을 유지합니다. timeout 코드는 실패 단계를 나타내며 간헐적 준비 지연의 근본 원인이 해결됐다는 의미는 아닙니다.
- CLI·설정·탐지·마스킹·호스트 계약과 기존 Claude/Codex 설치 방식을 유지합니다. 일반 사용자에게 Rust 또는 Go 컴파일러 설치를 요구하지 않습니다. 공개 자산의 체크섬 검증, 네 플랫폼 바이너리 선택, 셸 경로 복귀와 기존 정상 설치 보존은 v3.7.0의 계약을 유지합니다.

### 성능 실험의 범위

공식 gitleaks의 초기화 비용을 줄이는 의존성 후보를 별도 빌드하여 실제 공개 v3.7.0과 비교했습니다. 제한 자원에서 큰 개선을 확인했지만 Homebrew의 기존 backend에는 회귀가 있어 전체 설치 교체를 기각했습니다. 이 후보는 이 릴리스의 기본 scanner에 포함하지 않습니다. 실험 개선율을 v3.7.1의 사용자 성능 개선으로 해석하지 마세요. 기존 Rust 준비 후보도 목표 10% 개선에 못 미쳐 채택하지 않았습니다.

- [실험·기각 근거와 미해결 항목](https://github.com/JeongJaeSoon/agent-guard/blob/v3.7.1/bench/scanner/README.ko.md)
- [실패를 포함한 원시 측정과 체크섬](https://github.com/JeongJaeSoon/agent-guard/tree/v3.7.1/bench/results/scanner-startup)
- [검증 안내](https://github.com/JeongJaeSoon/agent-guard/blob/v3.7.1/docs/verification.ko.md)

호환성을 깨야 할 필요성은 입증되지 않았으므로 v4.0.0 전환을 추가하지 않았습니다.

## v3.7.0 - 2026-11-04

기존 CLI·설정·출력·종료 코드·마스킹 정책과 호스트 계약을 유지하면서, 검증된 문자열 치환 코어를 사전 빌드 Rust 바이너리로 제공합니다. 일반 사용자는 Rust를 설치할 필요가 없습니다. 탐지·PII·정책·호스트 어댑터는 셸에 남으며 전체 Rust 재작성이 아닙니다.

### 배포와 복구

- Linux/macOS × x64/arm64 바이너리와 SHA-256을 공개 자산 및 기존 universal archive에 포함합니다. Linux는 정적 musl이며 glibc 의존성이 없습니다. macOS 배포 대상은 14 이상이고 실제 검증 환경은 두 아키텍처 모두 macOS 15입니다. 그 밖의 OS·커널 실행까지 입증한 것으로 일반화하지 않습니다.
- 배포 아카이브와 Homebrew에서는 해당 플랫폼 바이너리의 체크섬을 확인하고 기본으로 사용합니다. 부재·손상·체크섬 불일치·실행 오류·빈/부분/복수 JSON 출력은 원래 셸/jq 경로로 복귀합니다. `AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell`은 명시적 셸 선택으로 유지합니다.
- Git marketplace 플러그인과 소스 아카이브는 바이너리가 없으므로 셸을 사용합니다. 기존 `AGENT_GUARD_RUST_CORE_BIN`으로 검증된 독립 설치의 바이너리를 지정할 수 있으며 Rust 컴파일이나 호스트 캐시 수정은 필요하지 않습니다.
- 업데이트를 기존 설치 옆에서 준비하고 검증한 뒤 같은 파일시스템에서 교체합니다. 추출·커밋·공개 링크 실패 및 INT/TERM에 대해 기존 정상 설치를 복구합니다. SIGKILL·전원 손실 때의 남은 `previous` 디렉터리 복구는 설치 안내를 따릅니다.
- 릴리스는 최종 PR head와 병합 커밋의 필수 검사 및 네 플랫폼 실제 실행·설치·성능 검증을 요구합니다. 다른 SHA의 바이너리를 발행하거나 기존 공개 자산을 덮어쓰지 않습니다.
- jq 1.6의 입력 끝 NUL 제거 때문에 `exec -- printenv`가 빈 값과 정상 값을 과도 마스킹하던 문제를 고쳤습니다. 인자 경계와 실패 시 전체 마스킹은 유지합니다.

### 측정과 범위

기본 전환 전 Linux x64의 실제 2 CPU·1 GiB·swap 없음 제한에서, 같은 입력·gitleaks 8.30.1·설정으로 시작 비용과 배포 체크섬 검증까지 포함해 측정했습니다. Claude 목표 경로 지연 22.20%·CPU 20.68%, Codex 지연 21.96%·CPU 21.06%가 개선됐고 일반 경로 지연 5% 초과 회귀는 없었습니다. 동시 작업 4개 처리량은 1.562→2.059 요청/초입니다. 이는 해당 입력·환경의 결과이며 다른 플랫폼의 성능이나 메모리 절감 입증이 아닙니다.

- [지원 조건·선택·실패 복귀](https://github.com/JeongJaeSoon/agent-guard/blob/v3.7.0/docs/native-redactor.md)
- [실측 검증 기록과 재현 방법](https://github.com/JeongJaeSoon/agent-guard/blob/v3.7.0/docs/rust-packaged-validation.ko.md)
- [새 측정 원본](https://github.com/JeongJaeSoon/agent-guard/tree/v3.7.0/bench/results/rust-packaged/qualification-30d7df8)

현재 병목만으로 호환성을 깨야 할 필요성은 입증되지 않았습니다. 영역별 후속 후보와 판단 근거를 문서화했고, 버전 번호를 위한 v4 변경은 추가하지 않았습니다.

## v3.6.15 - 2026-11-04

### 변경 사항

- **draft snapshot token 과잉 마스킹 수정**: 문서 도구의 draft 조회 결과에 들어 있는 `d<n>:` 형식의 snapshot token 을 더 이상 가리지 않고, 이 토큰을 인용한 프롬프트도 차단하지 않습니다. 다음 update 요청에 이 토큰을 그대로 보낼 수 있습니다. 면제 조건은 정확한 `snapshotToken`/`snapshot_token` 키와 해당 값 형식이 함께 맞는 경우뿐입니다. 다른 secret 키 아래의 같은 값, env 형식, 그 밖의 값 형식은 계속 가립니다. (#387)
- **Rust 배포 후보 CI**: 네 플랫폼에서 Rust 바이너리를 빌드하고 실제로 실행해 확인하는 CI 를 추가했습니다. 일반 설치 경로는 바뀌지 않습니다. (#388)
- **문서 정리**: 중복 검토 문서를 통합하고, 사용자·개발·측정 자료를 다시 구성했습니다. v3.6.14 발행과 설치 검증 근거를 반영했습니다. (#382)

## v3.6.14 - 2026-11-04

기본 셸 실행의 병목과 도구 호환성을 개선하고, 측정으로 효과를 확인한 Rust 문자열 치환기를 선택형 실험으로 추가했습니다. 일반 설치에 Rust 의존성이 추가되지 않으며 기본 마스킹 정책은 유지합니다.

### 변경 사항

- **셸 성능·프로세스 정리**: 중복 jq 처리와 불필요한 문자열 분할을 줄이고 watchdog 종료 시 남는 프로세스를 정리했습니다. (#377)
- **jq 1.6 과도 마스킹 수정**: NUL이 없는 정상 문자열까지 마스킹되던 판정을 수정했습니다. 실제 NUL이 포함된 값은 계속 보호합니다. (#379)
- **구형 awk 로그 보존 수정**: 반복 정규식을 지원하지 않는 awk에서도 기존 감사 로그 보존 정책이 적용됩니다. (#378)
- **shell 스크립트 인자 판정**: 단일 문자열 변수로 넘긴 스크립트 경로를 리터럴 경로와 동일하게 처리해 안전한 반복 실행의 오탐을 줄였습니다. `-c` 값은 코드로 검사하고 불명확한 값은 기존 closed 정책으로 차단합니다. (#385)
- **선택형 Rust 치환기**: 문자열 치환 단계만 Rust로 실행할 수 있습니다. 바이너리가 없거나 실행이 실패하면 기존 jq 경로로 복귀하고 부분 출력은 폐기합니다. 탐지기·정책·호스트 어댑터는 유지합니다. (#380)
- **개발 도구 Rust 이관**: Python 검증·측정·보고서 스크립트 10개를 Rust 명령으로 옮기고 Python 실행 의존성을 제거했습니다. 기존 입력·기대값·통계 동등성을 유지하며 Python 없는 Docker와 Linux/macOS 계약 검사를 추가했습니다. (#386)
- **측정·시각화**: 반복 측정 원시 데이터, 재현 명령, 한국어 그래프 HTML 보고서를 추가했습니다. (#381)
- **CI**: 같은 PR의 이전 실행만 취소하고 main·수동·릴리스 검증은 보존합니다. jq/awk·Rust 계약 검사를 관련 main 변경에도 실행합니다. HOL scanner를 v1.2.806으로 갱신했습니다. (#383, #364)

### 측정 결과와 적용 범위

최적화된 셸과 Rust를 같은 Docker 환경에서 비교한 결과입니다. 전체 CLI 실행 시간을 측정했으며 Rust 코어만의 속도와 구분했습니다.

| 측정 항목 | 최적화된 셸 | 선택형 Rust | 변화 |
| --- | ---: | ---: | ---: |
| Claude 다수 문자열 치환 지연 | 1,194.1 ms | 868.2 ms | 27.3% 감소 |
| 같은 경로 CPU 시간 | 1,236.4 ms | 910.8 ms | 26.3% 감소 |
| 동시 작업 4개 처리량 | 2.20 요청/초 | 3.08 요청/초 | 40.3% 증가 |
| 동시 작업 4개 표본 RSS 합 | 271.9 MiB | 281.9 MiB | 3.7% 증가 |

메모리 절감은 입증되지 않았습니다. Docker의 컨테이너별 CPU·메모리 제한은 해당 환경에서 적용되지 않았으며 양쪽은 동일한 상위 자원 한도를 공유했습니다. RSS 합은 표본 측정으로 공유 페이지 중복과 순간 최대치 누락 가능성이 있습니다. 이 수치를 모든 입력·운영체제나 전체 Rust 재작성의 효과로 일반화하지 않습니다.

### 호환성·검증

- 차등 검사 1,024건, jq 1.7.1/1.6 각각 호스트·복귀 검사 90건, 기존/Rust 출력 회귀 각각 1,018건, 단위 검사 201건을 통과했습니다.
- 기본 실행은 셸/jq입니다. 일반 사용자는 Rust를 설치할 필요가 없습니다. Rust 실험을 직접 빌드하는 개발자에게만 빌드 도구가 필요하며, 이 릴리스는 플랫폼별 Rust 바이너리를 배포하지 않습니다.
- 실험 활성화·복귀 동작: [native-redactor.md](https://github.com/JeongJaeSoon/agent-guard/blob/v3.6.14/docs/native-redactor.md)
- 그래프 HTML: [rust-performance.ko.html](https://github.com/JeongJaeSoon/agent-guard/blob/v3.6.14/docs/rust-performance.ko.html) (다운로드 후 브라우저에서 열기)
- [원시 측정값·검증 근거](https://github.com/JeongJaeSoon/agent-guard/tree/v3.6.14/bench/results/rust-experiment)

## v3.6.13 - 2026-11-03

- fix(scan): bare key 필드의 레코드 UUID를 generic-api-key 오탐에서 제외 (#375)

## v3.6.12 - 2026-11-02

- fix(hooks): grep/rg 검색 패턴과 새 openssl 출력 경로를 보호 경로 검사에서 제외 (#373)
- fix(hooks): jq filter field names no longer trip the protected-path check (#372)
- docs: 영어 정본을 유지하고 한국어·일본어 안내 추가 (#369)
- docs: 직접 계약 테스트 목록과 Makefile 도움말 정합성 정리 (#362)

## v3.6.11 - 2026-10-30

- fix(hooks): resolve commit and push in compound Bash commands (#367)

## v3.6.10 - 2026-10-30

- fix(prompt-guard): make blocked injected messages recoverable (#365)

## v3.6.9 - 2026-10-28

- perf(masking): streamline framing and reuse redaction plans (#360)
- perf(ci): parallelize navigation by host contract (#361)
- perf(hooks): reuse the gitleaks readiness verdict across hook processes (#359)

## v3.6.8 - 2026-10-27

- fix(hooks): stop reading inert here-documents and plain-word git arguments as unknown code (#357)
- Merge pull request #340 from JeongJaeSoon/codex/status-label-test-layers
- Merge remote-tracking branch 'origin/main' into codex/local-chain-integration-20261024
- Merge pull request #339 from JeongJaeSoon/codex/test-coverage-boundary
- Merge branch 'codex/local-339-integration-20261024' into codex/local-chain-integration-20261024
- test: revalidate selected locations after detector updates
- test: revalidate selected locations after detector updates
- Merge commit '0fb9d6cc2a017d57751aebe728ecf7ba72e832dd' into codex/local-chain-integration-20261024
- Merge remote-tracking branch 'origin/main' into codex/local-chain-integration-20261024
- Merge branch 'codex/test-coverage-boundary' into codex/status-label-test-layers
- docs: date the recorded coverage observation
- test: reject decision fields in fail-open prompt notices
- Merge branch 'codex/exec-raw-probe-failure' into codex/test-coverage-boundary
- Merge branch 'codex/test-coverage-boundary' into codex/status-label-test-layers
- test: assert failure diagnostics do not expose fixture secrets
- test: move status-label variants to direct classification contracts
- test: document layers and guard exec framing failures

## v3.6.7 - 2026-10-23

- fix(hooks): stop over-masking booleans, page cursors and short multibyte words (#353)
- ci: suite job の timeout を 25 分に上げる (#355)
- fix(hooks): resolve command variables in any locale, after closed parens and before builtin-named arguments (#354)

## v3.6.6 - 2026-10-23

- fix(hooks): resolve a literal command variable in the git gate (#351)
- fix(hooks): treat a bracket as a non-boundary before a spanning star (#350)
- fix: Claude の PreToolUse hook が timeout・crash したら tool 呼び出しをブロックする (#349)
- fix: inspect quoted substitutions and honor GIT_DIR in the git gate (#346)
- Merge pull request #337 from JeongJaeSoon/codex/exec-raw-probe-failure
- Merge pull request #336 from JeongJaeSoon/codex/prompt-assignment-failure-policy
- Merge branch 'codex/prompt-assignment-failure-policy' into codex/exec-raw-probe-failure
- Merge remote-tracking branch 'origin/main' into codex/prompt-assignment-failure-policy
- fix: fail closed on exec raw probe errors
- test: name synthetic assignment fixture explicitly
- fix: preserve prompt assignment probe failures

## v3.6.5 - 2026-10-22

- fix: only treat unquoted names as assignments in the git gate (#345)
- fix: follow an unquoted tilde cd target to HOME in the git gate (#344)
- fix: require a pinned letter for one-character star stand-ins in Bash path text (#343)
- test: add direct probe eligibility contracts (#335)
- perf: avoid per-character subshells in deny-path regex construction (#334)
- test: consolidate duplicated function extraction setup (#333)
- test: cover framing producer byte and failure contracts (#332)
- docs: document test layers and scoped source coverage (#329)
- test: add fast version and shell quoting contracts (#331)
- Merge pull request #327 from JeongJaeSoon/codex/ci-runtime-balance
- ci: preserve OS temporary root for permission regression fixtures
- docs: clarify preserved regression assertions and matrix check
- ci: run isolated test partitions on bounded worker bundles
- Merge remote-tracking branch 'origin/main' into codex/ci-runtime-balance
- ci: balance output coverage against latest baseline
- ci: balance test work and name suites by coverage

## v3.6.4 - 2026-10-17

- ci: bump hashgraph-online/ai-plugin-scanner-action (#312)
- fix(hooks): explain every closed block from the manifest resolver (#325)

## v3.6.3 - 2026-10-16

- ci: remove unused scanner setup and simplify validation output (#320)
- fix(pii): keep UTF-8 text out of byte-window regex matching (#322)
- fix(detection): allow source-module mentions in static prose (#321)
- fix(hooks): closed モードの遮断で毎回理由を返し、case の subject をコマンド扱いしない (#318)
- perf(redaction): avoid quadratic assembly of complete framed leaves (#323)

## v3.6.2 - 2026-10-15

- fix(detection): stop the cwd re-parse from recursing on blankless words (#316)
- fix(detection): keep env source modules readable after one static cwd change (#313)

## v3.6.1 - 2026-10-12

- MCP token 키의 `v:<n>` 버전 핸들을 불필요하게 마스킹하지 않도록 수정했습니다 (#309).
- 릴리스 발행 후 Homebrew tap 갱신 PR을 자동 생성하며, 같은 formula와 열린 PR은 재사용합니다 (#310).
- HOL 플러그인 스캐너 Action을 업데이트했습니다 (#302).

## v3.6.0 - 2026-10-11

- feat(hooks): show values the mask allow list names in the masked view (#307)
- feat(hooks): mask deny-value rule matches in the masked view (#306)
- feat(hooks): return a masked view in the block reason of a protected read (#305)
- feat(cli): add mask-file, a masked view of json, yaml, ini and dotenv files (#304)
- docs: add a sponsor line to the README (#301)

## Unreleased

- feat(hooks): in `AGENT_GUARD_DENY_READ_MODE=mask`, values whose key path matches a rule in `~/.config/agent-guard/mask-allow-keys.txt` are shown; the file must sit outside the work tree and the working directory and be private to the user, no variable can supply rules, deny-value rules and the secret scanner still win, and any refused rule or failed check keeps every value masked with a warning
- feat(hooks): in `AGENT_GUARD_DENY_READ_MODE=mask`, deny-value rules from `~/.config/agent-guard/mask-deny-values.txt` and the file `AGENT_GUARD_MASK_DENY_VALUES` names, together, replace every match with `[MASKED]`, comments included; a refused or unreadable rule, a match in a key, or a rule that runs out of time blocks with no view
- feat(hooks): `AGENT_GUARD_DENY_READ_MODE=mask` keeps blocking reads of protected files and puts a masked view of the file in the block reason for a `Read` or a plain `cat PATH`; the view is rescanned, capped at 6,144 bytes, and any failure blocks with no view
- fix(hooks): a `~/` path no longer normalizes to `$HOME/~/...`
- feat(cli): add `mask-file`, which prints a json, yaml, ini or dotenv file with its values replaced by `[MASKED]` and fails closed on anything else; `.envrc` and `*.envrc` are not supported because a shell, not a dotenv reader, reads them

## v3.5.6 - 2026-10-04

- fix(hooks): give Claude Code the block reason as JSON and stop echoing blocked prompts (#299)

## v3.5.5 - 2026-10-04

- chore: match the Action branding color to the new icon (#296)
- docs: record the demo GIF inside Claude Code (#295)
- chore(plugin): match the Codex brand color to the new icon (#293)
- docs: add the Agent Guard icon and a centered README header (#292)
- docs: re-record the demo GIF against the current CLI (#291)
- chore: add GitHub Sponsors funding link (#290)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#289)
- refactor: clean up stale comments, dead branches and drifted docs (#288)

## v3.5.4 - 2026-09-27

- fix(hooks): scan the git commit or push a git alias expands to (#286)
- test: move the shell cd tests from shard 3 to shard 4 (#285)

## v3.5.3 - 2026-09-25

- fix(hooks): check shell -c, eval and split words that hide a git commit (#283)

## v3.5.2 - 2026-09-25

- fix(hooks): scan the repository a shell cd moves git commit and push into (#276)

## v3.5.1 - 2026-09-25

- fix(hooks): decode ANSI-C quoted words before the Bash path check (#279)
- fix(hooks): let one star span several characters of a deny-read entry (#278)
- ci(test): shard tests/run.sh across a five-way CI matrix (#277)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#274)
- fix(hooks): scan changes git commit -a and pathspecs stage themselves (#275)
- docs(readme): highlight commit and push secret blocking (#273)

## v3.5.0 - 2026-09-21

- docs: remove maintainer-only documents and keep user-facing docs in English (#271)
- docs(boundaries): record function hooks (Claude Mods) compatibility probe (#270)
- fix(scan): bound git diff stderr capture at the source (#269)
- feat(scan): add AGENT_GUARD_SCAN_INPUT_MAX_BYTES and bound git diff stderr (#268)
- fix(plugin): make plugin update legible and report release staleness (#267)

## v3.4.5 - 2026-09-20

- fix: classify git diff scan-limit truncation as a size limit, not a git failure (#263)

## v3.4.4 - 2026-09-17

- fix(release): require reviewed two-phase publishing (#257)

## v3.4.3 - 2026-09-17

- ci: HOL plugin scanner action을 v1.2.678로 업데이트 (#250)
- fix: untracked 입력 상한의 SIGPIPE 오분류 수정 (#255)
- docs: 출력 마스킹 범위와 host 가정 명시 (#254)
- fix: expand Claude post-tool matchers (#253)
- fix: make gitleaks resolution deterministic (#252)
- fix: close post-tool masking fail-open paths (#251)
- fix(verification): Tie the live post-tool probe to an audit run ID and make the verification procedure self-contained (#244)

## v3.4.2 - 2026-09-14

- fix(redaction): keep content-block discriminators and pass image/PDF blocks through the output guard (#239)
- docs: support Homebrew 6 release checks (#237)

## v3.4.1 - 2026-09-11

- fix: preserve exact documentation placeholders (#235)
- Separate public and internal rollout documentation (#234)
- Add safe support log file export (#233)
- Add CLI-managed Claude and Codex plugin lifecycle (#232)

## v3.4.0 - 2026-09-11

- Prepare safe internal rollout, support logs, and portable installs (#230)

## v3.3.0 - 2026-09-10

- `PostToolUse` now scans the file a write tool just targeted, so a secret written to a gitignored path, outside the repository, into a *different* repository, or into a `skip-worktree` / `assume-unchanged` file is caught. Those were blind spots before: the working-tree backstop skips all of them (#221, #228).
- `scan-working-tree`, and therefore `/agent-guard:verify`, now covers the index as well as the worktree, both diffed against `HEAD`. Staging a secret and then restoring the file on disk no longer hides it. Content that only differs from the index — a committed secret whose staged removal is undone on disk — is still not reported, because only lines added relative to `HEAD` count (#225).
- Tier-2 PII detection (credit card, US SSN, Korean resident registration number) now requires digit boundaries and a valid Luhn checksum. Epoch-nanosecond timestamps, snowflake-style ids and other long digit runs are no longer read as card numbers, and IPv4 masking rejects out-of-range octets. `AGENT_GUARD_PII_HOOK_MODE=mask` hard-blocks Tier-2 on tool input, so this is what makes that mode usable (#217).
- New `AGENT_GUARD_PII_SKIP` turns individual **Tier-1** types (`EMAIL`, `PHONE`, `IP_ADDRESS`) off — useful when IPv4 masking hides what you are debugging. A skipped type stops being PII entirely, so `block` mode also stops blocking it; the switch is not output-only. Tier-2 names and unknown names are refused with exit 2, and it requires the built-in `regex` provider (#219).
- A Bash path block now names the `deny-read-paths` entry that matched and suggests a non-path-shaped rewrite, instead of only reporting `reason=bash_protected_path_text_match`. The gate still fails closed and no verdict changed; the matched command excerpt is deliberately not echoed, so an authenticated URL in the command cannot reach the transcript through the diagnostic (#220).
- Documentation now matches the code: `/agent-guard:verify`'s scan scope, why gitignored paths are excluded from it, how to distribute policy environment variables through managed settings and verify the value actually took effect, and what Codex managed configuration does and does not offer (#218, #222).

Existing installations need no new setup step: update the plugin and restart the session. In Codex, re-trust the hooks in **Settings > Hooks** after the update, as with any plugin change. `AGENT_GUARD_PII_HOOK_MODE` remains `off` by default; see the README before enabling it, since Tier-2 hard-blocks tool input and a small residual false-positive class remains.

## v3.2.0 - 2026-09-06

- Add an experimental, explicitly enabled pleno-anonymize PII provider with strict response validation. Remote processing remains off by default.
- Preserve standalone executable links during updates, including legacy payload directory aliases.
- Prefer the selected healthy shell cache and reject incomplete or redirected cache payloads. Existing shell integrations should rerun setup-shell after updating.
- Report unavailable direct scans with exit code 3 while preserving fail-closed execution behavior.
- Explain ambiguous Bash protected-path matches without weakening protection. Inline source expressions can still match the conservative path gate.
- Limit the setup skill to explicit invocation and clarify what host dispatch, policy denial, dependency failures, and unobserved execution can establish.
- Clean up GitHub Action scanner downloads after success, failure, and interruption.
- Reject malformed or multiple remote PII response objects and avoid echoing endpoint details in provider failures.

Use the README for installation, optional PII configuration, shell integration, and troubleshooting.

## v3.1.1 - 2026-09-04

- feat: harden multi-host installation and release flow
- fix(detection): exempt the Grep content pattern from the deny-path gate (#188)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#189)
- docs: document strict Bash path matching (#185)
- fix(redaction): mask quoted line-start assignments (#184)

## v3.1.0 - 2026-08-31

- fix: address post-merge hook regressions (#182)
- fix(redaction): accept a carriage return as an assignment delimiter (#181)
- fix(redaction): mask a KEY=value assignment inside a quoted string leaf (#179)
- fix(redaction): close the status-label display leak (#177)
- ci: remove the codex-review workflow (#176)
- feat(hooks): UserPromptSubmit prompt guard — block pasted secrets on both hosts (#173)
- feat(detection): block package-manager credential leak vectors (#172)
- fix(redaction): gate display masking on the value shape (#171)
- fix(detection): allow env source modules with an intermediate segment (#170)
- fix(setup-shell): support a fish login shell in setup and detection (#155)
- ci: bump openai/codex-action from 1.11 to 1.12 (#174)
- ci: bump hashgraph-online/ai-plugin-scanner-action from 1.2.514 to 1.2.533 (#175)
- fix(redaction): enforce short-value probe eligibility (#163)
- fix(pii): validate regex and experimental http adapters (#154)
- fix(hooks): prefix the Claude setup-skill invocation with a slash (#151)
- feat(shell)!: remove 1.x bang-guard compat flags; fail loud on unknown args (#167)
- refactor(hooks): render hook manifests from one template; dedup inline helpers (#166)
- chore(ci): cap job runtime on merge-gating workflows (#165)
- refactor(hosts): keep host-specific surfaces in sync with generic logic (#164)
- Merge pull request #161 from JeongJaeSoon/codex/env-template-filename-policy
- fix(detection): detect path-qualified cwd wrappers
- fix(detection): guard reevaluated template paths
- Merge remote-tracking branch 'origin/main' into codex/env-template-filename-policy
- Merge pull request #162 from JeongJaeSoon/codex/submission-artifact-lifecycle
- docs(submission): repin shell re-evaluation guard
- fix(detection): keep re-evaluated tokens guarded
- docs(submission): repin env template fix
- fix(detection): reject dynamic env template tokens
- fix(submission): require reviewed remote inputs
- chore(submission): repin merged env template payload
- Merge remote-tracking branch 'origin/main' into codex/env-template-filename-policy
- chore(submission): repin hardened env template payload
- fix(detection): preserve env template deny boundaries
- refactor(submission): render catalog pin after merge
- Merge pull request #153 from JeongJaeSoon/fix/display-redaction-chained-colon-labels
- chore(submission): repin env template payload
- fix(detection): handle env template filenames safely
- chore(submission): re-pin reviewed plugin payload
- Merge remote-tracking branch 'origin/main' into fix/display-redaction-chained-colon-labels
- Merge pull request #160 from JeongJaeSoon/codex/p1-invalid-toml-escape
- chore(submission): re-pin reviewed plugin payload
- fix(lockfiles): handle TOML escape boundaries
- chore(submission): re-pin reviewed plugin payload
- fix(lockfiles): reject invalid TOML escapes
- Merge pull request #157 from JeongJaeSoon/codex/p2-escaped-quote-redaction
- chore(submission): re-pin reviewed plugin payload
- test(exec): cover trailing printenv values
- fix(redaction): bound trailing printenv values
- test(exec): clarify large fixture indirection
- chore(submission): re-pin reviewed plugin payload
- test(exec): cover repeated large printenv values
- fix(redaction): bound printenv output modeling
- test(exec): keep high-cardinality probe single-shot
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): fail closed on printenv metadata
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): preserve bounded exec masking
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): guarantee whole-output fallback
- chore(submission): re-pin reviewed plugin payload
- perf(redaction): preflight oversized output
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): bound gitleaks output scanning
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): fail closed on raw temp errors
- chore(submission): re-pin reviewed plugin payload
- perf(redaction): fast-path framed assignment probes
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): fail closed across bounded output paths
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): bound all detector records
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): stream large hook output into jq
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): bound high-cardinality output work
- Merge origin/main into codex/p2-escaped-quote-redaction
- Merge pull request #159 from JeongJaeSoon/codex/p1-lockfile-same-line-secrets
- chore(submission): re-pin reviewed plugin payload
- fix(detection): reject incomplete TOML state
- chore(submission): re-pin reviewed plugin payload
- fix(detection): reject malformed checksum tails
- chore(submission): re-pin reviewed plugin payload
- fix(detection): reject incomplete TOML filtering
- chore(submission): re-pin reviewed plugin payload
- fix(detection): preserve binary lockfile bytes
- Merge remote-tracking branch 'origin/main' into codex/p1-lockfile-same-line-secrets
- ci: bump hashgraph-online/ai-plugin-scanner-action (#147)
- ci: bump actions/checkout from 7.0.0 to 7.0.1 (#146)
- chore(ci): re-pin marketplace .source.sha and verify linter download checksums (#152)
- fix(detection): validate package-lock snapshots
- fix(detection): scope structural lockfile hashes
- test: assemble shared redaction fixture safely
- fix(detection): scan context-free lockfile fragments
- fix: redact short punctuated secrets safely
- fix: preserve byte-exact output redaction
- test: clarify printenv fixture indirection
- fix: preserve exact exec redaction output
- fix: redact multiline secrets per output leaf
- fix(detection): parse structural lockfile fields
- test(redact): construct secret fixtures at runtime
- fix(detection): scan beside lockfile checksums
- fix(redact): mask through escaped quotes
- fix(redact): mask secrets behind non-status colon labels
- fix(detection): narrow lockfile checksums and output redaction (#145)
- fix(runtime): keep Agent Guard stable across plugin upgrades (#143)
- fix(security): scan-accuracy + shell-parsing hardening batch (#125-#134)
- Add a host-neutral setup-shell workflow for Codex (#144)

## v3.0.1 - 2026-07-22

- fix: handle sandboxed Agent Guard setup (#141)
- docs: surface the setup skill as a Claude Code entry point (#135)
- fix(hooks): report a scan that could not run distinctly from a detection (#137)
- fix(security): close verified scan bypasses + finish v3.0.0 release (#124)

## Unreleased

- fix(hooks): treat malformed `UserPromptSubmit` JSON as an infrastructure
  failure instead of collapsing a failed `jq` extraction into an empty prompt.
  The opt-in closed policy now blocks; the default open policy emits one
  host-shaped degradation notice.
- fix(shell): when SessionStart still receives a fish `$SHELL`, require both
  `.bashrc` and `.zshrc` managed blocks to remain loadable. The host snapshot may
  choose either shell, so one surviving rc can no longer silence the warning
  while the other snapshot path is unprotected.
- fix(redaction): limit the `:` equals-assignment delimiter to the quoted string
  leaf it was added for. Serialized output such as
  `{"log":"API_KEY=<value>"}` still masks, while valid compact source such as
  the JavaScript labelled statement `label:API_KEY=config.apiKey;` is preserved
  on display and accepted by the prompt guard.
- fix(redaction): accept a carriage return as an assignment delimiter. A `\r`
  before the key hid the assignment completely, on display and at the prompt
  guard, so a secret printed after a progress meter, a spinner, or on
  classic-Mac line endings reached the model in full and was not blocked when
  pasted back:

  ```
    0 12.3M    0 16384    0     0  50000      0\rAPI_KEY=<secret>   ->  no rewrite
  ```

  `\r` is a delimiter for the same reason it is edge whitespace on the value
  side: it separates fields on screen and belongs to neither. It joins the
  leading class of both assignment forms and of the status-label test, so the
  prose chain the status allowlist protects (`error: password: authentication
  is disabled`) is now recognised after a carriage return too — previously the
  label went unseen there and the prose was masked. Measured against the
  previous release commit over 2,518 carriage-return shapes: 357 real leaks
  closed, 6 false-positive prose masks removed, and every other newly masked
  case byte-identical to what that commit already produced with a space in the
  same position. The status guard in `scan_line` tests the delimiter character
  directly and had to agree: with the carriage return between the label and the
  key (`error:\rpassword: <prose>`) the colon assignment matches at the CR, and
  while that check accepted only space and tab the label went unrecognised and
  the prose was masked.
- fix(redaction): mask a `KEY=value` assignment inside a quoted string leaf
  (#178). The ordinary shape of a tool that returns a serialized log —
  `{"log":"starting with API_KEY=<value>"}` — reached the model in full on the
  heuristic path. Two causes, both needed. The enclosing string's own closing
  quote rode along on the value token, and `looks_like_reference()` tests for an
  embedded quote without position, so a terminator at the very end marked the
  token a nested reference and skipped it; a single trailing quote is now
  stripped the way trailing `}`/`]`/`)` already were, and only when the
  assignment does not itself begin with a quote, so the line-start re-scan of a
  value an outer quoted assignment already claimed cannot emit a narrower
  mapping that beats it. And `:` was not accepted as the delimiter before a
  quoted key, so the JSON form never matched at all — it joins the class away
  from `[`, since `[:` opens a POSIX character class and invalidates the whole
  regex. Credential-handling source code is unchanged: `os.environ["DB_PASSWORD"]`
  and `ENV.fetch("SESSION_KEY")` keep interior quotes and stay references.
  Display redaction and the prompt guard; the block/detect path is unchanged.
  The strip stops at the redaction sentinel: `password=[REDACTED]"` would
  otherwise lose the `]` that belongs to the marker, so `[REDACTED` was
  re-emitted as a secret and a stray `]` appended — compounding on every pass
  and making the prompt guard block text Agent Guard had itself redacted.
  A trailing carriage return is skipped as edge whitespace, so CRLF output —
  Windows tools, PowerShell, Docker and CI logs — masks the same shape it
  does on LF; the carriage return itself is preserved.
- fix(redaction): close the status-label display-redaction leak (#156). The
  seven-word status allowlist (`error`, `warning`, `info`, `note`, `debug`,
  `fatal`, `hint`) let a secret that gitleaks does not recognise reach the model
  unmasked whenever it sat behind one of those labels — `error: password:
  <value>` and `warning: db_password: <value>` were displayed in full. The label
  cannot settle it, because it is identical in the prose chain the allowlist
  exists to protect (`error: password: authentication is disabled`), so the
  VALUE now decides: a token whose shape reads as a credential (a digit beside a
  letter, an uppercase run starting past the first character, or a single-case
  alphabetic run longer than any ordinary word) masks, while a word, path,
  number, clock time or date stays visible. The chained shape
  (`response: error: api_key: <value>`) is covered by the same gate. Display
  redaction only; the block/detect path is unchanged. An unterminated quoted
  value (truncated output) is captured and classified when the leaf ends rather
  than skipped, so a credential-shaped one still masks. A captured value is recorded in
  both its literal and its edge-trimmed form, so a bare recurrence of a
  credential that was padded or split across a newline behind its label
  masks as well. Residual: an
  all-lowercase alphabetic secret shorter than 24 characters is indistinguishable
  from a prose word on this path and stays visible.
- docs: record why the deny-read Bash gate is NOT narrowed (#99). `echo
  foo.key`, `echo see also foo.pem` and `jq -r .key data.json` are reported as
  `blocked shell command referencing a deny-listed path` although nothing is
  read and no such file exists. A command-position narrowing that dropped word
  operands of commands which take no file operands was written, measured and
  removed again: every revision of it let a real read through. A newline or `&`
  starts another command, `|` hands the dropped word to `xargs cat`, a path- or
  quote-qualified name resolves to a different program than the one compared, an
  external binary resolves through PATH at execution time so a wrapper inherits
  the exception, and an exported Bash function named `echo` or `printf` beats
  the builtin — so even a builtin name does not identify what will run. A text
  gate that cannot name the program cannot safely drop its operands. #99 stays
  open as an accepted false positive; the counter-examples are pinned as tests
  so any re-attempt has to answer them.
- fix(hooks): drop the undefined `\"` escape from the shell-parser awk bracket
  expression (#99). gawk warned `regexp escape sequence \" is not a known
  regexp operator` on every `hook-pre-tool` run, including runs that passed. The
  class already contains a literal backslash via `\\`, so it is unchanged.
- ci: remove the `codex-review` workflow. It has never produced a review in
  this repository: with no `OPENAI_API_KEY` Actions secret every step is
  skipped, the job reports success in a few seconds, and the feedback job is
  skipped for an empty message — so it read as a passing check while doing
  nothing. Codex review on pull requests comes from the ChatGPT Codex GitHub
  app and is unaffected. Dropping the workflow also stops Dependabot raising
  version bumps for an action that never runs; the README section documenting
  it is removed with it.
- feat(detection): extend the env template marker vocabulary with `tpl`/`tmpl`
  and accept `-`/`_` marker separators (`.env-example`, `.env_sample`,
  `.env.tpl`), matching the naming conventions measured on GitHub. The marker
  must still be final and the stem must stay an env family; `.env.default(s)`
  stays blocked because dotenv-defaults loads it at runtime.
- fix(detection): allow env source modules that carry exactly one intermediate
  segment between the `env`/`envrc` stem and a code extension, so ordinary
  committed files such as `env.d.ts`, `env.server.ts`, `env.config.ts`, and `env.spec.ts`
  are readable on both the Read and Bash gates. The final extension must still
  be code: data/config suffixes (`env.json`, `env.local.json`), extension-less
  names (`env.d`), the leading-dot runtime form (`.env.d.ts`), deny-listed
  ancestors, and custom deny policies all stay authoritative.
- feat(detection): block package-manager credential leak vectors. Deny-read now
  covers Bundler (`.bundle/config`), RubyGems (`.gem/credentials` and the XDG
  `gem/credentials` location), Cargo (`.cargo/credentials*`), Composer home
  `auth.json`, Maven `.m2/settings.xml`, Gradle `.gradle/gradle.properties`,
  `pip.conf`, Poetry `pypoetry/auth.toml`, and Terraform CLI credentials
  (`.terraformrc`/`terraform.rc`). Deny-bash now blocks credential dump
  commands that print stored auth with no path or token in the command text:
  `bundle config` reads (bare/`list`/`get`/legacy dotted-key read; `set` stays
  allowed and is gitleaks-scanned), `npm config get` of protected keys,
  `yarn config get` of npmAuthToken/npmAuthIdent (and the registry/scope maps
  that nest them), `git credential fill`/any-helper `get`, `pip config
  list|get`, `composer config` on credential keys or `--list`,
  `mvn help:effective-settings -DshowPasswords`, and
  `security find-(generic|internet)-password`; `gcloud auth
  print-refresh-token` joins the existing gcloud token alternation. The
  command patterns are hardened against realistic variants an agent may emit:
  tool aliases (`bundler`, `npm c`/`npm get`), version-suffixed binaries
  (`pip3.12`), leading global options between a binary and its subcommand
  (`npm --location=user config get`, `bundle config --parseable`,
  `bundle --verbose config`, `security -q`, `gcloud --quiet`), Composer's
  documented `global <command>` wrapper, which runs the same config read
  against COMPOSER_HOME where the stored OAuth token lives
  (`composer global config`), wrapper/PHAR invocation forms (`./mvnw`,
  `php composer.phar`), the direct `git-credential-<helper> get` executable,
  `pip config debug`, and `$(...)` subshell prefixes; pnpm `config list`
  (which, unlike npm, does not mask) is blocked, and coverage extends to
  pnpm/bun. The `mvn` and `composer` patterns are anchored so prose/filenames,
  value tokens like `repositories.bearer`, and the `showPasswords=false` safe
  default do not over-block. Adds deny-read for Bun's `.bunfig.toml`; uv and
  pnpm need no new path (env/.netrc and `.npmrc` respectively already cover
  them).
- feat(hooks): add a `UserPromptSubmit` prompt guard on both hosts. Secrets
  pasted into the user prompt (gitleaks rules or `KEY=value` assignment
  heuristic) are blocked before submission by default.
  `AGENT_GUARD_PROMPT_GUARD_MODE` selects `block` (default), `mask` (reserved;
  degrades to block because neither host lets a hook rewrite the submitted
  prompt), `warn` (pass through with a host-shaped visible notice), or `off`.
  The PII input gate (`AGENT_GUARD_PII_HOOK_MODE`) applies to prompts
  independently of the secret mode, and an invalid PII mode now fails loud on
  the prompt path too. `read_stdin` uses `cat` when available and prompts over
  the shared scan cap skip the super-linear assignment probe (gitleaks still
  applies; the skip follows `AGENT_GUARD_INFRA_FAILURE_MODE`), so a large
  pasted prompt cannot burn the host hook timeout into a silent fail-open.
  A prompt-path infrastructure notice is folded into the same response object
  as the mode-specific message: a hook may write only one top-level JSON
  document, and emitting the notice separately left two concatenated objects
  that a host parsing stdout as one document rejects, dropping the warning.
  The privacy policy now discloses that with the experimental
  `AGENT_GUARD_PII_PROVIDER=http` adapter in `AGENT_GUARD_PII_HOOK_MODE=block`,
  the complete text of every submitted prompt — not just tool-input text —
  is sent to `AGENT_GUARD_PII_REDACT_URL`.

- fix(detection): allow explicitly named env templates such as `sample.env`,
  `example.envrc`, `.flaskenv.example`, and `.dev.vars.example`, while blocking
  reverse/runtime forms including `local.env`, `env.local`, `env.preview`, and
  template-looking names whose final suffix is a runtime or backup marker;
  preserve custom/non-environment deny precedence and deny-listed ancestors,
  accept safely quoted Bash template paths, and keep source modules such as
  `config.env.ts` readable without opening `schema.env.json` data files.
- fix(runtime): keep plugin hooks and Claude shell integration on the
  version-independent `current/bin/agent-guard` path. Each plugin execution
  refreshes `current`, while hook and shell entrypoints fall back to the newest
  installed semantic version when symlinks are unavailable.
- test(hooks): lock in commit/push staged scans from the tool payload's target
  work directory, including linked worktrees and hook processes launched from
  a different sandbox cwd, so stale-runtime regressions cannot reintroduce the
  Codex block.
- fix(runtime): unify scanner-infrastructure failures behind
  `AGENT_GUARD_INFRA_FAILURE_MODE=open|closed` (default `open`). Hooks, `agx`,
  and transparent Claude command wrapping now warn once per session and follow
  the same selected policy; actual secret detections still always block.
- fix(detection): allow recognized checksum fields in `go.sum`,
  `package-lock.json`, `yarn.lock`, `Cargo.lock`, and `uv.lock` only when both
  the lockfile path and checksum-line shape match. Other lockfile content,
  including embedded credentials, remains scannable.
- fix(redaction): mask only the value token of a complete secret-bearing
  assignment. Metadata keys such as `password_policy`, prose such as
  `error: password: ...`, and text adjacent to a real value are preserved.
  Suffix-qualified credential keys (`AWS_SECRET_ACCESS_KEY_ID`,
  `API_KEY_VALUE`, `DB_PASSWORD_HASH`) and whitespace-prefixed colon
  assignments in log lines still mask.
- fix(pii): make the accepted PII provider values explicit (#52).

  `regex` remains the supported, local default. `http` is an experimental
  bring-your-own-endpoint adapter with no service-specific compatibility
  guarantee. Any other value fails closed instead of falling through to
  pass-through output. Existing endpoint-backed configurations that fail
  provider validation should set `AGENT_GUARD_PII_PROVIDER=http` and keep their
  existing `AGENT_GUARD_PII_REDACT_URL`. Rejected values are now reported
  exactly once.

- fix(hooks): prefix the Claude Code setup-skill invocation with a slash
  (#151). The degraded-session warning told Claude Code users to run
  `agent-guard:setup-agent-guard`; pasted verbatim that is ordinary prompt
  text, not a skill invocation. Claude Code exposes a plugin skill on the
  slash-command surface as `/plugin:skill`, which is how this plugin already
  writes its sibling skill `/agent-guard:setup-shell`. The degraded message
  and every Claude-facing doc reference now use `/agent-guard:setup-agent-guard`.
  The Codex form `$setup-agent-guard` is unchanged.

- fix(setup-shell): support a fish login shell and stop the permanent
  "command wrapping is not loaded" false positive (#139). The marker
  `AGENT_GUARD_SHELL_INIT_VERSION` only reaches `SessionStart` through the
  environment of the shell that *launched* the agent, so a fish (or other
  non-POSIX) login shell — and any GUI/IDE launcher — could never satisfy it,
  even though the agent's own bash/zsh shell snapshot did load the wrapping from
  the same rc. `SessionStart` now reads the managed rc block on disk before
  reporting missing setup, and checks that it can still *load* — the delimiters
  alone prove nothing, because the block's `eval` emits neither the wrapping nor
  the marker once the binary it resolves is gone. It replays the block's own
  resolution order (baked stable path, newest versioned plugin-cache binary,
  `agent-guard` on `$PATH`) with `stat`-level checks only: silent when setup
  demonstrably ran and still resolves (only the version-drift comparison is
  lost), the usual setup guidance when the block is absent, and a distinct
  `can no longer load` warning when the block is present but resolves nothing
  (cache updated, uninstalled, hand-edited) — that state leaves command output
  unmasked, so it must never be silent. `setup-shell` additionally writes the
  managed block to **both** `~/.bashrc` and `~/.zshrc` when either the process
  `$SHELL` or the account login shell is fish. Account lookup uses `getent
  passwd` on Linux and `dscl UserShell` on macOS, with a non-fatal process-shell
  fallback; this covers the standard skill path where Claude's Bash tool reports
  zsh even though passwd reports fish. The CLI also says plainly that no
  automatic `agx` or nudge exists at a fish prompt and prints an executable path
  for plugin-only installs where bare `agent-guard` is not on `PATH`. No
  fish-syntax marker is written or faked: claiming protection fish cannot
  provide would be worse than the warning it replaces.
- fix(hooks): report a scan that could not run distinctly from a detection
  (#137). A scanner precondition failure and a real detection previously looked
  identical — both printed and exited 2 — so an operator could not tell whether
  agent-guard had found something in their staged changes or had never managed
  to look. The message names the directory and the action instead of an internal
  subcommand; hook handling now follows the infrastructure policy above.

  CLI behaviour change: `agent-guard scan-staged` and `agent-guard
  scan-working-tree` invoked outside a git work tree now exit **3** rather than
  2. Everything in this repo treats non-zero as failure (the native pre-commit
  hook, the `make` targets, the verify command), so no consumer changes — but
  scripts that test for exactly 2 should be updated. Direct scan commands and
  native Git hooks still treat every non-zero result as uncleared.

## v3.0.0 - 2026-07-19

- feat!: simplify managed deployment to settings merge plus developer setup (#122)

Breaking changes (see the [upgrade guidance](README.md#upgrading-older-installations)):

- Removed the `managed-install.sh` entrypoint and the self-contained
  `managed-bootstrap.sh`, including the `managed-bootstrap.sh` /
  `managed-bootstrap.sh.sha256` release assets.
- Removed the Codex managed hook path (`deployment/codex-hook`,
  `deployment/codex-requirements.toml.template`); Codex users install the
  plugin through the standard install.
- Removed `setup-shell --prepend-path`.

## v2.2.0 - 2026-07-18

- feat: add self-contained managed bootstrap (#119)

## v2.1.0 - 2026-07-18

- feat: add managed deployment for Claude Code and Codex (#117)
- docs: pin community submission source (#116)
- docs: prepare Claude marketplace submission review (#115)
- docs: lead quick start with Claude Code and Codex (#54)
- ci: bump hashgraph-online/ai-plugin-scanner-action from 1.2.286 to 1.2.484 (#111)
- ci: bump openai/codex-action from 1.9 to 1.11 (#107)

## v2.0.1 - 2026-07-17

- fix(hooks): scan `NotebookEdit` cell content so secrets written to notebook cells are blocked (and PII when `AGENT_GUARD_PII_HOOK_MODE=block`) (#112)

## v2.0.0 - 2026-07-14

- feat(shell)!: make Claude command wrapping stable and default-on, with `--no-command-wrapping` and `AGENT_GUARD_COMMAND_WRAPPING=off` opt-outs
- feat(install): enable command wrapping from direct bootstrap and add `/agent-guard:setup-shell` for plugin installs
- docs: add the 1.x to 2.x migration guide and move GitHub Action examples to the preserved `v2` release line
- ci(release): verify publishing `v2` does not move the existing `v1` compatibility tag

## v1.10.1 - 2026-07-14

- fix(codex): verify the plugin-local binary, hook trust, and live host dispatch during guided setup
- fix(codex): use harmless dedicated sentinels for live PreToolUse and PostToolUse probes
- docs(codex): document wrapping-tool boundaries and require pre/post live probes
- fix(shell): mask bare `printenv NAME` values with their variable-name context

## v1.10.0 - 2026-07-13

- feat(codex): add guided dependency setup and host-native hook responses
- feat(shell): graduate the Claude bang-command guard to a supported opt-in

## v1.9.0 - 2026-07-07

- feat(plugin): warn on version drift between plugin hooks and the shell-integration CLI (#104)
- feat(bench): per-channel leak-prevention benchmark (#90)

## v1.8.0 - 2026-07-06

- feat(detection): catch low-entropy vendor-prefixed tokens by shape alone (#101)
- feat(detection): allow dotenv-style template files via suffix rule (#100)

## v1.7.1 - 2026-07-03

- fix(shell): make setup-shell rc line self-healing when the CLI leaves $PATH (#96)

## v1.7.0 - 2026-07-02

- feat(shell): resolve agent-guard without a PATH install for the bang guard (#94)

## v1.6.0 - 2026-07-02

- feat(shell): experimental opt-in bang-command guard (#92)

## v1.5.0 - 2026-07-01

- feat(shell): mask ! shell-escape output via agent-guard exec + shell-init (#86)
- feat(detection): broaden output secret recall (JWT, bearer, more env keys) (#85)

## v1.4.0 - 2026-07-01

- test: harden tests/run.sh temp files with mktemp (CWE-377) (#82)
- chore(changelog): drop stale Unreleased block ahead of v1.4.0 (#81)
- ci: bump actions/github-script from 7.1.0 to 9.0.0 (#71)
- ci: bump actions/checkout from 5.0.1 to 7.0.0 (#74)
- ci: bump openai/codex-action from 1.8 to 1.9 (#76)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#75)
- docs: document shell-escape hook-bypass blind spot (#80)
- feat(agent-guard): mask PII in tool output via mask mode (#78)
- feat(agent-guard): mask secret-like values in tool output (#77)
- docs(readme): lead with a Claude Code quick start to lift install conversion (#73)
- feat(plugin): add Codex composer icon for Agent Guard (#72)
- ci: add HOL plugin scanner self-scan and harden CI workflows (#68)

## v1.3.8 - 2026-06-16

- docs: separate demo steps with blank lines for readability (#66)
- docs: render README badges in a single row (#65)

## v1.3.7 - 2026-06-16

- feat(agent-guard): rename Action to a unique GitHub Marketplace name (#63)

## v1.3.6 - 2026-06-16

- feat(agent-guard): unify positioning + Action branding for Marketplace publish (#61)
- fix(agent-guard): close fail-open gaps in hook input handling and deny-read Bash scan (#60)
- fix(agent-guard): calibrate secret-detection patterns (#59)

## v1.3.5 - 2026-05-24

- Merge pull request #57 from JeongJaeSoon/codex/plugin-layout-validation-ci
- Normalize plugin validation workflow names
- Tighten plugin root variable validation
- Split plugin layout validation steps
- Add plugin layout validation CI
- Merge pull request #56 from JeongJaeSoon/codex/codex-claude-plugin-hooks
- Align Codex hooks with plugin layout
- Use host-specific plugin hooks
- Improve Codex and Claude plugin hook compatibility
- feat: add PII filtering provider adapters (#51)
- [codex] Harden agent tool input scanning (#49)
- [codex] Add Codex code review workflow (#55)
- fix install hook quoting and docs

## v1.3.4 - 2026-05-09

- docs: clarify codex plugin hook setup (#46)
- ci: use checkout v5 (#45)

## v1.3.3 - 2026-05-09

- fix: include install script in release tarball (#43)

## v1.3.2 - 2026-05-09

- Fix real user install and verification flows
- simplify: narrow PostToolUse matcher, dedupe deny-read path, guard gitleaks version drift (#40)
- docs: fix v1 raw URL for gitleaks-checksum.sh after plugin restructure (#39)

## v1.2.1 - 2026-05-08

- fix(cli): follow symlinks when resolving SCRIPT_DIR (#34)

## v1.2.0 - 2026-05-08

- docs: restructure README around user task flow (#32)
- feat: add gitleaks-checksum helper (script + subcommand + slash command) (#31)
- refactor: simplify bin/agent-guard helper functions (#30)

## v1.1.2 - 2026-05-07

- feat(plugin): add /agent-guard:verify slash command (#26)
- chore(release): make release.yml idempotent on re-dispatch (#25)
- fix(release): bump VERSION constant in bin/agent-guard on release (#24)

## v1.1.1 - 2026-05-07

- Revert "chore(release): v1.1.1 (#20)" (#22)
- fix(release): build tarball outside the directory being archived (#21)

## v1.1.0 - 2026-05-07

- Revert "chore(release): v1.1.0 (#15)" (#17)
- fix(release): exclude tarball self-reference from tar input (#16)

## v1.0.2 - 2026-05-07

- fix(release): pick latest semver tag, ignore moving major tag (#10)
- chore(release): also bump marketplace.json plugin version (#9)
- docs: add Quickstart section with plugin install paths (#8)

## v1.0.1 - 2026-05-07

- chore(release): add automated release workflow (#5)
- simplify: remove scan_text_hook, fix sub-shell exit, drop make doctor, optimize deny-pattern checks (#4)
- chore: usability and robustness pass (#3)
- [codex] Add CI and clean public-readiness scan noise (#2)
- Harden against Bash/path bypass, Codex patch parsing, symlink, and action injection (#1)
