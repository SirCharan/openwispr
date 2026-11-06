#!/usr/bin/env python3
"""Merge one generate_appcast item into web/appcast.xml (adapted from Muesli scripts/merge_appcast_item.py, MIT).
Usage: merge_appcast_item.py --existing web/appcast.xml --generated gen.xml --build 2000 --url <zip url>
Creates the existing file with an empty channel when absent. Matches items by sparkle:version (the build number)."""
import argparse
from pathlib import Path
from xml.dom import minidom

NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MARK = "        <!-- Items are added by generate_appcast or the release script -->\n"
EMPTY = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{NS}" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>OpenWispr</title>
{MARK}    </channel>
</rss>
'''

def build_of(item):
    v = item.getElementsByTagNameNS(NS, "version")
    return v[0].firstChild.nodeValue.strip() if v and v[0].firstChild else None

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--existing", required=True, type=Path)
    p.add_argument("--generated", required=True, type=Path)
    p.add_argument("--build", required=True)
    p.add_argument("--url", required=True)
    a = p.parse_args()
    if not a.existing.exists():
        a.existing.parent.mkdir(parents=True, exist_ok=True)
        a.existing.write_text(EMPTY)
    text = a.existing.read_text()
    if text.count(MARK) != 1:
        raise SystemExit("ERROR: appcast missing the unique insertion marker")
    if any(build_of(i) == a.build for i in minidom.parseString(text).getElementsByTagName("item")):
        raise SystemExit(f"ERROR: appcast already contains build {a.build}")
    gen = [i for i in minidom.parse(str(a.generated)).getElementsByTagName("item") if build_of(i) == a.build]
    if len(gen) != 1:
        raise SystemExit(f"ERROR: generated appcast needs exactly one item for build {a.build}")
    item = gen[0]
    for e in list(item.getElementsByTagName("enclosure")):
        if e.hasAttributeNS(NS, "deltaFrom"):
            e.parentNode.removeChild(e)
    encl = item.getElementsByTagName("enclosure")
    if len(encl) != 1:
        raise SystemExit("ERROR: generated item needs exactly one full enclosure")
    encl[0].setAttribute("url", a.url)
    a.existing.write_text(text.replace(MARK, MARK + "        " + item.toxml() + "\n", 1))

if __name__ == "__main__":
    main()
