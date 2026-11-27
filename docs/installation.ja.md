<!-- translated-from: docs/installation.md; source-blob: 11494d677e4a505aba57902d804171c60cbf9f15 -->

<a id="installing-agent-guard"></a>

# Agent Guardのインストール

[English](installation.md) · [한국어](installation.ko.md) · 日本語

この文書は[英語の正本](installation.md)の日本語訳です。検証の手順は[日本語の検証ガイド](verification.ja.md)を参照してください。それ以外の詳細文書は英語版にリンクしています。

Agent Guardは、一つのポリシーCLIと、Claude Code・Codex用の個別のプラグインadapterで構成されます。保護したい境界に合わせて導入方法を選んでください。

| 導入経路 | インストール | 更新 | 検証 |
| --- | --- | --- | --- |
| Claude Codeプラグイン | Claude CodeからAgent Guardのmarketplaceとプラグインを追加 | `agent-guard plugin update --host claude` を実行。新しいリリースへ移行するClaude Codeのmarketplaceコマンドを表示します。 | プラグイン内の `bin/agent-guard version` と、無害なhost経路のプローブを実行 |
| Codexプラグイン | CodexからAgent Guardのmarketplaceとプラグインを追加 | `agent-guard plugin update --host codex` を実行。新しいリリースへ移行するCodexのmarketplaceコマンドを表示します。 | プラグイン内の `bin/agent-guard version` と、無害なhost経路のプローブを実行 |
| スタンドアロンCLI | 後述のチェックサム検証付きbootstrapコマンドを使用 | `agent-guard update` | `agent-guard version`、`agent-guard doctor`、`agent-guard check` |
| Homebrew | 公開されたtapのformulaを導入 | `brew upgrade JeongJaeSoon/tap/agent-guard` | `agent-guard version` |

`PATH` 上のCLIだけではプラグインを代替できません。プラグインはClaude CodeとCodexのイベントを共通のCLI契約に変換します。スタンドアロンの導入で追加されるのはCLIと任意のshell integrationであり、hostのhookは登録しません。

スタンドアロンCLIを使わない場合は、リリースタグに固定したmarketplaceを追加し、host自身のコマンドでプラグインを導入します。`vX.Y.Z` を確認済みのリリースに置き換えてください。

```sh
claude plugin marketplace add JeongJaeSoon/agent-guard@vX.Y.Z --scope user
claude plugin install agent-guard@agent-guard --scope user

codex plugin marketplace add JeongJaeSoon/agent-guard@vX.Y.Z
codex plugin add agent-guard@agent-guard
```

プラグインを導入しても `PATH` に `agent-guard` は追加されません。表の `agent-guard plugin update` を使うにはスタンドアロンCLIかHomebrewのCLIが必要です。どちらもなければmarketplaceを削除し、新しいタグで上記のコマンドを再実行して更新してください。marketplaceの削除では、そのプラグインも削除されます。その後hostを再起動します。

プラグインだけを導入した場合は `agent-guard` が `PATH` にないため、プラグインのCLIが出す案内（例: `update`、`check`、`doctor`、SessionStartの通知）はその実行ファイルを引用符で囲んだ絶対パスで示します。例: `"$HOME/.claude/plugins/cache/agent-guard/agent-guard/current/bin/agent-guard" setup`。`PATH` 上の `agent-guard` が同じインストールである場合と、スタンドアロン・Homebrewのインストールで `PATH` に `agent-guard` がある場合は、案内はこれまでどおり短い `agent-guard` を使います。`PATH` に `agent-guard` がない状態でパスを指定して実行したスタンドアロンCLI（例: `~/.local/bin` を追加する前の `~/.agent-guard/bin/agent-guard`）も自身のパスを示します。

<a id="runtime-dependencies"></a>

<a id="optional-warm-gitleaks-helper"></a>

## 任意のwarm gitleaks helper

