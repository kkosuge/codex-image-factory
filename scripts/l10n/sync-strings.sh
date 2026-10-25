#!/bin/bash
# ソースの文字列を CodexImageFactory/Localizable.xcstrings に取り込む。
# xcodebuild はビルド時に文字列を .stringsdata に抽出するが、カタログには書き込まないので、ここで同期する。
# Xcode の IDE でビルドしたときは自動で同期されるので、このスクリプトは CLI 用。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
DD="${DERIVED_DATA:-$ROOT/build/DerivedData}"

xcodebuild -project CodexImageFactory.xcodeproj -scheme CodexImageFactory -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD" build > /dev/null

OBJ="$DD/Build/Intermediates.noindex/CodexImageFactory.build/Debug/CodexImageFactory.build/Objects-normal"
FILES=()
while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find "$OBJ" -name '*.stringsdata' -print0)
[[ ${#FILES[@]} -gt 0 ]] || { echo "stringsdata が見つかりません: $OBJ" >&2; exit 1; }

xcrun xcstringstool sync CodexImageFactory/Localizable.xcstrings --stringsdata "${FILES[@]}"
python3 -I - <<'PY'
import json
d = json.load(open("CodexImageFactory/Localizable.xcstrings", encoding="utf-8"))
strings = d["strings"]
def translated(v):
    en = v.get("localizations", {}).get("en", {})
    if en.get("stringUnit", {}).get("state") == "translated":
        return True
    forms = en.get("variations", {}).get("plural", {})
    return bool(forms) and all(f.get("stringUnit", {}).get("state") == "translated" for f in forms.values())
missing = [k for k, v in strings.items()
           if v.get("extractionState") != "stale" and v.get("shouldTranslate", True) and not translated(v)]
stale = [k for k, v in strings.items() if v.get("extractionState") == "stale"]
print(f"キー {len(strings)} 個 / 英語訳が無いもの {len(missing)} 個 / 使われていないもの {len(stale)} 個")
PY
