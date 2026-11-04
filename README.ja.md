<!-- translated-from: README.md; source-blob: f5b84578e7b4a21fc467c55f0d61fda258c7b9a7 -->

<p align="center">
  <a href="https://github.com/JeongJaeSoon/agent-guard/releases"><img src="docs/assets/icon.png" alt="Agent Guard icon" width="128" height="128"></a>
</p>

<h1 align="center">Agent Guard</h1>

<p align="center">
  <a href="https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml"><img src="https://github.com/JeongJaeSoon/agent-guard/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/JeongJaeSoon/agent-guard/releases/latest"><img src="https://img.shields.io/github/v/release/JeongJaeSoon/agent-guard" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/JeongJaeSoon/agent-guard" alt="MIT license"></a>
</p>

[English](README.md) · [한국어](README.ko.md) · 日本語

**AIコーディングエージェントによる秘密情報の漏えいを防ぐ、ローカル優先のガードです。**

> 危険な `.env` の読み取りをブロックし、秘密情報らしい出力をマスクして、変更がGitに入る前に検査します。ホスティングアカウントもテレメトリー収集もありません。

この文書は[英語の正本](README.md)の日本語訳です。以下のインストール・検証ガイドは日本語で提供し、それ以外の詳細文書は英語版にリンクしています。

---

Agent Guardは、Claude Code、Codex、Git hook、GitHub Actions、直接実行するshellコマンドに対応するローカル優先のガードです。対応するツールの実行前に一般的な秘密情報の露出経路を遮断し、対応するツール出力をマスクし、ファイル変更後に変更されたファイルを検査します。`gitleaks` と移植可能なshellを使い、ホスティングアカウント、テレメトリー収集機能、開発者向けサービスはありません。

多層防御の一つとして使ってください。GitHub Secret Scanning、Push Protection、レビュー、通常の認証情報管理も引き続き必要です。Agent Guardは秘密情報の保管庫、DLPシステム、EDR、認証情報のローテーションツールではありません。

![Claude CodeでのAgent Guard: エージェントがBashの`cat`やReadで秘密鍵を含む.envを読むとブロックされ、shell integration有効時にユーザーが直接実行した`! cat .env`では鍵が[REDACTED]になります](docs/demo.gif)

<a id="keep-secrets-out-of-git"></a>

## 秘密情報をGitに入れる前に止める

鍵をコミットすると、ファイルから削除してもGitの履歴には長く残ります。Agent Guardはhookが適用されるコミット経路の手前でgitleaksを実行します。APIキー、トークン、`.env` の値が検出されれば履歴に入る前に止め、CIが後段の防御を担います。

