# Codex CLI 検証メモ（2026-10-24）

要件定義の「未検証の点」「未確定事項」を、実装前に実機で確認した結果。

- 環境: macOS 27.0.1 / Xcode 27.1 / Swift 6.4
- Codex: 検証開始時 codex-cli 0.163.0、途中で `mise up` により 0.164.0 に更新（`image_generation` は両方で stable / true）
- ログイン: `codex login status` → `Logged in using ChatGPT`（終了コード 0）

## 1. 画像は作業ディレクトリに書かれるか → 書かれる

要件どおりのコマンド（`-C <dir> -s workspace-write --skip-git-repo-check --json -o <dir>/last-message.md`）で、
指示したファイル名 `probe-01.png` が作業ディレクトリにできた。

Codex 内部の流れ:

1. image_generation ツールが `~/.codex/generated_images/<thread_id>/exec-<uuid>.png` に画像を書く
2. モデルが `cp` で作業ディレクトリの指定名にコピーする（JSONL の `command_execution` に出る）

- JSONL に画像データ（base64）は **含まれない**。
- `thread.started` イベントに `thread_id` が出る。モデルがコピーしなかった場合は
  `~/.codex/generated_images/<thread_id>/` から取り出せる（アプリはこれを予備の取り出し口にする）。
- `last-message.md` には指示どおりファイル名が 1 行ずつ入る。

## 2. サイズ・透過背景をプロンプトで指定できるか → できる

| 指定 | 結果 |
| --- | --- |
| 正方形・透明 | 1254×1254、hasAlpha: yes |
| 横長（3:2）・白、2 枚 | 1536×1024 ×2、hasAlpha: no |
| 縦長（2:3）・参照画像 1 枚 | 1024×1536 |

正確なピクセル数は指定できないが、縦横比と透過は効く。

## 3. 並列実行時の `~/.codex` 競合 → なし

2 本を同時実行（片方 `--ephemeral`、片方は通常）して両方成功。`--ephemeral` でも
`generated_images` には書かれる。既定では `--ephemeral` を付けず、設定で切り替えられるようにした。

## 4. レート制限 → 未到達（未検証）

3 回の並列実行では制限に当たらなかった。エラー時の JSONL は次の形なので、アプリは
stderr と、stdout のうち `type` が `error` / `turn.failed` の行だけを見て `429` / `rate limit` / `usage limit` などを探す
（`command_execution` の出力や Codex の返答本文は誤検知のもとになるので見ない）。

```json
{"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{...}}"}
{"type":"turn.failed","error":{"message":"..."}}
```

## 5. モデル指定（`-m`）と画質

画質は image_generation ツール側で決まり、エージェントのモデル・推論の強さは所要時間にほぼ影響しなかった
（1 枚 59 秒・推論 ultra、2 枚 61 秒・推論 low）。設定に「モデル」と「推論の強さ」を任意項目として置いた。

## 6. 実装後の受け入れテスト（本物の codex、2026-10-25）

`RealCodexTests`（アプリの実行部品・キュー・プロセス実行をそのまま使う）で、5 件を並列数 3 で流した。

- 5 件とも完了。最大同時実行 3、全体で約 2 分（1 件あたり約 60 秒）
- 各フォルダに run.json / prompt.txt / stdout.jsonl / stderr.log / last-message.md / 画像
- 透明指定は hasAlpha: yes、横長 1536×1024、縦長 1024×1536、正方形 1254×1254
- 履歴の `commandLine` を zsh にそのまま渡して再実行し、同じ名前の画像ができることを確認
- レート制限には当たらなかった（この日の合計は約 10 枚）

## その他の注意

- stdin がパイプ・ファイルだと `Reading additional input from stdin...` と表示して読みに行く。
  アプリは stdin を `/dev/null` にする。
- `-i, --image <FILE>...` は複数値を取るので、プロンプトの前に `--` を置く（`--` は受け付けられることを確認）。
- `item.completed` の `item.type == "error"` に無害な警告（under-development features など）が出る。失敗判定には使わない。
- stderr に `ERROR codex_core::tools::router: ... collab spawn failed` が出ることがあるが、終了コード 0 で成功している。
- codex は Node ではなくネイティブバイナリ（mise 配下）。GUI からはログインシェル（`zsh -lc`）でパスを解決する。
