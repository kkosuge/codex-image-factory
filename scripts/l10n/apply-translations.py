#!/usr/bin/env python3
"""英語訳（JSON: {"日本語のキー": "English"}）を Localizable.xcstrings に書き込む。

  python3 scripts/l10n/apply-translations.py translations.json [...]

カタログに無いキーは無視して報告する。訳は state=translated で入れる。
"""
import json
import sys

CATALOG = "CodexImageFactory/Localizable.xcstrings"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1
    with open(CATALOG, encoding="utf-8") as f:
        catalog = json.load(f)
    strings = catalog["strings"]
    applied, unknown = 0, []
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8") as f:
            table = json.load(f)
        for key, value in table.items():
            if key not in strings:
                unknown.append(key)
                continue
            entry = strings[key]
            entry.setdefault("localizations", {})["en"] = {
                "stringUnit": {"state": "translated", "value": value}
            }
            applied += 1
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
        f.write("\n")
    print(f"{applied} 個の訳を入れました")
    for key in unknown:
        print(f"カタログに無いキー: {key}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
