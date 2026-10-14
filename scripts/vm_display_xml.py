#!/usr/bin/env python3
"""Set and verify the preferred guest resolution in libvirt domain XML.

The <resolution> element is a preferred video mode, not a guarantee that a
SPICE client with automatic resizing enabled will keep that mode after login.
Preserve the domain XML verbatim outside its <video> section.
"""
import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

VIDEO = re.compile(r"<video\b[^>]*>.*?</video>", re.S)
MODEL = re.compile(r"<model\b[^>]*?(?:/>|>)", re.S)
RESOLUTION = re.compile(r"<resolution\b[^>]*/>")


def set_resolution(xml: str, x: int, y: int) -> str:
    if not (320 <= x <= 16384 and 240 <= y <= 16384):
        raise ValueError("resolution dimensions out of supported range")
    video = VIDEO.search(xml)
    if video is None:
        raise ValueError("libvirt XML does not contain a video device")
    segment = video.group()
    model = MODEL.search(segment)
    if model is None or not re.search(
        r"""\btype=['"](?:virtio|qxl)['"]""", model.group()
    ):
        raise ValueError("expected a virtio or QXL video model")
    if RESOLUTION.search(segment):
        segment = RESOLUTION.sub(
            f"<resolution x='{x}' y='{y}'/>", segment, count=1
        )
    elif model.group().endswith("/>"):
        old = model.group()
        segment = segment.replace(
            old, old[:-2] + f">\n        <resolution x='{x}' y='{y}'/>\n      </model>", 1
        )
    else:
        segment = segment.replace(
            model.group(), model.group() + f"\n        <resolution x='{x}' y='{y}'/>", 1
        )
    updated = xml[: video.start()] + segment + xml[video.end() :]
    root = ET.fromstring(updated)
    configured = root.find("./devices/video/model/resolution")
    if configured is None or configured.get("x") != str(x) or configured.get("y") != str(y):
        raise ValueError("resolution was not applied to the video model")
    return updated


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xml", type=Path)
    parser.add_argument("width", type=int)
    parser.add_argument("height", type=int)
    args = parser.parse_args()
    original = args.xml.read_text()
    args.xml.write_text(set_resolution(original, args.width, args.height))
    print(f"verified preferred guest display: {args.width}x{args.height}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
