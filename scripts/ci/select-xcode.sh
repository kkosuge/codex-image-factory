#!/bin/bash
# GitHub Actions の macOS ランナーで、入っている中でいちばん新しい Xcode を選ぶ。
# XCODE_VERSION（例: 26.1）を指定したときは、その版を選ぶ。
set -euo pipefail

if [[ -n "${XCODE_VERSION:-}" ]]; then
  APP="/Applications/Xcode_${XCODE_VERSION}.app"
else
  APP="$(python3 -I - <<'PY'
import glob, re
apps = glob.glob("/Applications/Xcode*.app")
def key(path):
    m = re.search(r"Xcode[_-]?([0-9.]+)", path)
    nums = [int(x) for x in m.group(1).split(".") if x] if m else [0]
    beta = "beta" in path.lower() or "release_candidate" in path.lower()
    return (not beta, nums)
print(max(apps, key=key) if apps else "")
PY
)"
fi

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Xcode が見つかりません: ${APP:-なし}" >&2
  ls -d /Applications/Xcode* >&2 || true
  exit 1
fi
sudo xcode-select -s "$APP/Contents/Developer"
xcodebuild -version
swift --version
