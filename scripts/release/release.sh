#!/bin/bash
# 配布用のビルド → 署名 → 公証 → zip → EdDSA 署名 → appcast.xml の更新。
# GitHub Actions（.github/workflows/release.yml）からも、手元からも同じように動かす。
#
# 必須:
#   VERSION              配布する版（例: 1.2.0）。CFBundleShortVersionString になる
#   SPARKLE_BIN          Sparkle の bin フォルダ（sign_update がある場所）
#   SPARKLE_KEY_FILE     EdDSA の秘密鍵ファイル（generate_keys -x で書き出したもの）
# 任意:
#   BUILD_NUMBER         CFBundleVersion。省略時は git のコミット数（増え続ける整数）
#   TEAM_ID              Apple のチーム ID。空なら ad-hoc 署名で公証もしない（手元での試し用）
#   SIGN_IDENTITY        既定は "Developer ID Application"
#   NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER   App Store Connect API キー（公証用）
#   SPARKLE_PUBLIC_ED_KEY  公開鍵の上書き（試し用。普段は project.pbxproj の値を使う）
#   APPCAST_IN           今の appcast.xml（無ければ新しく作る）
#   REPOSITORY           owner/name。既定は GITHUB_REPOSITORY か kkosuge/codex-image-factory
#   OUT_DIR              出力先。既定は build/release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

: "${VERSION:?VERSION を指定してください（例: VERSION=1.2.0）}"
: "${SPARKLE_BIN:?SPARKLE_BIN（sign_update のあるフォルダ）を指定してください}"
: "${SPARKLE_KEY_FILE:?SPARKLE_KEY_FILE（EdDSA の秘密鍵ファイル）を指定してください}"

if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "VERSION は 1.2 や 1.2.3 の形にしてください: $VERSION" >&2
  exit 1
fi

BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
TEAM_ID="${TEAM_ID:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-kkosuge/codex-image-factory}}"
OUT_DIR="${OUT_DIR:-$ROOT/build/release}"
APP_NAME="Codex Image Factory"
ZIP_NAME="Codex-Image-Factory-${VERSION}.zip"
TAG="v${VERSION}"
FEED_URL="$(xcodebuild -project CodexImageFactory.xcodeproj -target CodexImageFactory -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ SPARKLE_FEED_URL = /{print $2; exit}')"
DOWNLOAD_URL="https://github.com/${REPOSITORY}/releases/download/${TAG}/${ZIP_NAME}"
RELEASE_PAGE="https://github.com/${REPOSITORY}/releases/tag/${TAG}"

ARCHIVE="$OUT_DIR/CodexImageFactory.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"

step() { echo; echo "==> $*"; }

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

BUILD_ARGS=(
  "MARKETING_VERSION=$VERSION"
  "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
)
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  BUILD_ARGS+=("SPARKLE_PUBLIC_ED_KEY=$SPARKLE_PUBLIC_ED_KEY")
fi
if [[ -n "$TEAM_ID" ]]; then
  # Hardened Runtime は公証に必要。手元の ad-hoc 署名の版ではライブラリ検証で Sparkle を読めなくなるので、
  # プロジェクトの既定では切り、配布用のビルドでだけ入れる。
  BUILD_ARGS+=(
    "ENABLE_HARDENED_RUNTIME=YES"
    "CODE_SIGN_STYLE=Manual"
    "DEVELOPMENT_TEAM=$TEAM_ID"
    "CODE_SIGN_IDENTITY=$SIGN_IDENTITY"
    "OTHER_CODE_SIGN_FLAGS=--timestamp"
  )
fi

step "アーカイブ（$VERSION / ビルド $BUILD_NUMBER）"
xcodebuild -project CodexImageFactory.xcodeproj -scheme CodexImageFactory \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT_DIR/DerivedData" \
  archive "${BUILD_ARGS[@]}" | tail -5

step "書き出し"
mkdir -p "$EXPORT_DIR"
if [[ -n "$TEAM_ID" ]]; then
  cat > "$OUT_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$SIGN_IDENTITY</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$OUT_DIR/ExportOptions.plist" | tail -5
