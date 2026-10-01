#!/usr/bin/env python3
"""Fail publication if the feed does not reference the final signed package."""
import base64
import plistlib
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

feed, app, archive = map(Path, sys.argv[1:])
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(feed).findall("./channel/item")
if len(items) != 1:
    raise SystemExit("Expected exactly one full stable update")
item = items[0]
enclosure = item.find("enclosure")
expected = f'https://github.com/xiaotwu/Muses-Polyhymnia/releases/download/v{info["CFBundleShortVersionString"]}/{archive.name}'
if (enclosure is None or enclosure.get("url") != expected
        or enclosure.get("length") != str(archive.stat().st_size)
        or item.findtext(ns + "version") != info["CFBundleVersion"]
        or item.findtext(ns + "minimumSystemVersion") != info["LSMinimumSystemVersion"]
        or len(base64.b64decode(enclosure.get(ns + "edSignature", ""), validate=True)) != 64
        or not info.get("SUPublicEDKey")
        or not info.get("SURequireSignedFeed")):
    raise SystemExit("Feed does not match the signed application and archive")
