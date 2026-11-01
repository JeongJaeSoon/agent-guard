<!-- translated-from: docs/installation.md; source-blob: 63ed4d12f61638385d2bb565018802fd6c3f734a -->

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

<a id="runtime-dependencies"></a>

## 実行時の依存関係

macOSとLinuxでの実行には `sh`、`awk`、`git`、`jq`、gitleaks 8.30以降が必要です。gitleaksのバージョン確認を独立したプロセスグループで実行するため、`setsid` またはPerlも必要です。この隔離によって、確認処理の時間制限と子プロセスの後処理が可能になります。Linuxでは `sudo apt-get install -y util-linux` または `sudo dnf install -y util-linux` で `setsid` を導入してください。HomebrewのformulaはCLIとともにPerlを導入します。macOSの手動導入でどちらもない場合は `brew install perl` を使えます。

隔離ツールがないと、`agent-guard setup`、`doctor`、`check` は非ゼロの終了ステータスを返します。`setup --install` はダウンロード前に隔離ツールを確認します。ツールがなければgitleaksをダウンロードも上書きもせず、不足するツールの導入コマンドを表示します。導入後はgitleaksが十分に準備できているか再確認します。実行時のhookはこの状態を正常な検査とは扱わず、`AGENT_GUARD_INFRA_FAILURE_MODE` の `open` または `closed` ポリシーを適用します。

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

スタンドアロンの導入は次のように更新します。

```sh
agent-guard update
agent-guard version
agent-guard doctor
agent-guard check
```

プラグインキャッシュ内ではupdaterを意図的に利用できなくしています。実行ファイル自身がmarketplaceの削除で消えるキャッシュにあるため、自分でmarketplaceの固定先を変更できないからです。代わりに `agent-guard plugin update --host claude` または `--host codex` を実行してください。導入済みプラグインがすでにCLIに一致していれば、最新のGitHubリリースを調べ、新しいリリースへ進めるための正確なhost管理コマンドである `marketplace remove`、`marketplace add ...@vX.Y.Z`、プラグイン導入コマンドを表示します。`agent-guard doctor` と `agent-guard plugin status` も同じリリースの古さを報告します。照会を省略するには `AGENT_GUARD_RELEASE_CHECK=off` を設定します。shellブロックはキャッシュの `current` リンク経由で解決されるため、プラグインの更新後に `setup-shell` を再実行する必要はありません。

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

各経路を所有する管理ツールから削除してください。hostプラグインにはClaude CodeまたはCodexのプラグイン管理ツールを、Homebrewには `brew uninstall JeongJaeSoon/tap/agent-guard` を使います。スタンドアロンの場合は、まず `agent-guard setup-shell` が選んだshell rcファイルから管理対象のshell integrationブロックを取り除きます。次のコマンドでパスを確認した後に限り、公開シンボリックリンクと導入ディレクトリを削除してください。

```sh
command -v agent-guard
readlink "$(command -v agent-guard)"
```

プラグイン管理ツールのキャッシュを手動で削除しないでください。ライフサイクルはhostが管理します。削除後は新しいshellを開き、`command -v agent-guard` が期待どおりに解決されるか確認してください。別の導入が残っていれば、その `version`、`doctor`、`check` を実行します。