else
  echo "TEAM_ID が無いので、ad-hoc 署名のまま取り出します（配布には使えません）"
  ditto "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"
fi

step "中身の確認"
PLIST="$APP/Contents/Info.plist"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
UPDATES_ENABLED="$(/usr/libexec/PlistBuddy -c 'Print :CIFUpdatesEnabled' "$PLIST" 2>/dev/null || true)"
echo "版: $BUILT_VERSION / ビルド: $BUILT_BUILD / 自動アップデート: $UPDATES_ENABLED"
[[ "$BUILT_VERSION" == "$VERSION" && "$BUILT_BUILD" == "$BUILD_NUMBER" ]] || { echo "版が合いません" >&2; exit 1; }
[[ "$UPDATES_ENABLED" == "YES" ]] || { echo "Release ビルドなのに CIFUpdatesEnabled が YES ではありません" >&2; exit 1; }
[[ -n "$PUBLIC_KEY" ]] || { echo "SUPublicEDKey が空です。project.pbxproj の SPARKLE_PUBLIC_ED_KEY を設定してください" >&2; exit 1; }
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || { echo "Sparkle.framework が入っていません" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ -n "$TEAM_ID" ]]; then
  codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Timestamp|CodeDirectory)" || true
  codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime" || { echo "Hardened Runtime が有効になっていません" >&2; exit 1; }
fi

if [[ -n "$TEAM_ID" && -n "${NOTARY_KEY_PATH:-}" ]]; then
  step "公証"
  ditto -c -k --keepParent "$APP" "$OUT_DIR/notarize.zip"
  RESULT="$(xcrun notarytool submit "$OUT_DIR/notarize.zip" \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait --timeout 30m --output-format json)"
  echo "$RESULT"
  STATUS="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$RESULT")"
  SUBMISSION="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$RESULT")"
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "公証が通りませんでした（$STATUS）。ログ:" >&2
    xcrun notarytool log "$SUBMISSION" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  rm -f "$OUT_DIR/notarize.zip"
elif [[ -n "$TEAM_ID" ]]; then
  echo "NOTARY_KEY_PATH が無いので公証しません（Gatekeeper に止められます）" >&2
fi

step "zip にまとめる"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT_DIR/$ZIP_NAME"
ls -l "$OUT_DIR/$ZIP_NAME"

step "EdDSA 署名"
SIGN_OUTPUT="$("$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$OUT_DIR/$ZIP_NAME")"
SIGNATURE="$(sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/' <<<"$SIGN_OUTPUT")"
LENGTH="$(sed -E 's/.*length="([0-9]+)".*/\1/' <<<"$SIGN_OUTPUT")"
[[ -n "$SIGNATURE" && "$LENGTH" =~ ^[0-9]+$ ]] || { echo "sign_update の出力を読めません: $SIGN_OUTPUT" >&2; exit 1; }
# アプリに入れた公開鍵で確かめる。鍵を取り違えると、配った版がもう更新を受け取れなくなるため。
swift "$ROOT/scripts/release/ed25519.swift" verify "$PUBLIC_KEY" "$SIGNATURE" "$OUT_DIR/$ZIP_NAME"

step "appcast.xml"
python3 -I "$ROOT/scripts/release/update_appcast.py" \
  --in "${APPCAST_IN:-}" --out "$OUT_DIR/appcast.xml" \
  --feed-url "$FEED_URL" --build "$BUILD_NUMBER" --version "$VERSION" \
  --url "$DOWNLOAD_URL" --length "$LENGTH" --signature "$SIGNATURE" \
  --release-page "$RELEASE_PAGE"
xmllint --noout "$OUT_DIR/appcast.xml"
sed -n '1,30p' "$OUT_DIR/appcast.xml"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "zip=$OUT_DIR/$ZIP_NAME"
    echo "appcast=$OUT_DIR/appcast.xml"
    echo "tag=$TAG"
  } >> "$GITHUB_OUTPUT"
fi

step "できあがり"
echo "zip:     $OUT_DIR/$ZIP_NAME"
echo "appcast: $OUT_DIR/appcast.xml"
echo "配布先:  $DOWNLOAD_URL"