| コミットする主体 | 漏えいを止める仕組み |
| --- | --- |
| Claude CodeまたはCodexのエージェント | エージェントの `git commit` や `git push` の前に、ステージングされた追加行を検査し、秘密情報らしい値があればコマンドをブロックします。これらのコマンドでの `--no-verify` と `--no-gpg-sign` も拒否するため、エージェントはフラグで検査を無効にできません。 |
| ユーザーまたはエージェントによるすべてのローカルコミット | [ネイティブpre-commit hook](docs/integrations.md#native-git-hook)を導入すると、Gitがコミット対象をすべてステージングした後に追加行を検査し、検出時や検査を実行できない場合はコミットを中止します。Gitは `git commit --no-verify` でhookをスキップします。プラグインはエージェントによるそのフラグの使用を拒否し、残りをCIが補います。 |
| push後のすべての利用者 | [GitHub Action](docs/integrations.md#github-actions)が、実行対象のpushやpull requestでチェックアウトされたファイルを検査し、リポジトリの後段の防御を担います。 |

プラグインはコミットに含まれる内容を検査します。インデックスに加え、`git commit -a`、`--patch`、`git commit <path>` のようなpathspec、`--include`、`--only` でGitが自らステージングする追跡対象の変更と、`--interactive` で追加できる未追跡ファイルも対象です。`git commit $FLAGS` のように引数が実行時に決まる場合や、同じコマンドが先に `git add` を実行する場合は、追跡対象のすべての変更と未追跡ファイルを検査します。`git add -f` で追加する無視対象ファイルも含みます。`bash -c`、`sh -c`、here-string、`env -S`、`eval` に渡されるshellコードもコマンド本体と同じように検査します。Git aliasが展開するコマンドは、その実行で読み込まれる設定から取得して検査します。コード、Gitサブコマンド、alias、作業ディレクトリが実行時にしか決まらない場合はコミット対象を判断できないため、後述のインフラ障害ポリシーを適用します。`!` shell alias、`help.autoCorrect` が実行する可能性のある推測コマンド、同じコマンドの前段で変更された可能性のあるaliasも該当します。

プラグインが検査するのはコマンド開始時点のファイルです。同じコマンドの前段でファイルを書き込んだり別のリポジトリへ移動したりすると、その結果は見えません。ネイティブhookも導入してください。pushの検査対象は既存のコミットではなくステージングされた内容です。これらのhookを経由せずコミットされた秘密情報は、チェックアウトされたツリーに残っている間にCIが検出します。

検査を実行できなかった状態を正常とは扱いません。Claude CodeとCodexプラグインの既定では、保護の低下を警告してコマンドを続行します。`AGENT_GUARD_INFRA_FAILURE_MODE=closed` を設定するとブロックします（[設定](docs/configuration.md)を参照）。ネイティブhookとActionはこの設定にかかわらず、検査不能なら失敗します。Claude Code 2.1.295以降では、判断前のタイムアウトや異常終了も、どちらのモードでもツール呼び出しをブロックします。

<a id="choose-your-path"></a>

## 目的に合うガイドを選ぶ

| やりたいこと | 最初に読む文書 |
| --- | --- |
| Claude Code・Codexプラグイン、CLI、Git hook、Actionの導入 | [インストール](docs/installation.ja.md) |
| hostごとの対応範囲と連携設定の理解 | [連携](docs/integrations.md) |
| 出力マスキングが届くツール経路とhost間の違いの確認 | [出力マスキングの範囲](docs/integrations.md#output-masking-coverage) |
| 導入の検証と結果が証明する範囲の理解 | [検証](docs/verification.ja.md) |
| ポリシー、PII、マスキング、インフラ障害時の動作設定 | [設定](docs/configuration.md) |
| 組織での展開や環境のトラブル対応 | [運用](docs/operations.md)。[韓国語・日本語の展開ガイド](https://agent-guard-guide.jaesoon.chatgpt.site/)は現在公開されている補足説明です。 |

<a id="quick-use"></a>

## すぐに使う

プラグインの導入後、対話式のセットアップを実行します。

```text
# Claude Code
/agent-guard:setup-agent-guard

# Codex
$setup-agent-guard
```

セットアップはローカルの依存関係を確認し、合成チェックを実行します。現在のhostのツール経路がhookを呼び出す証拠にはなりません。プラグインの保護境界に依存する前に、[検証](docs/verification.ja.md)の無害な実呼び出しプローブを完了してください。

リポジトリを直接検査するには、次を実行します。

```sh
agent-guard scan-working-tree
agent-guard scan-staged
agent-guard scan-path .
```

<a id="support-log"></a>

## サポート用ログ

次のコマンドで、メタデータのみを含むローカルのサポート用ログを保存できます。

```sh
agent-guard logs export --output agent-guard-support.jsonl
```

親ディレクトリは事前に存在している必要があります。Agent Guardは権限0600の新しいファイルを作成し、既存ファイルやシンボリックリンクの置き換えを拒否します。プラグインのみの導入で `PATH` に `agent-guard` がない場合は、セットアップスキルが表示するプラグイン内の実行ファイルを使ってください。提出する情報は[サポート](SUPPORT.md)を参照してください。

<a id="requirements-and-scope"></a>

## 動作要件と対象範囲

リリースアーカイブとHomebrewパッケージは、チェックサム検証とshellへのフォールバックを備えたビルド済みRust文字列置換ヘルパーを使います。Rustは実行時の依存関係ではなく、検出・ポリシー・host adapterはshellに残ります。Git marketplaceプラグインはソースのみで配布します。プラットフォーム要件、明示的なshell選択、ビルド済みヘルパーの利用方法は[インストールガイド](docs/installation.ja.md)を参照してください。

対応プラットフォームはx64・arm64のmacOSとLinuxです。実行時には `sh`、`awk`、`git`、`jq`、gitleaks 8.30以降が必要です。現在Windowsには対応していません。gitleaksのバージョン確認を独立したプロセスグループで実行するため、Linuxの `util-linux` に含まれる `setsid`、またはPerlも必要です。`agent-guard doctor` は隔離ツールがなければ、プラットフォームに合った導入コマンドを表示します。

既定の処理はローカルで一時的に行われます。エンドポイントを使うPIIプロバイダーを有効にする前に[プライバシー](PRIVACY.md)を読んでください。責任ある脆弱性報告は[セキュリティ](SECURITY.md)、安全な問題報告は[サポート](SUPPORT.md)を参照してください。

<a id="project-documents"></a>

## プロジェクト文書

- [プライバシーとデータの取り扱い](PRIVACY.md)
- [セキュリティポリシー](SECURITY.md)
- [サポート](SUPPORT.md)
- [第三者に関する告知](THIRD_PARTY_NOTICES.md)
- [変更履歴](CHANGELOG.md)
- [既知の制約](docs/integrations.md#limits-and-backstops)

Agent Guardが会話記録への秘密情報の混入を防いだら、[開発への支援](https://github.com/sponsors/JeongJaeSoon)をご検討ください。
