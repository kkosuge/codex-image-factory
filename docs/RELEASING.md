# 配布とアップデートの手順

Codex Image Factory は、GitHub Releases で zip を配り、GitHub Pages に置いた `appcast.xml` を
Sparkle が読んで自動アップデートする。`v1.2.3` の形のタグを push すると、GitHub Actions が次を全部やる。

1. テスト
2. Release ビルド（Developer ID 署名・Hardened Runtime）
3. Apple の公証（notarization）と staple
4. zip にまとめ、Sparkle の EdDSA 鍵で署名
5. GitHub Releases に zip を上げる
6. `appcast.xml` に新しい版を足して `gh-pages` ブランチに push（GitHub Pages で公開）

アプリ側は、1 日 1 回 appcast を確認し、新しい版があれば裏でダウンロードして、アプリを終了したときに入れ替える。
アップデートのためのウィンドウやアラートは出さない（AI エージェントの操作を止めないため）。状態は設定の「アップデート」に文字で出る。

| もの | 場所 |
| --- | --- |
| ワークフロー | `.github/workflows/release.yml`（テストだけなら `ci.yml`） |
| ビルド〜appcast のスクリプト | `scripts/release/release.sh`（手元でも動く） |
| Pages への公開 | `scripts/release/publish_pages.sh` |
| appcast の URL | `https://kkosuge.github.io/codex-image-factory/appcast.xml`（ビルド設定 `SPARKLE_FEED_URL`） |
| 公開鍵 | ビルド設定 `SPARKLE_PUBLIC_ED_KEY`（Info.plist の `SUPublicEDKey` になる） |

## 最初に 1 回だけやること

### 0. リポジトリ名を決めてから最初のリリースをする

appcast の URL（`https://<ユーザー名>.github.io/<リポジトリ名>/appcast.xml`）は、配ったアプリの中に書き込まれる。
最初のリリースのあとでリポジトリ名を変えると、それまでに配った版はアップデートを見つけられなくなる
（GitHub Pages の URL は、リポジトリ名を変えても転送されない）。名前を変えるなら最初のリリースの前に変え、
ビルド設定 `SPARKLE_FEED_URL` と `scripts/release/pages-index.html` のリンクも直す。

### 1. Sparkle の署名鍵を作る

Sparkle のツールは [Sparkle のリリース](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)の
`Sparkle-2.10.0.tar.xz` に入っている（展開した `bin/` を使う）。

```bash
./bin/generate_keys
```

秘密鍵はログインキーチェーンに入り、公開鍵が表示される。公開鍵を `project.pbxproj` の
`SPARKLE_PUBLIC_ED_KEY`（Debug と Release の 2 か所）に入れてコミットする。

> 2026-10-25 に作成済み。公開鍵は `9muFF7YUgvJ3NkpI4G0kfuetR2b67FSD+FXqfkfCdsE=` で、`project.pbxproj` に入っている。
> 秘密鍵は、鍵を作った Mac のログインキーチェーン（項目名 `https://sparkle-project.org`）にある。

秘密鍵をファイルに書き出して GitHub のシークレットに入れ、ファイルは消す。

```bash
./bin/generate_keys -x sparkle_private_key.txt
```

```bash
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_private_key.txt
```

```bash
rm sparkle_private_key.txt
```

**秘密鍵はパスワードマネージャーなどにも控えておくこと。** なくすと、配った版に新しい版を届けられなくなる。

### 2. Developer ID の証明書

Xcode の Settings → Accounts → チーム → Manage Certificates →「+」→ **Developer ID Application** で作る
（Apple Developer のサイトで作ってもよい）。キーチェーンアクセスで証明書と秘密鍵をまとめて `.p12` に書き出し、
パスワードを付ける。

```bash
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64
```

```bash
gh secret set MACOS_CERTIFICATE_PASSWORD
```

チーム ID（10 文字）はリポジトリの変数に入れる（秘密ではない）。