スキャンのたびに新しいgitleaksプロセスが起動し、その時間の大半は起動コストです。
warm helperは、コンパイル済みのgitleaks 8.30.1 detectorをユーザーと設定ごとに
1つだけメモリに保持してすべてのセッションで共有し、10分間リクエストがなければ
自ら終了します。Linux x64/arm64とmacOS arm64向けの別のリリースassetで、リリース
アーカイブ、Homebrewパッケージ、プラグインには含まれません。

`agent-guard setup --install` はgitleaksと一緒にhelperもインストールします。
使用中のgitleaksが公式のgitleaks 8.30.1リリースビルドであれば、privateディレクトリ
にあっても `PATH` にあっても、helperをダウンロードします。以前その方法でgitleaksを
インストールした場合は、`agent-guard setup --install` をもう一度実行してhelperを
取得してください。このバージョンのhelperがすでにインストールされていれば、
何もダウンロードしません。helperをダウンロードできない場合や値が一致しない場合は
警告だけを出します。gitleaksはインストールされ、コマンドは失敗しません。
それ以外のgitleaks（Homebrewビルドなどの別のビルド、別のバージョン、
`AGENT_GUARD_GITLEAKS_BIN` が選んだもの）を使っている場合は、helperを
インストールせず、理由とすべきことを1行で表示します。helperのassetがないプラットフォームでは
何も表示しません。helperを省くには、コマンドの実行時に
`AGENT_GUARD_GITLEAKS_HELPER=off` を設定してください。

helperだけをインストールするコマンドもあります。プラグイン、Homebrew、
単独インストールのいずれでも同じで、インストールできなければ失敗します。

```sh
agent-guard setup --install-gitleaks-helper
```

どちらのコマンドも、2つのバイナリがこのAgent Guardバージョンに組み込まれたSHA-256値と
どちらも一致する場合にだけhelperをインストールします。場所はprivateなgitleaks
（既定では `~/.agent-guard/bin`）の隣の `gitleaks-helper` です。インストールすると既定で
使われます。変数は不要で、実行中のhostも次のスキャンから使います。Agent Guardを
更新した後はどちらかのコマンドをもう一度実行してください。別のバージョン用にインストール
されたhelperは使われません。無効にするには次のようにします。

```sh
export AGENT_GUARD_GITLEAKS_HELPER=off
```

