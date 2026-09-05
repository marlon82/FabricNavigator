#!/usr/bin/env python3
"""Create topology-sized PNG assets without modifying the source photographs."""

import argparse
import json
from pathlib import Path

from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--max-width", type=int, default=1200)
    parser.add_argument("--max-height", type=int, default=400)
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    files = []
    for source in sorted(args.source.glob("*.png")):
        with Image.open(source) as opened:
            image = opened.convert("RGBA")
            image.thumbnail((args.max_width, args.max_height), Image.Resampling.LANCZOS)
            destination = args.destination / source.name
            image.save(destination, "PNG", optimize=True, compress_level=9)
            files.append(source.name)
    manifest = {
        "id": "extreme-device-images",
        "name": "Extreme Device Images",
        "version": args.version,
        "format": 1,
        "fileCount": len(files),
        "files": files,
    }
    (args.destination / "plugin.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