```bash
gh variable set APPLE_TEAM_ID --body ABCDE12345
```

### 3. 公証用の App Store Connect API キー

App Store Connect → ユーザとアクセス → 統合 → App Store Connect API で、チームキーを作る（役割は Developer で足りる）。
`AuthKey_XXXXXXXXXX.p8` をダウンロードし、キー ID と発行者 ID を控える。

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY_P8_BASE64
```

```bash
gh secret set NOTARY_API_KEY_ID --body XXXXXXXXXX
```

```bash
gh secret set NOTARY_API_ISSUER_ID --body 00000000-0000-0000-0000-000000000000
```

### 4. GitHub Pages

無料プランで Pages を使うにはリポジトリを公開にする。最初のリリースで `gh-pages` ブランチができたら、
Settings → Pages で「Deploy from a branch」→ `gh-pages` / `(root)` を選ぶ。コマンドなら次のとおり。

```bash
gh api -X POST repos/kkosuge/codex-image-factory/pages -f "source[branch]=gh-pages" -f "source[path]=/"
```

### 設定するものの一覧

| 種類 | 名前 | 中身 |
| --- | --- | --- |
| シークレット | `SPARKLE_ED_PRIVATE_KEY` | `generate_keys -x` の中身 |
| シークレット | `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application の .p12（base64） |
| シークレット | `MACOS_CERTIFICATE_PASSWORD` | .p12 のパスワード |
| シークレット | `NOTARY_API_KEY_P8_BASE64` | App Store Connect API キーの .p8（base64） |
| シークレット | `NOTARY_API_KEY_ID` | キー ID |
| シークレット | `NOTARY_API_ISSUER_ID` | 発行者 ID |
| 変数 | `APPLE_TEAM_ID` | チーム ID |
| 変数（任意） | `XCODE_VERSION` | ランナーで使う Xcode の版（例: `26.1`）。省略時はいちばん新しいもの |

## リリースする

```bash
git tag v1.0.0
```

```bash
git push origin v1.0.0
```

- 版（`CFBundleShortVersionString`）はタグから取る。`v1.2` か `v1.2.3` の形にする。
- ビルド番号（`CFBundleVersion`）は git のコミット数。Sparkle はこの数の大小で新旧を決めるので、
  新しいリリースは必ず前より多いコミットから作る。
- 同じタグで作り直したいときは、GitHub のリリースとタグを消してから push し直す（appcast の同じビルド番号の項目は置き換わる）。

## 手元で試す

署名・公証なし（ad-hoc）で、テスト用の鍵を使ってビルドから appcast までを試せる。配布には使えない。

```bash
swift scripts/release/ed25519.swift generate-test-key > /tmp/test.key
```

```bash
VERSION=1.0.0 SPARKLE_BIN=/path/to/Sparkle/bin SPARKLE_KEY_FILE=/tmp/test.key SPARKLE_PUBLIC_ED_KEY="$(swift scripts/release/ed25519.swift public-key /tmp/test.key)" OUT_DIR=/tmp/cif-release ./scripts/release/release.sh
```

`release.sh` は、作った zip の署名をアプリに入れた公開鍵で確かめる。鍵の組み合わせが違えば、そこで止まる。

## 最初の 2 回のリリースで確かめること

自動アップデートの流れは、本物の appcast が無いと試せない。最初は次の順で確かめる。

1. `v1.0.0` を出し、Releases の zip を別の Mac（か、ダウンロードフォルダ）から開いて、Gatekeeper の警告が出ないことを確かめる
2. 設定の「アップデート」に「最新版です」と出ることを確かめる
3. `v1.0.1` を出し、1.0.0 で「アップデートを確認」を押す →「バージョン 1.0.1 は、アプリを終了したときにインストールされます。」
4. アプリを終了して開き直し、設定の版が 1.0.1 になっていることを確かめる