判定はすべて引き続きCLIが行います。helperが失敗すると実際のgitleaksを実行する
ため、失敗がクリーンなスキャンとして扱われることはありません。
`AGENT_GUARD_GITLEAKS_BIN` を設定している場合や `AGENT_GUARD_LOG_MODE=off` の場合は
helperを使いません。helperが応答するのは `agent-guard setup --install` が
インストールする公式のgitleaks 8.30.1リリースバイナリだけで、Goの `regexp` で
ビルドしたgitleaks（Homebrew、`go install`）は常に実際に実行します。
`agent-guard setup` と `agent-guard doctor` は、インストール済みのhelperが応答しない
場合に、その理由とすべきことを1行で表示します。選択されたgitleaksが別のビルドや
バージョンの場合、状態ディレクトリが深くhelperのソケットパスが103バイトを超える場合、
helperが別のAgent Guardバージョン用にインストールされた場合、上の2つの変数の
どちらかを設定している場合です。gitleaksのファイルをこのバージョンに記録された公式
ビルドのSHA-256と比較し、何も起動もインストールもしません。自分でソースから
ビルドしたものを使うには、
`AGENT_GUARD_GITLEAKS_HELPER` をその `agent-guard-scan` の絶対パスにしてください。
同じ結果の保証、失敗時の処理、メモリ、プライバシーは
[warm gitleaks helperガイド（英語）](https://github.com/JeongJaeSoon/agent-guard/blob/main/docs/gitleaks-helper.md)にあります。

## 実行時の依存関係

リリースアーカイブとHomebrewパッケージには、Linux x64/arm64とmacOS arm64用のRust文字列置換ヘルパーが含まれます。Rustコンパイラーは不要です。CLIは対象プラットフォームのチェックサムを検証したヘルパーを既定で使用し、不在や失敗時はshell/jqへ戻ります。検出・ポリシー・PII・host adapterはshellに残るため、以下の依存関係は引き続き必要です。shellを明示的に選択するには次を設定してください。

```sh
export AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell
```

Linuxヘルパーは静的muslを使うためglibcは不要で、Ubuntu 24.04で実行を検証します。macOSヘルパーのdeployment targetはmacOS 14以降で、macOS 15 arm64で検証します。Intel Mac(x86_64)には対応していません。リリースはIntel用ヘルパーを配布せず、Intelでは検証しないため、Intel環境ではshell/jqへのフォールバックを使います。スタンドアロンのインストーラーはIntelでこの案内を表示し、更新時に残っているIntel用ヘルパーを削除します。Intel用ヘルパーを含む最後のリリースは3.8.2です。そのリリースに留まるには、インストーラーを `AGENT_GUARD_VERSION=3.8.2` で実行してください。deployment targetの設定だけでは、すべての古いOS・カーネルで動作する証拠にはなりません。未対応環境ではshellへのフォールバックを維持します。配布チェックサムは破損を検出しますが、バイナリとチェックサムの両方が悪意をもって置き換えられた場合の認証にはなりません。

ソースアーカイブとhost管理のGit marketplaceプラグインにはバイナリがないため、`AGENT_GUARD_RUST_CORE_BIN` で信頼できるビルド済みヘルパーを指定しなければshellを使います。スタンドアロン版のヘルパーを使えばhostのキャッシュを編集する必要はありません。同じバージョンのスタンドアロンリリースをインストールし、そのヘルパーを検証してから、hostを起動する環境に上書き設定を追加してください。プラットフォームに合うターゲット(`x86_64-unknown-linux-musl`、`aarch64-unknown-linux-musl`、`aarch64-apple-darwin`)を選びます。次はLinux x64の例です。

```sh
target=x86_64-unknown-linux-musl
native_root="$HOME/.agent-guard/libexec"
(cd "$native_root" && shasum -a 256 -c "agent-guard-redact-$target.sha256") &&
  export AGENT_GUARD_RUST_CORE_BIN="$native_root/agent-guard-redact-$target"
```

Homebrewのヘルパーディレクトリは `$(brew --prefix agent-guard)/libexec/libexec` です。その環境でhostを再起動してください。この設定はhookを登録・置換しません。上書き値は実行可能ファイルの絶対パスである必要があり、リクエストごとにチェックサムを再確認しないため、信頼できるインストールだけを指定してください。設定を外すと同梱ヘルパーに戻り、`AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell` を設定するとネイティブ実行を無効にします。

macOSとLinuxでの実行には `sh`、`awk`、`git`、`jq`、gitleaks 8.30以降が必要です。gitleaksのバージョン確認を独立したプロセスグループで実行するため、`setsid` またはPerlも必要です。この隔離によって、確認処理の時間制限と子プロセスの後処理が可能になります。Linuxでは `sudo apt-get install -y util-linux` または `sudo dnf install -y util-linux` で `setsid` を導入してください。HomebrewのformulaはCLIとともにPerlを導入します。macOSの手動導入でどちらもない場合は `brew install perl` を使えます。

隔離ツールがないと、`agent-guard setup`、`doctor`、`check` は非ゼロの終了ステータスを返します。`setup --install` はダウンロード前に隔離ツールを確認します。ツールがなければgitleaksをダウンロードも上書きもせず、不足するツールの導入コマンドを表示します。導入後はgitleaksが十分に準備できているか再確認します。実行時のhookはこの状態を正常な検査とは扱わず、`AGENT_GUARD_INFRA_FAILURE_MODE` のポリシーを適用します。このポリシーは、秘密スキャンを実行できない場合、既定でブロックします。`open` では、gitleaksがなくてもPreToolUseの保護パス検査とdenyパターン検査を続けて実行し、そこでの秘密スキャンだけを省きます。ほかのhookはこれまでどおり検査なしで通過します。

スタンドアロンまたはHomebrewのコマンドとして `agent-guard` を導入済みなら、公式のhost管理ツールにプラグインの導入を委ねられます。

```sh
agent-guard plugin status --host all
agent-guard plugin install --host claude
agent-guard plugin install --host codex
```

`--host all` で両方を一度に導入できます。`--host` を省略する場合は、`claude` と `codex` のどちらか一方だけが利用可能である必要があります。Claude Codeは `--scope user|project|local` に対応し、既定は `user` です。Codexはuser scopeのみ対応します。各marketplaceは、導入を実行するCLIのバージョンと一致するリリースタグ（`v<CLI version>`）に固定されます。固定されたmarketplaceと導入済みプラグインがCLIに一致していれば、`install` を繰り返しても変更はなく、暗黙の更新もしません。導入済みプラグインが無効なら、`status` がその状態を報告し、`install` はhost管理ツールで有効にするよう案内します。更新と削除は明示的に実行します。

```sh
agent-guard plugin update --host all
agent-guard plugin uninstall --host claude
```

`plugin status` はバージョンが食い違っても終了コード0を返すため、既存のスクリプトはそのまま動きます。driftを検出するには `--check` を付けます。`agent-guard plugin status --check --host all` は、marketplaceの固定タグまたは導入済みプラグインのバージョンがこのCLIと異なる場合（`status` が表示するdriftと同じです）に1を返します。`--check` は `status` のみに適用されます。`plugin update` が2で終了した場合は、ユーザーの操作が必要という意味です。たとえば別のリリースに固定されたmarketplaceは、host管理ツールで削除して追加し直す必要があり、コマンドが正確な手順を表示します。

これらのコマンドはリモートの `JeongJaeSoon/agent-guard@v<CLI version>` marketplaceを使い、host CLIを直接呼び出します。プラグインキャッシュやhost設定ファイルを自分で書き換えず、`sudo` の実行やhostの確認プロンプトの回避もしません。変更した各hostを再起動してからhookを検証してください。

`status` は、導入済みプラグインと期待するバージョンとの差をmarketplaceの状態とは別に報告します。Claude Codeは設定されたmarketplace refをJSONの状態出力に含めます。Codex 0.153.4は含めないため、Codexの状態では固定状態を保守的に未検証と表示します。`install` や `update` が既存のCodex marketplaceを再利用する前に、CLIは同じ固定ソースを再度追加するようCodexに要求します。Codexは同じrefの場合のみ冪等な変更なしの処理として扱い、固定されていないrefや異なるrefは状態を変更せず拒否します。

CLIは、固定されていないmarketplace、別のリリースに固定されたmarketplace、同名で別ソースのmarketplaceを黙って置き換えません。公式のhost管理ツールでmarketplaceを削除し、`agent-guard plugin install --host HOST` を再実行してください。marketplaceを削除すると、そこから導入したプラグインも削除されます。この二つのコマンドを一つの復旧手順として扱ってください。marketplaceの登録やプラグインの導入が途中で失敗した場合は、hostが管理する状態のうち何が残っているかと、安全に再試行できる正確なコマンドをCLIが報告します。

CLIのプラグイン管理は、自分で管理する導入を対象とします。`managed` scopeのClaudeプラグインを検出し、macOSとLinuxでは管理者所有の `managed-settings.json` と `managed-settings.d/*.json` のAgent Guard項目も読みます。managed marketplaceが宣言済みで、プラグインがまだダウンロードされていない初期状態も対象です。`status` は管理対象として識別し、`install`、`update`、`uninstall` は変更を拒否します。Claudeの基本ファイル、次に名前順のdrop-inファイルという順番でマージし、Agent Guardのキーを評価します。読み取れないファイル、不正な形式、通常ファイルに解決されないパスがあると、所有関係を安全に判断できないためfail-closedで失敗します。空ファイルや、無関係な設定だけを含む有効なファイルは自己管理の利用を妨げません。有効な `policyHelper` が宣言されていると、実行時にはその結果がファイルベースの設定を置き換えます。CLIはhelperを実行しないため、この場合もfail-closedで失敗します。このCLIの確認は意図しない管理操作を防ぐ補助であり、管理ポリシーを強制する境界はClaudeのmanaged-settingsによる展開です。Jamfなどの管理配下では、管理設定内の確認済みリリースタグを変更してください。管理ポリシーの上にuserやprojectの導入を追加しないでください。[運用](operations.md#managed-claude-code-rollout)を参照してください。

<a id="standalone-cli"></a>

## スタンドアロンCLI

現在のリリースを導入します。

```sh
curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
```

bootstrapperはバージョン付きのリリースarchiveとSHA-256ファイルをダウンロードし、導入済みファイルを変更する前にarchiveを検証します。`~/.agent-guard` に導入し、`~/.local/bin` に `agent-guard` のリンクを作成します。その後、依存関係の状態を報告し、既定のshell integrationを導入します。`~/.local/bin` が `PATH` にあることを確認して実行してください。

```sh
agent-guard version
agent-guard doctor
agent-guard check
```

`check` は依存関係とポリシーの利用可能性を確認するもので、host hookが呼び出された証拠ではありません。利用予定の経路で無害なコマンドを使い、host adapterを別途検証してください。

リリースを固定するには、確認済みの公開バージョンを `v` なしで入力してください。展開に必要な機能を含むバージョンを選びます。以下の保存先は、隔離された導入を必要とする場合にだけ変更してください。

```sh
printf 'Reviewed release version (X.Y.Z): '
IFS= read -r guard_version
curl -fsSL "https://github.com/JeongJaeSoon/agent-guard/releases/download/v${guard_version}/bootstrap.sh" | \
  AGENT_GUARD_VERSION="$guard_version" \
  AGENT_GUARD_HOME="$HOME/.agent-guard" \
  AGENT_GUARD_BIN_DIR="$HOME/.local/bin" sh
```

コマンドwrappingなしでshell integrationを導入したい場合は、導入時にのみ `AGENT_GUARD_COMMAND_WRAPPING=off` を設定します。

`agent-guard update` とその後のbootstrap実行はこの選択を維持します。`AGENT_GUARD_COMMAND_WRAPPING` が未設定なら、導入済みのCLIに `agent-guard setup-shell --print-command-wrapping` で問い合わせます。このコマンドは、オプションなしの `setup-shell` が書き直すrcファイル（fishでは `~/.bashrc` と `~/.zshrc` の両方）の管理ブロックから `on` または `off` を表示します。`setup-shell --rc FILE` で導入した場合のようにそのファイルにブロックがなければ、既定のresolverファイルがなくopt-outのresolverファイルだけがあるときに `off` と読みます。選択を変えるには、update時に `AGENT_GUARD_COMMAND_WRAPPING=on` または `off` を設定します。この確認がないリリースは `agent-guard update` の途中でコマンドwrappingを再び有効にしていました。すでにそうなっている場合は `agent-guard setup-shell --no-command-wrapping` を一度実行し直してください。`AGENT_GUARD_VERSION` でそのような以前のリリースを固定したbootstrap実行も、`AGENT_GUARD_COMMAND_WRAPPING=off` を設定しなければwrappingを有効にして導入します。

スタンドアロンの導入は次のように更新します。

```sh
agent-guard update
agent-guard version
agent-guard doctor
agent-guard check
```

プラグインキャッシュ内ではupdaterを意図的に利用できなくしています。実行ファイル自身がmarketplaceの削除で消えるキャッシュにあるため、自分でmarketplaceの固定先を変更できないからです。代わりに `agent-guard plugin update --host claude` または `--host codex` を実行してください。導入済みプラグインがすでにCLIに一致していれば、最新のGitHubリリースを調べ、新しいリリースへ進めるための正確なhost管理コマンドである `marketplace remove`、`marketplace add ...@vX.Y.Z`、プラグイン導入コマンドを表示します。`agent-guard doctor` と `agent-guard plugin status` も同じリリースの古さを報告します。照会を省略するには `AGENT_GUARD_RELEASE_CHECK=off` を設定します。

Codexが `PATH` にある場合、`agent-guard doctor` は一時的に起動した `codex app-server` に `hooks/list` で問い合わせます。現在のディレクトリでCodexがagent-guardのhookを実行するかを確かめるためです。Codexは各hookを、hookの項目とプラグインの内容で信頼します。そのため `hooks.json` が変わらなくても、プラグインを更新するとagent-guardのhookがすべて再確認待ちになることがあります。再び信頼されるまで、Codexはそれらのhookを実行しません。

Codexがagent-guardのhookを再確認待ちまたは無効と報告した場合、`doctor` はexit 1で終了し、次の手順を表示します。

1. そのディレクトリで `codex` を起動します。
2. **Hooks need review** で **Review hooks** を選びます。
3. 各hookのSourceが `agent-guard@agent-guard` で、コマンドが想定どおりであることを確認してから信頼します。
4. 実行中のCodexセッションを再起動します。

想定どおりのコマンドは、プラグインの `hooks/launch.sh` を `codex` とそのイベントのhook subcommandで実行する1行です。agent-guardのhook同士で異なるのはこのsubcommandだけです。`Stop` のコマンドは次のとおりです。

```sh
sh -c 'r=${PLUGIN_ROOT:-}; [ -n "$r" ] && for q in "$r" "${r%/*}/current" "${r%/*}"/[0-9]*.[0-9]*.[0-9]*; do [ -f "$q/hooks/launch.sh" ] && exec sh "$q/hooks/launch.sh" codex hook-stop "$r"; done; while read -r l; do :; done; m=${AGENT_GUARD_INFRA_FAILURE_MODE:-}; case $m:hook-stop in open:*|closed:*) ;; *:hook-s*) m=open ;; *) m=unset ;; esac; a=blocking; [ $m = open ] && a=continuing; echo "agent-guard: PLUGIN_ROOT env not set or no hook launcher was found; $a because AGENT_GUARD_INFRA_FAILURE_MODE=$m" >&2; [ $m = open ] && exit 0; exit 2'
```

ほかのhookは `hook-pre-tool`、`hook-post-tool`、`hook-session-start`、`hook-user-prompt` を使います。launcherはCodexが信頼するプラグイン内容の一部です。launcherは `bin/agent-guard` を実行する前に選ばれたバージョンが完全かどうかを確かめ、実行ファイルが見つからない場合は `AGENT_GUARD_INFRA_FAILURE_MODE` を適用します。

Codex向けの `plugin status`、`plugin install`、`plugin update` も同じ確認結果を表示しますが、終了コードは変えません。読み取れない応答はokではなくunverifiedとして報告します。okは新しいCodexプロセスが読む設定がそうなっているという意味であり、hookの実際の実行を観測したという意味ではありません。この確認はCodexのapp serverを起動するため、通常のCodex起動と同じくネットワークに接続したり、Codex自身のキャッシュを更新したりすることがあります。省略するには `AGENT_GUARD_CODEX_TRUST_CHECK=off` を設定します。

`setup-shell` はshell rcに次のブロックを追加し、検証を行うresolverを `~/.agent-guard/shell-init.sh` に書き込みます。

```sh
# >>> agent-guard shell-init >>>
[ ! -r ~/.agent-guard/shell-init.sh ] || . ~/.agent-guard/shell-init.sh
# <<< agent-guard shell-init <<<
```

ファイルがない場合、この行は何もせず終了ステータス0で終わります。どちらもキャッシュの `current` リンク経由で解決されるため、プラグインの更新後に `setup-shell` を再実行する必要はありません。再実行すると、以前のブロックを同じ位置でこのブロックに置き換えます。

resolverファイルは `setup-shell` を実行した時点のコピーで、先頭行にファイル形式を記録します。`~/.zshrc` または `~/.bashrc` に以前の `setup-shell` が書いたインラインブロックが残っている場合や、`~/.agent-guard/shell-init*.sh` ファイルに形式行がないか古い形式行がある場合、`agent-guard doctor` は `shell integration:` 行を出力します。その行の案内どおりに `setup-shell` を再実行すると、ブロックは上の1行に置き換わり、ファイルは書き直されます。この行は `doctor` の終了ステータスを変えず、`doctor` はどちらのファイルも編集しません。それまでは古い2つの形式もそのまま読み込まれます。`--rc` で選んだrcファイルは `doctor` の確認対象外です。

スタンドアロンCLIの更新では、既存のインストールの隣に候補を準備してから
置き換えます。チェックサム・展開・置換の失敗時は以前のインストールを維持
または復元し、無関係なローカルファイルも保持します。電源断や処理できない
強制終了で最後のディレクトリ置換が中断された場合は、隣の
`.agent-guard-update.*/previous` バックアップを保持し、元のインストール先に
復元してから再試行してください。旧・新ペイロードを保存する空き容量が必要です。

<a id="homebrew"></a>

## Homebrew

プロジェクトのtapから公開されたformulaを導入します。

```sh
brew tap JeongJaeSoon/tap
brew install JeongJaeSoon/tap/agent-guard
agent-guard version
```

アップグレードして、バージョンを確認します。

```sh
brew upgrade JeongJaeSoon/tap/agent-guard
agent-guard version
```

formulaはリリースtarballのSHA-256を固定します。この導入はHomebrewが管理するため、その上で `agent-guard update` を実行しないでください。

このCLIからClaude CodeやCodexのプラグインも導入した場合、CLIのアップグレードだけではhost marketplaceは新しいリリースに移りません。`agent-guard update` または `brew upgrade` の後に、自分で管理する各hostを明示的に同期してください。

```sh
agent-guard plugin status --host all
agent-guard plugin update --host all
```

既存のmarketplaceが以前のリリースに固定されていると、`plugin update` は変更前に停止し、公式のhost管理ツールによる削除と再導入の正確なコマンドを表示します。その復旧手順に従ってhostを再起動し、プラグイン内のセットアップと受け入れチェックをやり直して、変更されたCodexのhookを再度信頼する操作を行ってください。そのマシンに導入されたhostだけを対象にします。Jamf管理下のClaude Codeでは、管理者の展開手順でmanaged marketplaceのタグを進めてください。

<a id="removing-an-installation"></a>

## アンインストール

各経路を所有する管理ツールから削除してください。hostプラグインにはClaude CodeまたはCodexのプラグイン管理ツールを、Homebrewには `brew uninstall JeongJaeSoon/tap/agent-guard` を使います。スタンドアロンの場合は、まず `agent-guard setup-shell` が選んだshell rcファイルから管理対象のshell integrationブロックと、そのブロックが読み込んでいた `~/.agent-guard/shell-init*.sh` ファイルを取り除きます。次のコマンドでパスを確認した後に限り、公開シンボリックリンクと導入ディレクトリを削除してください。

```sh
command -v agent-guard
readlink "$(command -v agent-guard)"
```

実行ファイルを削除する前に、`install.sh git-hooks` を実行した各リポジトリからnative Git hookを取り除いてください。hookは実行ファイルを絶対パスで指しているため、そのファイルがなくなるとそのリポジトリのすべてのコミットを止めます。

```sh
cd <each-repository-with-the-hook>
git config --get core.hooksPath   # prints githooks while the hook is active
git config --unset core.hooksPath
rm githooks/pre-commit
```

`core.hooksPath` を解除するとGitは再び `.git/hooks` を実行するため、導入前からあったhook（agent-guardのhookが連結して実行していたhook）が再び単独で実行されます。`githooks/` にまだ使う別のhookがある場合は、`core.hooksPath` はそのままにして `githooks/pre-commit` だけを削除してください。取り除かなかったhookはfail-closedのまま動作します。exit 1で終了し、見つからないパスと上記のコマンドを表示します。以前のリリースが導入したhookは `exec: ... not found` だけを表示します。案内を追加するには、そのリポジトリで現在のリリースの `install.sh git-hooks` を実行し直してください。

プラグイン管理ツールのキャッシュを手動で削除しないでください。ライフサイクルはhostが管理します。削除後は新しいshellを開き、`command -v agent-guard` が期待どおりに解決されるか確認してください。別の導入が残っていれば、その `version`、`doctor`、`check` を実行します。
