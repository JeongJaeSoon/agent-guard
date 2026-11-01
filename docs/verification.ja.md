<!-- translated-from: docs/verification.md; source-blob: 9fd0748eab29d52f6d06342382e7994583f0e812 -->

<a id="verification"></a>

# 検証

[English](verification.md) · [한국어](verification.ko.md) · 日本語

この文書は[英語の正本](verification.md)の日本語訳です。導入手順は[日本語のインストールガイド](installation.ja.md)を参照してください。それ以外の詳細文書は英語版にリンクしています。

依存関係、決定的な動作、実際のhostによるhook呼び出しは、別々の証拠で確認してください。前の段階の成功は次の段階の証明にはなりません。

正確なmatcher、hostごとの置換契約、時間制限は[出力マスキングの範囲](integrations.md#output-masking-coverage)にまとまっています。プラグインの更新、hookの信頼設定の変更、hostのアップグレード後は、依存するすべての経路で次の実呼び出しプローブをやり直してください。

| 証拠 | コマンドまたは操作 | 証明すること | 証明しないこと |
| --- | --- | --- | --- |
| 依存関係の確認 | `agent-guard check` または `agent-guard doctor` | 必要なローカルコマンドとポリシーファイルが利用可能 | hostがhookを呼び出すこと |
| 合成チェック | `agent-guard smoke-test` | 同梱の拒否・scanner・マスキング経路が連動する | 導入済みプラグインや現在の経路がそれらを使うこと |
| ローカルリポジトリ検査 | `scan-staged`、`scan-working-tree`、`scan-path` | 選択した現在のリポジトリまたはパスを検査した | 今後のツール呼び出しや、範囲外の無視対象パス |
| 実際のhostでのプローブ | 通常のhost経路を通した無害なプローブ | その経路が期待したhookを呼び出した | 別のツール、wrapper、host |

<a id="plugin-acceptance"></a>

## プラグインの受け入れ確認

1. hostの対話式セットアップ、またはプラグイン内の `check` と `smoke-test` を実行します。
2. プラグインを更新するたびに、hookが有効で信頼済みであることを確認します。
3. ユーザーが使うのと同じ経路で、ツール実行前の検査用sentinelを実行します。

   ```sh
   printf '%s\n' 'AGENT_GUARD_LIVE_PRE_TOOL_PROBE'
   ```

   sentinelが表示される前にguardがブロックする必要があります。

4. 同じ経路でツール実行後のプローブを実行します。このコマンドは検査対象の実行ファイルからsentinelを読み出すため、単独で実行できます。この文書には別のコピーを置かず、sentinelの不一致を防ぎます。

   ```sh
   GUARD=$(command -v agent-guard)   # or the plugin-local bin/agent-guard path
   printf '%s\n' "$(sed -n 's/^LIVE_POST_TOOL_PROBE=//p' "$GUARD" | head -1)"
   ```

   生のsentinelがモデルに届いてはいけません。置換結果には `[REDACTED]` が残り、ローカル診断ログが有効な間は、置換を行ったhook呼び出しも示されるはずです。

   ```text
   [REDACTED] agent-guard live probe run_id=<run id>
   ```

   コマンドに `[REDACTED]` を直接入力しないでください。それではマスキングもhookの呼び出しも検査できません。

5. 報告されたrun idを、ユーザー自身がターミナルで診断ログと照合します。

   ```sh
   agent-guard logs export \
     | jq -c 'select(.run_id == "<run id>" and .command == "hook-post-tool")'
   ```

   `"outcome":"masked"` を持つ `finished` の記録は、その導入がその時点でsentinelを置換したことを示します。この部分だけがエージェントの報告に依存しないため、run idに対応する記録がなければプローブ失敗として扱ってください。ログにはメタデータのみが含まれ、ツール名はありません。記録が証明するのはPostToolUseによる置換であり、どのツール経路を通ったかではありません。実際に実行した経路と合わせて判断してください。`AGENT_GUARD_LOG_MODE=off` では引用できる記録がなく、置換結果も `[REDACTED]` のみです。

sentinelに認証情報は含まれません。検査するのはhookの呼び出しだけであり、決定的なポリシー動作は `smoke-test` で別途確認します。

sentinelを含むファイルの読み取り自体もguardの対象となるツール呼び出しです。そのため、セットアップスキル自身のプローブ行も置換済みで返されます。これはhookが動作した結果であり、リポジトリにplaceholderがコミットされているわけではありません。確認が必要なら、その行とplaceholderのバイト長を比較してください。

<a id="read-results-correctly"></a>

## 結果を正しく読む

- 秘密情報の検出はブロックまたは検出結果であり、scannerのエラーではありません。
- `DEGRADED` の表示やscannerが使えない状態は、正常な検査結果ではありません。依存関係を修復するか、文書化されたインフラ障害ポリシーを選んでください。
- インフラ障害時の `open` モードは、目に見える一度限りの警告後に続行し、`closed` はブロックします。このポリシーはインフラ障害に適用され、秘密情報の検出時はブロックします。空ではなく、形式が不正またはオブジェクトでないPreToolUse・Stop入力は、インフラモードと無関係にブロックされます。PostToolUseはまず独立したparserで有効なhost envelopeを復元し、保守的な置換を出力します。空ではなく、形式が不正またはオブジェクトでないPostToolUse envelopeに対する終了ステータス2は可視の診断であり、完了済みのツール結果を撤回できません。空のstdinは文書化された例外であり、PreToolUse、PostToolUse、Stopはいずれも応答なしでステータス0を返します。拒否したイベントはすべて報告します。
- hostが時間制限に達したhookを終了すると、hookが判断を返せないことがあります。Claude Code 2.1.295以降は `PreToolUse` hookのタイムアウトや異常終了時にツール呼び出しをブロックします。ほかのイベントやhostには当てはまりません。GitとCIによる後段の防御を有効にしてください。

直接の検査コマンド（`scan-staged`、`scan-working-tree`、`scan-path`）は、インフラ障害ポリシーを適用せず、呼び出し元に終了ステータスを返します。

| 終了ステータス | 意味 |
| --- | --- |
| `0` | 検査した入力では何も検出されませんでした。 |
| `1` | 秘密情報らしい値を検出しました。検出結果はマスクされるため、メッセージは値ではなく検査した入力を示します。 |
| `2` | `scan-path` の引数やパスの不足などの使用法エラー、または `scan-staged`・`scan-path` 中のgitleaksエラーです。 |
| `3` | 検査を実行できませんでした。gitleaksやその設定がない、Gitリポジトリではない、`git diff` が失敗した、入力が検査予算を超えた、などの状態です。 |

`2` と `3` は「未検査」と扱い、正常とは扱わないでください。

<a id="routine-checks"></a>

## 日常のチェック

```sh
agent-guard doctor
agent-guard smoke-test
agent-guard scan-working-tree
```

CodexではhookのUIで変更されたhookを再確認してください。Claude Codeでは導入やshell rcの変更後にプラグインを再読み込みし、セッションを再起動してください。
