#!/usr/bin/env python3
"""Sparkle の appcast.xml に新しい版の項目を足す。

既存の appcast があれば読み込み、同じビルド番号の項目は置き換えて、新しい項目を先頭に入れる。
標準ライブラリだけで動く（GitHub Actions の macOS ランナーの python3 で動かす）。
"""

import argparse
import email.utils
import os
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def sp(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def new_feed(title: str, feed_url: str) -> ET.ElementTree:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "link").text = feed_url
    ET.SubElement(channel, "description").text = f"{title} の更新情報"
    ET.SubElement(channel, "language").text = "ja"
    return ET.ElementTree(rss)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--in", dest="input", default="", help="既存の appcast.xml（無ければ新しく作る）")
    p.add_argument("--out", required=True, help="書き出す appcast.xml")
    p.add_argument("--title", default="Codex Image Factory")
    p.add_argument("--feed-url", required=True)
    p.add_argument("--build", required=True, help="CFBundleVersion（sparkle:version）")
    p.add_argument("--version", required=True, help="CFBundleShortVersionString")
    p.add_argument("--url", required=True, help="zip のダウンロード URL")
    p.add_argument("--length", required=True, type=int)
    p.add_argument("--signature", required=True, help="sign_update が出した EdDSA 署名")
    p.add_argument("--minimum-system-version", default="15.0")
    p.add_argument("--release-page", default="", help="リリースのページ（お知らせ用）")
    p.add_argument("--pub-date", default="", help="RFC 2822 の日時。省略時は今")
    args = p.parse_args()

    if not args.build.isdigit():
        print(f"ビルド番号は整数にしてください: {args.build}", file=sys.stderr)
        return 1

    if args.input and os.path.exists(args.input) and os.path.getsize(args.input) > 0:
        tree = ET.parse(args.input)
    else:
        tree = new_feed(args.title, args.feed_url)
    rss = tree.getroot()
    channel = rss.find("channel")
    if channel is None:
        print("appcast に channel がありません", file=sys.stderr)
        return 1

    # 同じビルド番号の項目は置き換える（同じタグで作り直したとき）。
    for item in list(channel.findall("item")):
        v = item.find(sp("version"))
        if v is not None and (v.text or "").strip() == args.build:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"{args.title} {args.version}"
    ET.SubElement(item, "pubDate").text = args.pub_date or email.utils.formatdate(usegmt=True)
    ET.SubElement(item, sp("version")).text = args.build
    ET.SubElement(item, sp("shortVersionString")).text = args.version
    ET.SubElement(item, sp("minimumSystemVersion")).text = args.minimum_system_version
    if args.release_page:
        ET.SubElement(item, "link").text = args.release_page
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": str(args.length),
        "type": "application/octet-stream",
        sp("edSignature"): args.signature,
    })

    # 新しい版を先頭（channel の見出しの直後）に入れる。
    children = list(channel)
    first_item = next((i for i, c in enumerate(children) if c.tag == "item"), len(children))
    channel.insert(first_item, item)

    ET.indent(tree, space="  ")
    tree.write(args.out, encoding="utf-8", xml_declaration=True)
    with open(args.out, "a", encoding="utf-8") as f:
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
